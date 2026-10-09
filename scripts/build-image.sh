#!/bin/bash
# Build the RK3229 (MX10) USB-stick image: FAT32 /boot (extlinux, zImage, DTB)
# + ext4 Alpine Linux rootfs.  Runs as root on a Linux host (no loop devices).
#
# Needs: sfdisk mkfs.vfat mtools(mcopy,mmd) e2fsprogs(>=1.43, mke2fs -d) openssl
#        kmod(depmod) tar xz
#
# Inputs (env, with defaults relative to this script):
#   ALPINE_TAR   alpine-minirootfs-*-armv7.tar.gz
#   KERNEL_BUILD kernel tree after: make ARCH=arm rk3229_defconfig zImage dtbs modules
#   UBOOT_IMG    uboot.img for the eMMC "uboot" partition (copied to /boot/rk3229/)
#   IDBLOADER    (optional) loader/idbloader_ddr_1.11.img -> written to sector 64
#   TRUST_IMG    (optional) the box's trust.img; its first 4 MiB -> sector 0x6000
#   With IDBLOADER + UBOOT_IMG + TRUST_IMG the image also boots as an SD card
#   (BootROM -> idblock -> uboot -> trust), without touching the internal flash.
#   OUT          output directory
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ALPINE_TAR=${ALPINE_TAR:?set ALPINE_TAR}
KERNEL_BUILD=${KERNEL_BUILD:?set KERNEL_BUILD}
UBOOT_IMG=${UBOOT_IMG:-}
IDBLOADER=${IDBLOADER:-}
TRUST_IMG=${TRUST_IMG:-}
OUT=${OUT:-$HERE/out}
IMG_MIB=${IMG_MIB:-1536}
ROOT_PASSWORD=${ROOT_PASSWORD:-alpine}
DISK_ID=0x52334b32            # PARTUUID = 52334b32-01 / -02 (see extlinux.conf)
BOOT_START=32768              # sector 32768 = 16 MiB: keeps the area before it
BOOT_SECTORS=131072           #   free for an idbloader (sector 64) / u-boot.itb
ARCH_CROSS=arm-linux-gnueabihf-
export ARCH=arm

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"
KREL=$(cat "$KERNEL_BUILD/include/config/kernel.release")
echo "== kernel $KREL"

# ---- rootfs -------------------------------------------------------------
R=$W/rootfs; mkdir "$R"
tar -xzpf "$ALPINE_TAR" -C "$R" --numeric-owner
cp -a "$HERE/rootfs-overlay/." "$R/"
date +%s > "$R/etc/rk3229/timestamp"
HASH=$(openssl passwd -6 "$ROOT_PASSWORD")
sed -i "s|^root:[^:]*:|root:${HASH//|/\\|}:|" "$R/etc/shadow"
sed -i 's|^root:\([^:]*\):[^:]*:|root:\1:20000:|' "$R/etc/shadow"
make -C "$KERNEL_BUILD" -s ARCH=arm CROSS_COMPILE=$ARCH_CROSS \
     INSTALL_MOD_PATH="$R" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "$R/lib/modules/$KREL/build" "$R/lib/modules/$KREL/source"
mkdir -p "$R/boot" "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp"
chmod 1777 "$R/tmp"

# ---- /boot (FAT32) ------------------------------------------------------
B=$W/boot.img
truncate -s $((BOOT_SECTORS * 512)) "$B"
mkfs.vfat -F 32 -n RK3229BOOT -i 52334b31 "$B" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$B" ::/extlinux ::/rk3229
mcopy -i "$B" "$HERE/boot-overlay/extlinux/extlinux.conf" ::/extlinux/extlinux.conf
mcopy -i "$B" "$KERNEL_BUILD/arch/arm/boot/zImage" ::/zImage
mcopy -i "$B" "$KERNEL_BUILD/arch/arm/boot/dts/rockchip/rk3229-mx10.dtb" ::/rk3229-mx10.dtb
[ -n "$UBOOT_IMG" ] && mcopy -i "$B" "$UBOOT_IMG" ::/rk3229/uboot.img
# keep a copy inside the rootfs' /boot mount point for reference
mkdir -p "$R/boot"

# ---- root (ext4) --------------------------------------------------------
TOTAL=$((IMG_MIB * 2048))
ROOT_START=$((BOOT_START + BOOT_SECTORS))
ROOT_SECTORS=$((TOTAL - ROOT_START))
RF=$W/root.img
truncate -s $((ROOT_SECTORS * 512)) "$RF"
mke2fs -q -t ext4 -L alpine-root -m 1 -O ^orphan_file \
       -U 6b1d2f0e-3229-4a6e-9c6b-52334b320002 -d "$R" "$RF"
e2fsck -fn "$RF" >/dev/null

# ---- assemble -----------------------------------------------------------
IMG=$OUT/rk3229-alpine-usb.img
rm -f "$IMG"; truncate -s $((TOTAL * 512)) "$IMG"
sfdisk -q "$IMG" <<EOT
label: dos
label-id: $DISK_ID
unit: sectors

start=$BOOT_START, size=$BOOT_SECTORS, type=c, bootable
start=$ROOT_START, size=$ROOT_SECTORS, type=83
EOT
if [ -n "$IDBLOADER" ] && [ -n "$UBOOT_IMG" ] && [ -n "$TRUST_IMG" ]; then
	echo "== SD loader chain: idblock@0x40 uboot@0x4000 trust@0x6000"
	dd if="$IDBLOADER" of="$IMG" bs=512 seek=64     conv=notrunc status=none
	dd if="$UBOOT_IMG" of="$IMG" bs=512 seek=16384  conv=notrunc status=none count=8192
	dd if="$TRUST_IMG" of="$IMG" bs=512 seek=24576  conv=notrunc status=none count=8192
fi
dd if="$B"  of="$IMG" bs=512 seek=$BOOT_START  conv=notrunc status=none
dd if="$RF" of="$IMG" bs=512 seek=$ROOT_START  conv=notrunc status=none
sfdisk -l "$IMG"
( cd "$OUT" && sha256sum rk3229-alpine-usb.img > rk3229-alpine-usb.img.sha256 )
echo "== done: $IMG"
