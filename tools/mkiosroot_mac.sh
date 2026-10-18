#!/bin/bash
# Build the iPixel iOS root on macOS: one case-sensitive HFS+ image holding an iOS OS
# root filesystem plus its cryptexes, for the Pixel 6 userdata partition.
#
#   sudo ./tools/mkiosroot_mac.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]
#
# SIZE default: 16G
set -euo pipefail

if [[ $# -lt 4 ]]; then
	echo "Usage: sudo $0 OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]" >&2
	exit 1
fi

if [[ $EUID -ne 0 ]]; then
	echo "Error: this script must be run as root (sudo $0 ...)" >&2
	exit 1
fi

os=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1")
sysos=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$2")
appos=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$3")
out=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$4")
size=${5:-16G}

if [[ -e "$out" ]]; then
	echo "Refusing to overwrite existing $out" >&2
	exit 1
fi

work=$(mktemp -d /tmp/ipixel-root.XXXXXX)
attached_devs=()

cleanup() {
	echo "Cleaning up mounts..."
	for dev in "${attached_devs[@]}"; do
		hdiutil detach "$dev" -force 2>/dev/null || true
	done
	rm -rf "$work"
}
trap cleanup EXIT

echo "--> Mounting IPSW APFS disk images..."
mount_apfs() {
	local img="$1"
	local dev_mount
	dev_mount=$(hdiutil attach -nobrowse -readonly "$img" | awk '/\/Volumes/{print $1, $3}')
	local dev=$(echo "$dev_mount" | awk '{print $1}')
	local mnt=$(echo "$dev_mount" | awk '{print $2}')
	attached_devs+=("$dev")
	echo "$mnt"
}

os_mnt=$(mount_apfs "$os")
sysos_mnt=$(mount_apfs "$sysos")
appos_mnt=$(mount_apfs "$appos")

echo "  OS mounted at: $os_mnt"
echo "  SystemOS mounted at: $sysos_mnt"
echo "  AppOS mounted at: $appos_mnt"

echo "--> Creating blank HFS+ image: $out ($size)..."
# Create raw sparse/flat file
size_bytes=$(python3 -c "
s = '$size'.upper()
mult = 1
if s.endswith('G'): mult = 1024**3; s = s[:-1]
elif s.endswith('M'): mult = 1024**2; s = s[:-1]
print(int(s) * mult)
")
dd if=/dev/zero of="$out" bs=1048576 count=0 seek=$((size_bytes / 1048576)) status=none

# Attach raw image as block device and format as Case-Sensitive Journaled HFS+
root_dev=$(hdiutil attach -nobrowse -nomount "$out" | awk '{print $1; exit}')
attached_devs+=("$root_dev")

echo "--> Formatting $root_dev as Case-Sensitive Journaled HFS+..."
newfs_hfs -J -s -v iOSRoot "$root_dev"

mkdir -p "$work/root"
mount -t hfs "$root_dev" "$work/root"

echo "--> Copying OS filesystem..."
rsync -aH --numeric-ids "$os_mnt/" "$work/root/"

echo "--> Staging SystemOS and AppOS cryptexes into /private/preboot/Cryptexes..."
mkdir -p "$work/root/private/preboot/Cryptexes/OS"
mkdir -p "$work/root/private/preboot/Cryptexes/App"
rsync -aH --numeric-ids "$sysos_mnt/" "$work/root/private/preboot/Cryptexes/OS/"
rsync -aH --numeric-ids "$appos_mnt/" "$work/root/private/preboot/Cryptexes/App/"

echo "--> Linking shared cache to /System/Library/Caches/com.apple.dyld..."
dsc="private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
for f in "$work/root/$dsc"/*; do
	[ -e "$f" ] || continue
	ln -f "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

echo "--> Hard-linking cryptex binaries not present in base root..."
for c in OS App; do
	(cd "$work/root/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [ ! -e "$work/root/$f" ] && [ ! -L "$work/root/$f" ]; then
			mkdir -p "$work/root/$(dirname "$f")"
			src="$work/root/private/preboot/Cryptexes/$c/$f"
			if [ -L "$src" ]; then
				cp -P "$src" "$work/root/$f"
			else
				ln "$src" "$work/root/$f"
			fi
		fi
	done
done

echo "--> Setting up logd diagnostics & uuidtext directories..."
db="$work/root/private/var/db"
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

echo "--> Installing system keybag for AppleKeyStore..."
install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
	install -m 0600 -o 0 -g 0 /dev/stdin "$work/root/private/var/keybags/systembag.kb"

echo "--> Applying iPixel root tweaks (disabling watchdog, skipping Setup & migration, seeding activation)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/sweet-root-tweaks.py" "$work/root"

echo "--> Unmounting target image..."
umount "$work/root"

echo "--> Verifying HFS+ filesystem..."
fsck_hfs -f "$root_dev"

echo "--> Detaching block devices..."
hdiutil detach "$root_dev"
attached_devs=()

echo "Successfully built iOS 16 root image: $out"
