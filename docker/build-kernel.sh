#!/bin/bash
# Mac で実行: Docker で Linux (ARM32) をビルドする。
#   ./docker/build-kernel.sh
# ソースツリーは Docker ボリューム (rk3229-kwork) 内に clone する
# (macOS のファイルシステムは大文字小文字を区別しないため、Linux ツリーを置いてはいけない)。
# 出力: out/kernel/{zImage,rk3229-mx10.dtb,kernelrelease}
# ツリーはボリュームに残り、docker/build-image.sh がモジュールの取り出しに使う。
set -euo pipefail
source "$(dirname "$0")/common.sh"
resolve_src "$LINUX_REPO"
mkdir -p "$ROOT/out/kernel"
docker build -t "$IMAGE" "$HERE"
docker run --rm \
  -v rk3229-kwork:/work \
  -v "$ROOT/out/kernel":/out \
  ${SRC_MOUNT[@]+"${SRC_MOUNT[@]}"} \
  -e SRC_URL="$SRC_URL" -e BRANCH="$LINUX_BRANCH" -e JOBS="$JOBS" \
  "$IMAGE" bash -euxc '
    git config --global --add safe.directory "*"
    if [ -d /work/linux/.git ]; then
      cd /work/linux
      git remote set-url origin "$SRC_URL"
      git fetch -q --depth 1 origin "$BRANCH"
      git checkout -q -f FETCH_HEAD
    else
      git clone -q --depth 1 --branch "$BRANCH" "$SRC_URL" /work/linux
      cd /work/linux
    fi
    git log --oneline -1
    export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
    make rk3229_defconfig
    make "$JOBS" zImage dtbs modules
    cp arch/arm/boot/zImage /out/zImage
    cp arch/arm/boot/dts/rockchip/rk3229-mx10.dtb /out/rk3229-mx10.dtb
    make -s kernelrelease > /out/kernelrelease
    sha256sum /out/zImage /out/rk3229-mx10.dtb
  '
echo "出力: $ROOT/out/kernel/{zImage,rk3229-mx10.dtb}"
