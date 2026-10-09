# RK3229 (MX10 TV box) → mainline U-Boot v2026.07 移行メモ (2026-09-30)

対象は `MIGRATION.md` と同じ実機です。元の `uboot` パーティション(Rockchip 製 U-Boot 2014.10 系)を、
mainline U-Boot v2026.07 に差し替えます。

> **状態: ビルドと梱包の検証まで完了。実機での起動は未検証です。** 下の「未検証・要確認」を必ず読んでください。

## 1. 方針: 元の idblock / trust は残し、uboot パーティションだけ差し替える

RK322x の起動順は `BootROM → idblock(DDR初期化 + miniloader) → uboot → trust(TOS) → ...` です。

- `nand_full_dump.img` の **sector 64 付近の idblock は全部ゼロ**で、バックアップに含まれていません(sector 0〜0x1000 には PARM のコピーしかありません)。
  つまり idblock は、一度上書きすると元に戻せません。
- mainline の TPL/SPL 方式(`u-boot-rockchip.bin` を sector 64 に書く)は、この idblock を置き換え、DDR 初期化を U-Boot の TPL が行います。
  そのための DRAM タイミング(`rockchip,pctl-timing` など)は MX10 の DRAM 用の値が分からず、EVB の値しかありません。合わないと起動しなくなります。
- そこで **idblock と trust.img(TOS)は触らず**、`uboot` パーティションの中身だけを mainline U-Boot にします。
  DDR 初期化と TOS(PSCI) は元のまま動き、U-Boot は EVB + OP-TEE 構成と同じく、非セキュア側で動きます。
- `uboot` パーティションだけの変更なので、`extracted/uboot.img` を書き戻せば元に戻ります。

## 2. 成果物

| ファイル | 内容 |
|---|---|
| `port/uboot/uboot.img` | 書き込み用イメージ(4 MiB、元と同形式)。ロードアドレス 0x61000000 |
| `port/uboot/u-boot.bin` | U-Boot 本体(DTB 込み、491,320 bytes)。`uboot.img` の中身 |
| `port/uboot/u-boot-0001-rockchip-add-MX10-RK3229-TV-box.patch` | v2026.07 に対する MX10 ボードの差分(コミット済み: `840c8b95`) |
| `port/uboot/series/0001〜0011-*.patch` | Armbian の rk322x-box 用パッチを取り込んだ差分(7 章) |
| `port/tools/rk-pack.py` | `loader` / `loader-info` コマンドを追加 |
| `u-boot-v2026.07/` | 上の patch を適用済み(未コミット) |

patch の内容:

- `configs/mx10-rk3229_defconfig`: EVB の defconfig をベースに、環境変数の保存先を無しにし、Ethernet を外し、LED を追加
- `arch/arm/dts/rk3229-mx10.dts`: `linux-v7.2` の MX10 DTS のコピー(`OF_UPSTREAM` は使わずローカル DTS を使用)
- `arch/arm/dts/rk3229-mx10-u-boot.dtsi`: stdout=UART2、青 LED を点灯、赤 LED を消灯
- `board/rockchip/mx10_rk3229/`, `include/configs/mx10_rk3229.h`, `arch/arm/mach-rockchip/rk322x/Kconfig`: ボード定義。
  ブートターゲットは `mmc0 mmc2`(SD → eMMC)のみ

## 3. ビルド

```
cd u-boot-v2026.07
make mx10-rk3229_defconfig
make CROSS_COMPILE=arm-linux-gnueabihf- -j u-boot.bin
python3 ../port/tools/rk-pack.py loader u-boot.bin uboot.img --addr 0x61000000 --magic LOADER
python3 ../port/tools/rk-pack.py loader-info uboot.img      # 4 コピーとも OK になること
```

- 使ったツール: gcc 13.3 (arm-linux-gnueabihf), Ubuntu 24.04。警告・エラーなし。
- **`make`(ターゲット指定なし)は最後の binman 工程で失敗します**(OP-TEE の `tee.bin` が無いため)。想定内で、`u-boot.bin` は先に出来ています。
  このとき出来る `u-boot-rockchip.bin` は偽のブロブ入りの非機能イメージなので、**絶対に書かないでください**。
- `rk-pack.py loader` は、元の `uboot.img` / `trust.img` を、その中身から再生成して**バイト一致**することを確認済みです
  (ヘッダ: 8 バイトの magic, ロードアドレス, サイズ, CRC(多項式 0x04c10db7), SHA-256(payload + addr + size + 32), 1 MiB 間隔 4 コピー)。
- `u-boot.bin` は 1 MiB スロットに収まります(上限 約 1,046,000 bytes)。

## 4. 書き込みと復旧

マスクロム状態(MASKROM キーを押しながら電源)で、`MIGRATION.md` と同じく `rkdeveloptool` を使う想定です。
`uboot` パーティションは sector 0x2000(mtdparts より)、4 MiB です。

```
rkdeveloptool db <RK322x の loader>      # 書き込み用の一時ローダ
rkdeveloptool wl 0x2000 port/uboot/uboot.img
rkdeveloptool rd
```

- **戻すとき**: 同じ手順で `wl 0x2000 extracted/uboot.img`。
- 起動しなくても、idblock を触っていないのでマスクロムには入れます。

## 5. 起動の流れと期待する動作

- 元のローダが `uboot.img` を 0x61000000 に読み込んで起動します。
- 起動できると **前面の青 LED が点灯**し、赤 LED は消灯します。UART2 (1.5 Mbaud) に U-Boot のログが出ます。
- 既定は `bootflow scan`(標準ブート)です。
  SD カード(mmc0)、次に eMMC(mmc2)から `extlinux.conf` / `boot.scr` を探します。環境変数は保存しません(書き込みなし)。
  SD の例(`/boot/extlinux/extlinux.conf`, カーネルには `CMDLINE_FORCE` が入っているので append は参考):

  ```
  label linux
    kernel /boot/zImage
    fdt /boot/dtbs/rockchip/rk3229-mx10.dtb
    append console=ttyS2,1500000n8 root=/dev/mmcblk0p1 rootwait rw
  ```
- eMMC の Rockchip 形式カーネル(`kernel` パーティション、`kernel-appended-dtb.img`)を直接起動する補助コマンドとして、
  U-Boot のプロンプトで `run boot_rkemmc` を用意しています(これも未検証)。

## 6. 未検証・要確認

1. **実機起動は未確認**です(実機に接続できないため、ビルドと梱包の検証のみ)。UART の最初のログと LED を確認してください。
2. **DRAM 容量**: 本体は DDR 初期化を元の idblock に任せ、GRF `os_reg2` からサイズを読みます。
   元の DDR ブロブがこのレジスタを Rockchip 標準の形式で設定していれば `DRAM: 1 GiB` と出ます。
   出ない・値がおかしい場合は、まずここを疑ってください(ブロブの中身は見られないため未確認)。
3. **ロードアドレス**: 元の uboot は 0x60000000 でしたが、mainline の EVB 設定に合わせて 0x61000000 にしています。
   起動しない場合は、`CONFIG_TEXT_BASE` と `rk-pack.py` の `--addr` を 0x60000000 に揃えて試せます。
4. **TOS 領域**: trust.img は 0x68400000 に読み込まれます(EVB の OP-TEE では 0x68400000-0x68600000 を保護)。
   MX10 の Linux DTS(vendor DTB も)にはこの領域の `reserved-memory` がありません。
   Linux がここを使うと問題になる可能性があります。カーネル側の確認事項です(今回は変更していません)。
5. **未対応**:
   - **Ethernet**: 内蔵 PHY(RMII)用のドライバが U-Boot に無く、`gmac_rockchip` は RGMII のみ。ネットワークブートは不可
   - **USB ホスト**: rk322x 用の USB2 PHY ドライバが無い(USB メモリからの起動は不可)
   - HDMI 出力、Wi-Fi、IR、VFD
   - OTG ガジェット(`ums`, fastboot)は EVB の設定のまま入れていますが、MX10 では試していません
6. **TPL/SPL チェーン**: idblock を置き換える方式は、上記のとおり DRAM タイミングが不明なため**使っていません**。
   `rk3229-mx10-u-boot.dtsi` の `&dmc` の値は EVB のもので、MX10 では検証していません。
7. LED の極性と GPIO は Linux DTS(vendor DT からの推定)のままです。点灯しない場合は極性の可能性があります。

## 7. Armbian の rk322x-box 用パッチの取り込み

Armbian (`armbian/build` の `patch/u-boot/v2026.04/`) の rk322x-box 用 U-Boot パッチを、v2026.07 に取り込みました
(`port/uboot/series/` の 11 本、`u-boot-v2026.07/` の `rk3229` ブランチに `840c8b95` の続きとしてコミット)。
元の作者(Paolo Sabatino)は各コミットの author に残してあります。

| 内容 | パッチ |
|---|---|
| DW-HDMI / rk3228 HDMI・inno HDMI PHY・VOP ドライバ、クロック | 0001〜0005(そのまま) |
| GMAC の内蔵 RMII PHY 対応 | 0007(v2026.07 に合わせて調整) |
| USB OTG / EHCI(リセット、PHY) | 0006(調整)、0009(そのまま) |
| SPL の OP-TEE 起動で r1 を設定(SPL のみ。MX10 の起動経路には無関係) | 0008(そのまま) |
| `rk322x-box` ボードの defconfig / DTS(TPL/SPL + Rockchip の DDR ブロブ + OP-TEE 方式) | 0010〜0011 |

- v2026.07 に当たらなかった箇所は手で合わせました。DTS の hunk(Armbian は `arch/arm/dts/rk322x.dtsi` を直接変更)は、
  v2026.07 が Linux の `rk322x.dtsi` を取り込んでいるため、`arch/arm/dts/rk322x-u-boot.dtsi` での上書きに置き換えています。
  `gmac_rockchip.c` は `#include <reset.h>` の 1 hunk、Kconfig / DTS Makefile はボード追加部分を手で合わせています。
- `mx10-rk3229_defconfig` と `rk322x-box_defconfig` の**両方がビルドできます**(警告・エラーなし)。
- **MX10 の defconfig では、これらの機能(Ethernet、USB、HDMI)はまだ有効にしていません**。
  そのため `u-boot.bin` は 489,576 → 491,320 bytes に増えただけで、動作は 4 章までと同じです(`uboot.img` は作り直しました)。
  有効化する場合は `mx10-rk3229_defconfig` に、`rk322x-box_defconfig` の `CONFIG_GMAC_ROCKCHIP` / `CONFIG_PHY_ROCKCHIP_INNO_USB2` /
  `CONFIG_USB_*` / `CONFIG_VIDEO*` などを追加します(未検証です)。
- `rk322x-box_defconfig` は、DDR 初期化に Rockchip の DDR ブロブ(`rk322x_ddr_*.bin`)を使う TPL/SPL 方式で、idblock を置き換えます。
  ブロブは Armbian の `packages/blobs/rockchip/` にあり、この tree には入れていません。**MX10 の実機には書かないでください**
  (idblock がバックアップに無いため、書くと元に戻せません)。
