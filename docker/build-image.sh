#!/bin/bash
# Mac で実行: SD カード用イメージ (idbloader + U-Boot + trust + FAT32 /boot + Alpine ext4) を作る。
#   ./docker/build-image.sh
# 先に ./docker/build-uboot.sh と ./docker/build-kernel.sh を実行しておくこと。
# 入力:
#   out/uboot/uboot-usb.img   build-uboot.sh の出力
#   rk3229-tools/trust.img    箱の純正 trust.img (先頭 4 MiB だけ使う。git 管理外。docs/ 参照)
#   ALPINE_VERSION            (任意) デフォルト 3.24.2。out/cache/ にダウンロードして使い回す
# 出力: out/rk3229-alpine-usb.img と .sha256   (ROOT_PASSWORD 環境変数で root のパスワードを変更可)
set -euo pipefail
source "$(dirname "$0")/common.sh"
ALPINE_VERSION=${ALPINE_VERSION:-3.24.2}
[ -f "$ROOT/out/uboot/uboot-usb.img" ] || { echo "out/uboot/uboot-usb.img がありません (先に build-uboot.sh)"; exit 1; }
[ -f "$ROOT/trust.img" ] || { echo "trust.img がありません (箱の純正 trust.img を $ROOT/trust.img に置く)"; exit 1; }
docker volume inspect rk3229-kwork >/dev/null 2>&1 || { echo "カーネルのビルドがありません (先に build-kernel.sh)"; exit 1; }
docker build -t "$IMAGE" "$HERE"
docker run --rm \
  -v rk3229-kwork:/work \
  -v "$ROOT":/host:ro \
  -v "$ROOT/out":/out \
  -e ALPINE_VERSION="$ALPINE_VERSION" -e ROOT_PASSWORD="${ROOT_PASSWORD:-alpine}" \
  "$IMAGE" bash -euxc '
    mkdir -p /out/cache
    ver=$ALPINE_VERSION; br=v${ver%.*}
    tar=alpine-minirootfs-$ver-armv7.tar.gz
    [ -f /out/cache/$tar ] || curl -fL -o /out/cache/$tar \
      https://dl-cdn.alpinelinux.org/alpine/$br/releases/armv7/$tar
    export ALPINE_TAR=/out/cache/$tar KERNEL_BUILD=/work/linux
    export UBOOT_IMG=/host/out/uboot/uboot-usb.img IDBLOADER=/host/loader/idbloader_ddr_1.11.img
    export TRUST_IMG=/host/trust.img OUT=/out
    bash /host/scripts/build-image.sh
  '
echo "出力: $ROOT/out/rk3229-alpine-usb.img"
echo "書き込み: diskutil unmountDisk /dev/diskN && sudo dd if=$ROOT/out/rk3229-alpine-usb.img of=/dev/rdiskN bs=4m"
