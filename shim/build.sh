#!/bin/bash
# Build the iPixel shim and wrap it in a boot.img v4 for Google Pixel 6 (oriole).
set -euo pipefail
cd "$(dirname "$0")"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	CC=aarch64-linux-gnu-gcc
	LD=aarch64-linux-gnu-ld
	OBJCOPY=aarch64-linux-gnu-objcopy
	NM=aarch64-linux-gnu-nm
	READELF=aarch64-linux-gnu-readelf
	CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
else
	CC="clang"
	LD="/opt/homebrew/bin/ld.lld"
	OBJCOPY="/opt/homebrew/opt/llvm/bin/llvm-objcopy"
	NM="/opt/homebrew/opt/llvm/bin/llvm-nm"
	READELF="/opt/homebrew/opt/llvm/bin/llvm-readelf"
	CFLAGS="-target aarch64-none-elf -O2 -ffreestanding -nostdlib -fpie -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
fi

mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done

# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }

$LD -T shim.ld --build-id=none -N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image

# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
end_hex=$($NM out/shim.elf | awk '$3=="_end"{print $1}')
size=$(python3 -c "print(int('$end_hex', 16))")
truncate -s "$size" out/Image

# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else empty ramdisk
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi

# Compress kernel with legacy LZ4 as required by Pixel 6 ABL
lz4 -c -l -12 --favor-decSpeed out/Image > out/Image.lz4

# Build Android Boot Image Header v4 for Google Pixel 6 (iBoot-Android)
python3 ../tools/mkbootimg_v4.py --kernel out/Image.lz4 --ramdisk out/ramdisk.bin \
	--os_version 13.0.0 --os_patch_level 2026-04 \
	--cmdline "console=null" -o out/shim-boot.img

# Host render of the console layout
clang -O1 -Wall -DHOST_TEST -o out/host_test console.c host_test.c && ./out/host_test
ls -lh out/Image out/Image.lz4 out/shim-boot.img
