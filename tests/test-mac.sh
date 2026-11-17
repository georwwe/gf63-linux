#!/bin/bash
# End-to-end test of mac/build-usb.sh on a macOS runner: official ISO in, FAT32 disk image out.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${RUNNER_TEMP:-/tmp}/gf63"
mkdir -p "$TMP"
sw_vers
brew install wimlib

echo "Downloading ISO..."
curl -L --fail --retry 3 -sS -o "$TMP/ltsc.iso" \
  'https://go.microsoft.com/fwlink/p/?LinkID=2195404&clcid=0x409&culture=en-us&country=US'
ls -lh "$TMP/ltsc.iso"

# A fake driver package, to exercise the drivers path
mkdir -p "$TMP/drivers/wifi"
printf '[Version]\r\nSignature="$Windows NT$"\r\n' > "$TMP/drivers/wifi/test.inf"

# A blank disk image that stands in for the USB stick
hdiutil create -size 12g -type UDIF -layout NONE "$TMP/usb.dmg" >/dev/null
DISK="$(hdiutil attach "$TMP/usb.dmg" -nomount | awk 'NR==1 {print $1}')"
DISK="${DISK#/dev/}"
echo "Fake USB: $DISK"

GF63_ALLOW_ANY_DISK=1 GF63_NO_PROMPT=1 bash "$ROOT/mac/build-usb.sh" "$TMP/ltsc.iso" "$DISK" "$TMP/drivers"

# The script ejects the disk; attach the image again and look inside
DEV="$(hdiutil attach "$TMP/usb.dmg" -nomount | awk 'NR==1 {print $1}')"
USB="$TMP/usbmnt"
mkdir -p "$USB"
sudo mount_msdos -u "$(id -u)" -g "$(id -g)" "${DEV}s1" "$USB"
fail=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
diskutil info "${DEV}s1" | grep -E 'File System Personality|Partition Type' || true
check 'Volume is FAT32'        "diskutil info '${DEV}s1' | grep -q 'MS-DOS FAT32'"
check 'UEFI loader present'    "[ -f '$USB/efi/boot/bootx64.efi' ]"
check 'boot.wim present'       "[ -f '$USB/sources/boot.wim' ]"
check 'setup.exe present'      "[ -f '$USB/setup.exe' ]"
check 'install.swm present'    "[ -f '$USB/sources/install.swm' ]"
check 'No file over 4 GB'      "[ -z \"\$(find '$USB' -type f -size +4095M)\" ]"
ls -lh "$USB/sources/" | grep -i 'install'
LIST="$(wimlib-imagex dir "$USB/sources/install.swm" 1 --ref="$USB/sources/install*.swm")"
check 'Kit inside image'            "echo \"\$LIST\" | grep -q '^/GF63/Optimize-Windows.ps1'"
check 'Slim marker inside image'    "echo \"\$LIST\" | grep -q '^/GF63/slim-pending'"
check 'Drivers inside image'        "echo \"\$LIST\" | grep -q '^/GF63/drivers/drivers/wifi/test.inf'"
check 'SetupComplete inside image'  "echo \"\$LIST\" | grep -qi '^/Windows/Setup/Scripts/SetupComplete.cmd'"
wimlib-imagex extract "$USB/sources/install.swm" 1 /Windows/Setup/Scripts/SetupComplete.cmd \
    --ref="$USB/sources/install*.swm" --dest-dir="$TMP/out" >/dev/null
check 'SetupComplete has CRLF'      "grep -q \$'\\r' '$TMP/out/SetupComplete.cmd'"
[ "$fail" = 0 ] && echo 'All checks passed' || { echo 'Some checks FAILED'; exit 1; }
