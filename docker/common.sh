# shellcheck shell=bash
# 共通設定 (docker/*.sh から source される)。環境変数で上書きできる。
#
#   UBOOT_REPO / UBOOT_BRANCH   U-Boot のソース (URL か、Mac 上の絶対パス)
#   LINUX_REPO / LINUX_BRANCH   Linux のソース
#   JOBS                        make の並列数 (デフォルト -j8)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/docker
ROOT="$(cd "$HERE/.." && pwd)"                         # <repo>
UBOOT_REPO=${UBOOT_REPO:-https://github.com/tsuji-riya/u-boot}
UBOOT_BRANCH=${UBOOT_BRANCH:-rk3229}
LINUX_REPO=${LINUX_REPO:-https://github.com/tsuji-riya/linux}
LINUX_BRANCH=${LINUX_BRANCH:-rk3229}
JOBS=${JOBS:--j8}
IMAGE=rk3229-build
mkdir -p "$ROOT/out"

# 絶対パスならそのディレクトリを /src に読み取り専用でマウントして clone する
# (結果: SRC_MOUNT=docker run 用の -v 引数, SRC_URL=コンテナ内での clone 元)
resolve_src() {  # $1=repo-or-path
  if [[ "$1" == /* ]]; then
    SRC_MOUNT=(-v "$1":/src:ro); SRC_URL=file:///src
  else
    SRC_MOUNT=(); SRC_URL=$1
  fi
}
