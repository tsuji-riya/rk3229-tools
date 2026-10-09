# RK3229 (MX10 TV box) → mainline Linux v7.2 移行メモ (2026-09-29)

対象: `nand_full_dump.img` の実機（Rockchip RK3229 / DDR3 1GiB / eMMC 8GiB、Android 7.1.2 SDK・vendor kernel 3.10.104）を、
Android ではなく通常の Linux として mainline v7.2 で動かすための移植。

> **状態: ビルド検証まで完了。実機での起動は未検証です。** 下の「未検証・要確認」を必ず読んでください。

## 1. 解析結果（vendor DTS → mainline への対応）

| 項目 | vendor (3.10) の内容 | v7.2 での扱い |
|---|---|---|
| SoC / 基本 | rk3229, Cortex-A7 x4, OPP 408MHz–1.464GHz（mainline rk3229.dtsi の OPP と一致） | `rk3229.dtsi` をそのまま利用 |
| メモリ | `memory { reg = <0 0> }`（ローダが決定）。firmware に `roca.mem.size=8GB1GB` → 8GiB flash + **1GiB RAM** | `0x60000000 + 1GiB`（ローダが ATAG で渡す場合は ATAG_DTB_COMPAT によりその値が優先） |
| CPU 電源 | PWM1 → vdd_arm (0.95–1.40V) | `pwm-regulator` (`pwm1`) |
| ロジック/GPU 電源 | PWM2 → vdd_logic (1.00–1.30V) | `pwm-regulator` (`pwm2`)、Mali-400 は `lima` |
| 有線 LAN | 内蔵 PHY, RMII, clock output 50MHz | `gmac` + 内蔵 PHY (`ethernet-phy-id1234.d400`) |
| eMMC | rksdmmc@30020000, 8bit, 37.5MHz | `emmc` (`mmc2`) |
| SD | rksdmmc@30000000, `broken-cd`, `power-inverted`（電源 SW = GPIO1_B6） | `sdmmc` (`mmc0`) + `vcc_sd` |
| SDIO Wi-Fi/BT | 電源 GPIO2_D2(Wi-Fi)/GPIO2_D5(BT)、32kHz 出力 GPIO1_B0、BT UART1 = GPIO3_B5/B6/A6/A7 | `mmc-pwrseq-simple` + `sdio`, `uart1`（BT 用ピンを board DTS に定義） |
| HDMI | rk322x-hdmi, CEC 有効, I2S0 音声 | `dw-hdmi` + `vop` + `simple-audio-card`(I2S0) |
| USB | host VBUS = GPIO3_C4, OTG 1 + host 2 | `u2phy0/1`, `usb_otg`, `usb_host{0,1,2}_{ehci,ohci}` |
| コンソール | UART2 (uart21 ピン), 1.5Mbaud (fiq-debugger) | `uart2`, `stdout-path = serial2:1500000n8` |
| 電源キー | GPIO0_A3 | `gpio-keys` |
| LED | 赤 GPIO3_C5 / 青 GPIO1_A7 | `gpio-leds` |
| IR | PWM3 (GPIO1_B3) を独自ドライバでデコード | `gpio-ir-receiver`（NEC 系。キーマップは userland で設定） |
| 熱 | tsadc, CRU リセット | `tsadc` (`hw-tshut-mode = 0`) |
| **PSCI** | **legacy PSCI 0.1**（`arm,psci`, cpu_on=0x84000003 …）。trust.img(TOS) が提供 | vendor と同じ記述で上書き（後述） |

基板は Rockchip RK322x box リファレンス設計で、mainline の `rk3229-xms6.dts` とほぼ同構成です。DTS はそれをベースに MX10 固有部分を反映しました。

## 2. 成果物（`port/` 以下）

| ファイル | 内容 |
|---|---|
| `linux-v7.2/arch/arm/boot/dts/rockchip/rk3229-mx10.dts` | MX10 用 DTS（新規） |
| `linux-v7.2/arch/arm/configs/rk3229_defconfig` | Rockchip 専用に絞った defconfig（新規） |
| `.../rockchip/Makefile`, `Documentation/.../rockchip.yaml` | DTB 登録と binding 追記 |
| `port/0001-...patch` | 上記の差分 |
| `port/zImage`, `port/rk3229-mx10.dtb`, `port/zImage-dtb` | ビルド済みカーネル / DTB / DTB 連結版 |
| `port/kernel.img`, `port/resource.img` | 元のローダ用に梱包済み（12MiB / 15MiB, 元と同サイズ） |
| `port/kernel-appended-dtb.img` | DTB 連結版 zImage の kernel.img |
| `port/modules-7.2.0-rk3229.tar.gz` | モジュール（rootfs の `/` に展開） |
| `port/tools/rk-pack.py` | KRNL / RSCE イメージ作成ツール |

ビルド: `make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- rk3229_defconfig && make -j zImage dtbs modules`
（gcc 13.3 クロスで警告なし。`W=1` の DTB 警告なし。`CHECK_DTBS=y` の指摘は `hdmi resets`（rk322x.dtsi 由来、xms6 も同じ）のみ。）

> macOS のツリーは大文字小文字を区別しない FS のため netfilter の `xt_DSCP.h`/`xt_dscp.h` 等が衝突し、git 上で "modified" になっています（今回の変更とは無関係）。ビルドは case-sensitive な Linux 上で行ってください。

## 3. 起動方法

元のローダ（uboot.img / trust.img）を残したまま、eMMC の `kernel` と `resource` だけを差し替える方式です。
`nand_full_dump.img` が元に戻すための完全バックアップになります。

- `rk-pack.py` は元 firmware の `kernel.img`/`resource.img` を再生成して**バイト一致**することを確認済みです
  （KRNL の CRC は多項式 0x04c10db7・init 0・zImage 部分）。
- PARM の `KERNEL_IMG: 0x60408000`, `ATAG: 0x60000800`。ローダは resource 内の `rk-kernel.dtb` を DTB として渡す想定。
- **cmdline はカーネル内に固定**しています（`CONFIG_CMDLINE_FORCE`）:
  `console=ttyS2,1500000n8 root=/dev/mmcblk0p1 rootwait rw`
  ローダ側 cmdline は `init=/init` 等 Android 前提のため無視させています。**rootfs は SD カード 1 番目のパーティション（ext4）**。
  変更は `CONFIG_CMDLINE` を編集して再ビルド。
- eMMC は Rockchip 独自の mtdparts でパーティション分割されており GPT ではありません。`CONFIG_CMDLINE_PARTITION` を有効にしてあるので、
  eMMC を Linux から使うなら `blkdevparts=mmcblk2:...` を cmdline に追加できます。
- 書き込みは Rockchip の一般的な手順（`rkdeveloptool` / `upgrade_tool` で `kernel`・`resource` パーティションへ）。
- 動かない場合は UART2 (1.5Mbaud) のログを確認。DTB が渡らない場合は `kernel-appended-dtb.img`（DTB 連結 + ATAG 互換）を試してください。

## 4. 未検証・要確認

1. **実機起動は未確認**（実機に接続できないため、ビルドと DTB 検証のみ）。
2. **PSCI**: vendor DT は legacy PSCI 0.1 でした。mainline の rk322x.dtsi は PSCI 0.2/1.0 を想定するため、TOS が `PSCI_VERSION` に応答しない場合 2 コア目以降が起動しない恐れがあります。
   そこで MX10 DTS では vendor と同じ 0.1 記述に上書きしています。SMP が起動しない場合は最初にここを疑ってください。
3. **LED の極性**（vendor の値 `1` は独自ドライバ解釈）。xms6 と同じ ACTIVE_HIGH にしています。
4. **SD スロット電源 (GPIO1_B6, active-low)** と **電源キー**は vendor DT からの推定です。
5. **Wi-Fi/BT チップは個体差**があります。firmware には ap6330(Broadcom)/rtl8189es/rtl8723bs/esp8089/ssv6051 用ドライバが同梱され、起動時に判別する方式です。
   実機で SDIO ID（Android なら `lsmod` / `/sys/bus/sdio/devices/*/device`）を確認してください。
   mainline で使えるのは Broadcom (`brcmfmac`, ファームウェア要)、RTL8723BS (`rtl8723bs`, staging)、RTL8723DS (`rtw88_8723ds`) など。
   **rtl8189es / esp8089 / ssv6051 は mainline に無い**ため、その個体では Wi-Fi は使えません（USB Wi-Fi を推奨）。BT の `bluetooth` ノードはチップ確定後に追加してください。
6. **メモリ量**は 1GiB と推定（`roca.mem.size=8GB1GB`）。ローダが DTB を渡す場合は DTS の値が使われるため、起動時に `Memory:` の行で確認してください。
7. **未対応**: 前面パネル VFD（3 線式、GPIO1_A0–A2。v7.2 に該当ドライバ無し）、内蔵アナログ音声 codec、IR のハードウェアデコード、
   Rockchip 独自のホット/温度ガバナ（`lkg_adjust_volt`）。HDMI 音声・映像・Ethernet・USB・SD/eMMC・GPU(lima)・VPU/RGA は mainline ドライバがある構成です。
8. 元 firmware は `userdebug/test-keys`・adb root 有効・ビルドプロパティに偽装（Android 14 表記、S905W/amlogic 表記）があります。移行後は Android 側は使わないため実害はありませんが、rootfs は必ず自分で作り直してください。
9. DTS の compatible `rockchip,rk3229-mx10` は out-of-tree 用の便宜的な名前です（upstream 化するなら実ベンダー名が必要）。

## 5. U-Boot

U-Boot (mainline v2026.07) の移行は `UBOOT.md` を参照してください。
元の idblock / trust.img は残し、`uboot` パーティションだけを差し替える方式です(実機起動は未検証)。
