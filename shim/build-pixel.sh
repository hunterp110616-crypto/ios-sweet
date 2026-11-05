#!/bin/bash
# Build the Pixel 5 boot image:  build-pixel.sh PAYLOAD.bin OUT.img
#   shim (arm64 Image, text_offset 0x80000) -> zero-padded to 12 MB -> LZ4 frame (-B7) = kernel
#   PAYLOAD.bin (tools/mkpayload.py) = boot ramdisk (ABL puts it after the 30 MB vendor ramdisk; the shim searches for it)
#   boot.img header v3 + unsigned AVB hash footer, 96 MiB like the stock boot partition (what `fastboot boot` accepts on redfin)
set -euo pipefail
cd "$(dirname "$0")"
[ $# -ge 2 ] || { sed -n '2,6p' "$0"; exit 2; }
PAYLOAD=$(realpath "$1"); OUTIMG=$(realpath -m "$2")
MKBOOTIMG=${MKBOOTIMG:-$HOME/pixel5/mkbootimg/mkbootimg.py}
AVBTOOL=${AVBTOOL:-$HOME/pixel5/avb/avbtool.py}
CC=aarch64-linux-gnu-gcc
OBJCOPY=aarch64-linux-gnu-objcopy
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
abs=$(aarch64-linux-gnu-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
size=$(aarch64-linux-gnu-nm out/shim.elf | awk '$3=="_end"{print strtonum("0x"$1)}')
truncate -s "$size" out/Image
cp out/Image out/Image-12M
truncate -s 12582912 out/Image-12M
lz4 -9 -B7 -f out/Image-12M out/Image.lz4 >/dev/null
python3 "$MKBOOTIMG" --header_version 3 --kernel out/Image.lz4 --ramdisk "$PAYLOAD" \
	--os_version 14.0.0 --os_patch_level 2023-11 --cmdline "" -o "$OUTIMG"
python3 "$AVBTOOL" add_hash_footer --image "$OUTIMG" --partition_size $((0x6000000)) --partition_name boot \
	--prop com.android.build.boot.os_version:14 \
	--prop com.android.build.boot.fingerprint:google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys \
	--prop com.android.build.boot.security_patch:2023-11-05
ls -l out/Image "$OUTIMG"
