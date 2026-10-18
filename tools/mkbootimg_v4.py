#!/usr/bin/env python3
"""Pack a kernel and ramdisk into an Android Boot Image Header v4 (boot_img_hdr_v4).

Used for Google Pixel 6 (oriole) fastboot boot images.
"""
import argparse, struct, sys

BOOT_MAGIC = b'ANDROID!'
BOOT_IMAGE_HEADER_V4_SIZE = 1584
PAGE_SIZE = 4096


def align(size, page_size=PAGE_SIZE):
    return (size + page_size - 1) // page_size * page_size


def encode_os_version(version_str, patch_level_str):
    """Encode OS version (e.g. 13.0.0) and patch level (e.g. 2026-04)."""
    val = 0
    if version_str:
        parts = [int(p) for p in version_str.split('.')[:3]]
        while len(parts) < 3:
            parts.append(0)
        a, b, c = parts
        val |= ((a & 0x7f) << 25) | ((b & 0x7f) << 18) | ((c & 0x7f) << 11)
    if patch_level_str:
        y, m = [int(p) for p in patch_level_str.split('-')[:2]]
        val |= (((y - 2000) & 0x7f) << 4) | (m & 0xf)
    return val


def create_boot_image_v4(kernel_bytes, ramdisk_bytes=b'', cmdline='', os_version=0):
    ksize = len(kernel_bytes)
    rsize = len(ramdisk_bytes)
    hdr_size = BOOT_IMAGE_HEADER_V4_SIZE
    header_version = 4

    # Format of v4 header (1584 bytes):
    # 0x00: char magic[8] = "ANDROID!"
    # 0x08: uint32_t kernel_size
    # 0x0C: uint32_t ramdisk_size
    # 0x10: uint32_t os_version
    # 0x14: uint32_t header_size
    # 0x18: uint32_t reserved[4]
    # 0x28: uint32_t header_version = 4
    # 0x2C: char cmdline[1536]
    # 0x62C: uint32_t reserved / end of 1584 bytes

    hdr = bytearray(hdr_size)
    struct.pack_into('<8sIIII4I', hdr, 0,
                     BOOT_MAGIC,
                     ksize,
                     rsize,
                     os_version,
                     hdr_size,
                     0, 0, 0, 0)
    struct.pack_into('<I', hdr, 40, header_version)

    cl = cmdline.encode('utf-8')[:1535]
    hdr[44:44 + len(cl)] = cl

    # Align header to page size
    hdr_padded = bytes(hdr) + b'\0' * (align(len(hdr)) - len(hdr))
    kernel_padded = kernel_bytes + b'\0' * (align(ksize) - ksize)
    ramdisk_padded = ramdisk_bytes + b'\0' * (align(rsize) - rsize) if rsize else b''

    return hdr_padded + kernel_padded + ramdisk_padded


def main():
    parser = argparse.ArgumentParser(description='Build Android Boot Image v4 for Pixel 6')
    parser.add_argument('--kernel', required=True, help='Path to kernel binary (Image)')
    parser.add_argument('--ramdisk', default=None, help='Path to ramdisk binary (payload)')
    parser.add_argument('--cmdline', default='', help='Kernel command line')
    parser.add_argument('--os_version', default='13.0.0', help='OS version string')
    parser.add_argument('--os_patch_level', default='2026-04', help='OS patch level string (YYYY-MM)')
    parser.add_argument('-o', '--output', required=True, help='Output boot image path')
    args = parser.parse_args()

    with open(args.kernel, 'rb') as f:
        kernel_data = f.read()

    ramdisk_data = b''
    if args.ramdisk:
        with open(args.ramdisk, 'rb') as f:
            ramdisk_data = f.read()

    os_ver = encode_os_version(args.os_version, args.os_patch_level)
    boot_img = create_boot_image_v4(kernel_data, ramdisk_data, args.cmdline, os_ver)

    with open(args.output, 'wb') as f:
        f.write(boot_img)

    print(f'Wrote {args.output}: {len(boot_img)} bytes (kernel={len(kernel_data)}, ramdisk={len(ramdisk_data)})')


if __name__ == '__main__':
    main()
