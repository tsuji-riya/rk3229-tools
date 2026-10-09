#!/bin/bash
# Mac で実行: Docker で U-Boot をビルドし、Rockchip ローダ形式 (uboot-usb.img) に梱包する。
#   ./docker/build-uboot.sh
# 出力: out/uboot/{u-boot.bin,uboot-usb.img}
set -euo pipefail
source "$(dirname "$0")/common.sh"
resolve_src "$UBOOT_REPO"
mkdir -p "$ROOT/out/uboot"
docker build -t "$IMAGE" "$HERE"
docker run --rm \
  -v rk3229-uwork:/work \
  -v "$ROOT":/host:ro \
  -v "$ROOT/out/uboot":/out \
  ${SRC_MOUNT[@]+"${SRC_MOUNT[@]}"} \
  -e SRC_URL="$SRC_URL" -e BRANCH="$UBOOT_BRANCH" -e JOBS="$JOBS" \
  "$IMAGE" bash -euxc '
    git config --global --add safe.directory "*"
    if [ -d /work/u-boot/.git ]; then
      cd /work/u-boot
      git remote set-url origin "$SRC_URL"
      git fetch -q --depth 1 origin "$BRANCH"
      git checkout -q -f FETCH_HEAD
      git clean -qfdx
    else
      git clone -q --depth 1 --branch "$BRANCH" "$SRC_URL" /work/u-boot
      cd /work/u-boot
    fi
    git log --oneline -1
    export CROSS_COMPILE=arm-linux-gnueabihf-
    make mx10-rk3229_defconfig
    make "$JOBS" u-boot.bin
    cp u-boot.bin /out/u-boot.bin
    python3 /host/tools/rk-pack.py loader u-boot.bin /out/uboot-usb.img --addr 0x61000000
    python3 /host/tools/rk-pack.py loader-info /out/uboot-usb.img
    sha256sum /out/u-boot.bin /out/uboot-usb.img
  '
cat <<MSG

出力: $ROOT/out/uboot/uboot-usb.img
(動作確認: U-Boot のプロンプトで "version" を実行し、ビルド日時を確認)

SD カード (例: /dev/disk5) の U-Boot だけを更新するには:
  diskutil unmountDisk /dev/disk5
  sudo dd if=$ROOT/out/uboot/uboot-usb.img of=/dev/rdisk5 bs=512 seek=16384 conv=notrunc
  diskutil eject /dev/disk5
MSG
