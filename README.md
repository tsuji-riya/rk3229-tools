# rk3229-tools

RK3229 (MX10 系 TV box) で mainline **U-Boot + Linux** を動かすためのビルド・SD カードイメージ作成ツール一式。
ソースは別リポジトリの `rk3229` ブランチにあります。このリポジトリはビルド手順・イメージ作成・パッチ・資料を持ちます。

| 何 | どこ |
|---|---|
| U-Boot (v2026.07 + MX10 対応) | <https://github.com/tsuji-riya/u-boot> ブランチ `rk3229` |
| Linux (v7.2 + MX10 対応) | <https://github.com/tsuji-riya/linux> ブランチ `rk3229` |

## 構成

```
docker/       Mac から実行するビルドスクリプト (Docker 必須)
  build-uboot.sh    U-Boot → out/uboot/uboot-usb.img
  build-kernel.sh   Linux  → out/kernel/{zImage,rk3229-mx10.dtb}
  build-image.sh    SD カードイメージ → out/rk3229-alpine-usb.img
scripts/
  build-image.sh    イメージ組み立て本体 (docker/build-image.sh がコンテナ内で呼ぶ)
tools/rk-pack.py    Rockchip ローダ形式 (uboot.img) の梱包
boot-overlay/ rootfs-overlay/   SD の /boot (extlinux.conf) と Alpine の設定
loader/       Rockchip の idbloader (SD 起動用の第一段ローダ)。由来は loader/README.md
docs/         BOOT-ANALYSIS.md (ブート解析) / NOTES.md (実機で分かったこと) / UBOOT.md / MIGRATION.md
```

## ビルド (Mac, Docker)

`-j8` で動きます (`JOBS=-j4 ./docker/...` で変更可)。ソースは既定で上の GitHub の `rk3229` ブランチを clone します。
別の場所を使うときは `UBOOT_REPO` / `LINUX_REPO` (URL か Mac 上の絶対パス)、`UBOOT_BRANCH` / `LINUX_BRANCH` で上書きします。
ソースツリーは Docker ボリューム (`rk3229-uwork`, `rk3229-kwork`) に置かれます
(Mac のファイルシステムは大文字小文字を区別しないため、Linux ツリーを Mac 上に置けません)。

```
./docker/build-uboot.sh      # U-Boot
./docker/build-kernel.sh     # Linux
cp /path/to/extracted/trust.img ./trust.img    # 箱の純正 trust.img (git 管理外、先頭 4 MiB だけ使う)
./docker/build-image.sh      # SD イメージ (Alpine minirootfs をダウンロードします)
```

### SD カードに書く (macOS)

**SD カードの中身は全部消えます。書き込み先を必ず確認してください。**

```
diskutil list                               # /dev/diskN を確認
diskutil unmountDisk /dev/diskN
sudo dd if=out/rk3229-alpine-usb.img of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

U-Boot だけ差し替えるとき (イメージ全体は書き直さない):

```
sudo dd if=out/uboot/uboot-usb.img of=/dev/rdiskN bs=512 seek=16384 conv=notrunc
```

カーネルだけ差し替えるとき: SD の FAT32 ボリューム `RK3229BOOT` に `out/kernel/zImage` と `rk3229-mx10.dtb` をコピーします。

### 起動

UART2 (1,500,000 baud, 8N1) と HDMI の両方にブートメニューが出ます。既定は `alpine`。
Alpine のログインは `root` / `alpine` です (ROOT_PASSWORD で変更可)。**起動したらすぐ `passwd` で変更してください。**
問題があるときは extlinux メニューの `debug` / `alpine-safe`、`docs/BOOT-ANALYSIS.md` の切り分け表を使ってください。

## ソースの変更内容

コードはこのリポジトリには置きません。上の 2 つのリポジトリの `rk3229` ブランチを参照してください。

| Linux (`v7.2` の上) | |
|---|---|
| `dt-bindings: arm: rockchip: Add RK3229 MX10 TV box` | compatible |
| `ARM: dts: rockchip: rk322x: Add the VIO power domain to the HDMI node` | Linux HDMI のハング対策 |
| `ARM: dts: rockchip: Add RK3229 MX10 TV box` | rk3229-mx10.dts と Makefile |
| `ARM: configs: Add rk3229_defconfig` | defconfig |

| U-Boot (`support mx10` の上) | |
|---|---|
| `rockchip: mx10-rk3229: Enable USB host, HDMI video and USB boot` | USB ホスト / HDMI / USB 起動 |
| `usb: kbd: Bind the 2024 USB-C Apple Magic Keyboards by device ID` | Apple キーボード |
| `usb: kbd: Create the interrupt queue also for POLL_NO_REPORT_IDLE devices` | 割り込みキュー |
| `usb: ohci: Do cache maintenance for interrupt queue buffers` | キー入力の取りこぼし修正 |

## 状態

実機 (MX10, RK3229) で確認済み: SD からの起動、U-Boot の HDMI とシリアル出力、USB キーボード (U-Boot)、Linux の HDMI 出力、Alpine のログイン。
未確認: Ethernet、Wi-Fi、音声、USB メモリからのブート (U-Boot は `usb` を先に探す設定)、`docker/build-kernel.sh` と `docker/build-image.sh` の初回実行。
