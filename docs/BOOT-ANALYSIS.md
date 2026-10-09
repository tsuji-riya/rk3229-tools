# RK3229 (MX10) ブート仕様の解析と USB ブート設計 (2026-10-09)

対象は `UBOOT.md` / `MIGRATION.md` と同じ実機(MX10 系 RK3229 TV box、DDR3 1GiB、eMMC 8GiB)です。
「USB メモリから U-Boot と Linux を起動したい」という要望に対し、まず起動の仕組みを `nand_full_dump.img`、
ベンダー `uboot.img` / `trust.img`、mainline U-Boot v2026.07 のソースから読み取り、その結果に合わせてイメージを設計しました。

> **追記 (2026-10-10): SD カードからの起動、U-Boot の HDMI 出力と USB キーボード、Linux の HDMI 出力は実機で確認済みです。** 以降の本文の「未検証」は作成時点(10-09)の記述です。実機で分かったことは `NOTES.md` を参照。
>
> **(以下は作成時点の注記)** 実機での起動は未検証です。 本文の各項に「根拠」と「未確認」を分けて書いています。

## 1. 結論

1. **RK3229 の BootROM は USB メモリ(mass storage)から起動できません。** USB は OTG ポートの maskrom(PC からの書き込み専用 download モード)だけです。
2. **一方、SD カードは BootROM が直接起動できます。** 内蔵フラッシュに Android が入っていても、SD に有効な idblock があれば SD から起動する
   (Multitool for RK3228/RK3229 の実績。利用者の報告と、Multitool の SD イメージ構成の両方で確認)。
   当初「SD が先に見られるのは内蔵に有効なローダが無い時だけ」と書きましたが、Armbian フォーラムの一般論に頼りすぎた誤りで、撤回します。
   BootROM が SD を eMMC/NAND より先に見るのか、Multitool が別の仕掛けを使っているのかは**ソースでは未確認**ですが、実績は SD の idblock が優先されることを示します。
3. したがって起動経路は 2 つです。
   - **A. SD カード単体(推奨・内蔵フラッシュに一切書かない):** SD に idblock(sector 0x40)+ `uboot`(0x4000)+ `trust`(0x6000)+ Linux を入れる。
     BootROM → SD の idblock → 我々の mainline U-Boot → SD 上の Linux。
   - **B. eMMC の `uboot` パーティションを差し替え + USB メモリ:** eMMC 上の U-Boot が USB メモリから Linux を読む。
     eMMC への書き込みが 1 回要る。USB メモリだけを使う運用はこちら。
   A の SD に U-Boot を入れておけば、**SD(ローダ専用)+ USB メモリ(システム)** の組み合わせにもなります
   (`boot_targets` が `usb mmc0 mmc2` なので USB を先に探す)。
4. eMMC の idblock(DDR 初期化 + miniloader)と `trust`(TOS)は**触りません**(B でも `uboot` パーティションだけ)。

## 2. 起動チェーン(この実機)

```
BootROM ──▶ idblock ──────▶ miniloader ──▶ trust(TOS) ──▶ uboot ──▶ kernel
 (SoC内)    (DDR初期化+      (idblockの       OP-TEE          (非セキュア側)
            miniloader)      一部)           0x68400000       0x60000000 / 0x61000000
```

| 段 | 場所 | 中身 | 根拠 |
|---|---|---|---|
| BootROM | SoC 内 | 内蔵メモリから idblock を読む。見つからない時は USB OTG の maskrom | U-Boot `bootrom.h` の `BROM_BOOTSOURCE_*`(NAND, eMMC, SPI NOR, SPI NAND, SD, …, USB)、`rockchip.rst`(BootROM はすべて失敗すると USB OTG の BootROM モードに入る) |
| idblock | sector 64 (0x40) | ヘッダ `0x0FF0AA55` + `"RK32"`。DDR 初期化ブロブ + miniloader(RK322x は RC4 なし、最大 0x7000 バイト) | U-Boot `tools/rkcommon.c`(`rk322x`: `"RK32"`, `spl_rc4=false`, `0x8000-0x1000`) |
| trust | eMMC sector 0x4000 | `TOS` コンテナ。中身は **OP-TEE**(`TEE-CORE`、`TEE_PAGER`)。ロード先 `0x68400000` | `extracted/trust.img` ヘッダ(addr=0x68400000, size=0x51788)と strings |
| uboot | eMMC sector 0x2000(4 MiB) | `LOADER` コンテナ。ロード先 `0x60000000`、サイズ 386,312 B、CRC32(多項式 0x04c10db7)+ SHA-256。1 MiB 間隔で 4 コピー | `extracted/uboot.img` ヘッダ。`rk-pack.py loader-info` で再生成が**バイト一致** |
| ベンダー U-Boot | 上記の中身 | `U-Boot 2014.10-RK322X-06 (Jan 06 2025)`、`bootcmd=bootrk`、`bootdelay=0`。`kernel`/`boot`(KRNL)と `resource`(RSCE: `rk-kernel.dtb`)を読む | strings。USB は**ガジェット側のみ**(rockusb/fastboot/MUSB UDC)で、`usb start` もマスストレージも無い |
| パラメータ | eMMC sector 0, 0x400, … | `PARM`。`KERNEL_IMG 0x60408000`, `ATAG 0x60000800`, mtdparts(下表) | `nand_full_dump.img` 先頭(4 コピーのみ非ゼロ) |

eMMC のパーティション(sector): uboot 0x2000, trust 0x4000, misc 0x8000, baseparamer 0xA000, resource 0xA800,
kernel 0x12000, boot 0x18000, recovery 0x22000, backup 0x32000, cache 0x52000, metadata 0x92000, kpanic 0x9A000,
system 0x9C000, userdata 0x49C000。

### idblock について分かっていること・分からないこと

- ダンプの **sector 64 は全ゼロ**で、先頭 512 MiB を 512 バイト境界で走査しても idblock ヘッダ(`55 AA F0 0F`)は
  **1 つも見つかりません**。ただしこの実機は Android で起動するので、idblock は**ダンプでは読めない領域**にあります
  (ダンプ手段がその領域を見せていない、または eMMC の別領域にある、などが考えられますが**未確認**)。
- そのため idblock は**バックアップも復元もできません**。この設計が idblock に一切触れないのはこのためです。
- 参考: Rockchip の公式ローダ定義(`rkbin/RKBOOT/RK322XMINIALL.ini`)では、DDR 初期化が `rk322x_ddr_300MHz_v1.10.bin`、
  miniloader が `rk322x_miniloader_v2.56.bin`、maskrom 用の USB プラグが `rk322x_usbplug_v2.56.bin` です。

## 3. USB の扱い(何が出来て何が出来ないか)

| 経路 | 可否 | 説明 |
|---|---|---|
| BootROM が USB メモリから idblock を読む | **不可** | BootROM の USB は maskrom(PC から `rkdeveloptool` で書き込む用) |
| ベンダー U-Boot が USB メモリから起動 | **不可** | USB ホスト / マスストレージのコードが無い(strings で確認) |
| **mainline U-Boot(eMMC)が USB メモリから起動** | **可(今回実装、ビルド検証のみ)** | 下の 4 章 |
| maskrom + USB OTG で RAM から U-Boot を起動(eMMC 書き込み無し) | 理論上可 | `u-boot-rockchip-usb471/472.bin`(binman)の仕組みはあるが、DDR ブロブが必要。**作っていない** |
| **SD カードから U-Boot ごと起動(内蔵に書かない)** | **可(今回実装、構造検証のみ)** | Multitool と同じ配置(下の 3.1)。idblock は Multitool 同梱のバイナリを使用 |

### 3.1 SD の配置(Multitool `boot_install` と同一)

| sector | 内容 | 出所 |
|---|---|---|
| 0x40 | `idbloader_ddr_1.11.img`(DDR 初期化 + miniloader、100 KiB) | Multitool 同梱の Rockchip バイナリ(`loader/` に同梱、由来は `loader/README.md`) |
| 0x4000 | `uboot.img`(LOADER、ロード先 0x61000000、4 MiB) | 我々の mainline U-Boot。Rockchip の `loaderimage` の出力と**バイト一致**を確認 |
| 0x6000 | trust(TOS、ロード先 0x68400000、4 MiB = 1 MiB×4 コピー) | この箱自身の `trust.img` の先頭 4 MiB(`loaderimage --pack --trustos` の出力と一致) |
| 0x8000〜 | p1 FAT32 / p2 ext4 | Alpine |

- TOS にはこの箱のベンダー版(legacy PSCI 0.1)をそのまま使います。DTS の PSCI 記述がそれを前提にしているためです。
  Multitool 既定の OP-TEE 4.5.0 に替える場合は DTS の PSCI を戻す必要があります。
- 我々の U-Boot の `TEXT_BASE=0x61000000` と TOS の `0x68400000` は、Multitool の `UBOOT_ADDR` / `TRUST_ADDR` と同じです。
- DRAM 初期化は Multitool の idbloader(DDR ブロブ)が行います。この箱の元の idblock とは別物なので、DRAM 容量の認識は実機で要確認です。

## 4. U-Boot の変更(`tsuji-riya/u-boot` の `rk3229` ブランチ参照)

`UBOOT.md` には「rk322x 用 USB2 PHY ドライバが無い」とありましたが、v2026.07 に取り込み済みの Armbian パッチ(0006/0009)で
`phy-rockchip-inno-usb2.c` に **`rockchip,rk3228-usb2phy`** の設定が入っており、EHCI の reset 指定も `rk322x-u-boot.dtsi` にあります。
足りなかったのは **MX10 の defconfig で有効にしていなかったこと**だけでした。

`mx10-rk3229_defconfig` に追加:

- `CONFIG_DM_RESET`, `CONFIG_PHY_ROCKCHIP_INNO_USB2`, `CONFIG_DM_REGULATOR_FIXED`
- `CONFIG_USB_EHCI_HCD/GENERIC`, `CONFIG_USB_OHCI_HCD/GENERIC`(低速デバイスはコンパニオン OHCI に回るため)
- `CONFIG_USB_STORAGE`, `CONFIG_USB_KEYBOARD`, `CONFIG_CMD_USB`
- `CONFIG_SYS_MALLOC_F_LEN=0x4000`(下の 9 章: 実機ログで判明した必須の修正)

`include/configs/mx10_rk3229.h`: `BOOT_TARGETS` を `"usb mmc0 mmc2"` に変更(USB → SD → eMMC の順)。
`preboot=usb start` は既存の `CONFIG_USE_PREBOOT` により入ります。

VBUS(GPIO3_C4, `vcc_host`)は DTS で `regulator-boot-on` / `regulator-always-on` なので、U-Boot の DM が bind 後に自動で ON にします
(`regulator-uclass.c`: `DM_FLAG_PROBE_AFTER_BIND`)。

ビルド結果: `u-boot.bin` 537,584 バイト(1 MiB スロットの上限内)、`uboot.img` は 4 コピーとも CRC OK。

## 5. Linux 側の変更

- `CONFIG_CMDLINE_FORCE` をやめ、**ブートローダ(extlinux の `append`)から cmdline を受け取る**ようにしました
  (`CMDLINE_FROM_BOOTLOADER`)。固定の `root=/dev/mmcblk0p1` では USB から起動できないためです。
  **この変更で、ベンダーローダが `kernel` パーティションのカーネルを直接起動する旧経路(Android の cmdline が渡る)は使えなくなります。**
  今後の起動は U-Boot 経由を前提にしています。
- DTS に **TOS 用 `reserved-memory`**(`0x68400000`, 2 MiB, `no-map`)を追加(`UBOOT.md` 6 章の未確認事項 4)。
  OP-TEE が保護する範囲は EVB と同じと仮定した値で、実際の範囲は未確認です。
- ルートは `root=PARTUUID=52334b32-02`(MBR のディスク署名を固定)。USB の認識順が変わっても追従します。

## 6. USB スティックのレイアウト

| 範囲 | 内容 |
|---|---|
| sector 0 | MBR(ディスク署名 `0x52334b32`) |
| sector 64 〜 32767(16 MiB) | SD 起動用ローダ: idblock@0x40、uboot@0x4000、trust@0x6000(3.1 章)。**USB メモリとして使うときは BootROM に読まれないので無害** |
| p1: sector 32768〜(64 MiB, FAT32, `RK3229BOOT`) | `/extlinux/extlinux.conf`, `/zImage`, `/rk3229-mx10.dtb`, `/rk3229/uboot.img` |
| p2: 80 MiB〜(ext4, `alpine-root`) | Alpine Linux 3.24.2 armv7 minirootfs + 起動スクリプト + カーネルモジュール |

U-Boot の標準ブート(bootstd)は p1 の `/extlinux/extlinux.conf` を見つけて、`kernel_addr_r=0x62000000` / `fdt_addr_r=0x61f00000` に読み込みます。
FAT32 なので、PC(macOS / Windows)からそのまま `extlinux.conf` を編集できます。

## 7. 未検証・リスク

1. **実機起動は未確認。** USB ホストの動作(PHY / クロック / リセット / VBUS)は、ビルドと設定の整合性しか確認していません。
2. **DRAM 容量**(`UBOOT.md` 6 章 2): U-Boot は GRF `os_reg2` から容量を読みます。DDR ブロブの設定次第で `DRAM:` の表示が変わります。
3. **ロードアドレス 0x61000000**(同 3): ベンダーは 0x60000000。起動しないときは `CONFIG_TEXT_BASE` と `rk-pack.py --addr` を 0x60000000 に揃えて試してください。
4. **セキュアブート**: ベンダー U-Boot に `loader's key not match` / `Secure Boot find rsa key` の文字列があります。
   この機種が eFuse でセキュアブートを有効にしている場合、署名のない `uboot.img` は起動しません(量販 TV box では通常無効)。**未確認。**
5. **TOS の保護範囲**: 5 章の `reserved-memory` は推定です。
6. **USB スティックの相性**: 起動直後は VBUS 立ち上がり待ちなどで、遅い USB メモリを認識しないことがあります
   (U-Boot で `usb reset` → `bootflow scan` を手で実行して切り分け)。
7. **同じイメージを SD と USB の両方に書いて同時に挿さない**: 両方に `PARTUUID=52334b32-02` があるとルートが曖昧になります。
   別々のイメージにするか、片方の MBR ディスク署名(`sfdisk --disk-id`)と `extlinux.conf` の `root=` を変えてください。
8. **SD 起動(経路 A)の BootROM 優先順位**は、ソースでは確認できていません(利用者の Multitool の実績に依拠)。
9. **Ethernet / HDMI** は U-Boot では未対応のまま(Linux 側は mainline ドライバあり)。ネットワークブートは不可です。

## 8. 初回起動の確認手順(UART2, 1,500,000 baud, 8N1)

1. 経路 A なら SD カードにイメージを書いて挿す。経路 B なら `uboot-usb.img` を eMMC に書く(`README.md`)。電源を入れると**前面の青 LED が点灯**し、赤は消灯します。
2. U-Boot のログに `Bus usb@...: ... scanning bus ... for devices... N USB Device(s) found` が出る。
3. `scanning bus for devices` の後に `Found /extlinux/extlinux.conf` と、メニュー(`1: Alpine Linux (Linux 7.2)`)が出る。
4. Linux が起動し、`Waiting for root device PARTUUID=52334b32-02...` を経て、`rk3229 login:` が出る(root / alpine)。

つまずいたときの切り分け:

| 症状 | 見る所 |
|---|---|
| U-Boot のログが出ない / 青 LED が点かない | `uboot.img` の書き込み、ロードアドレス(7 章 3)。書き戻し: `wl 0x2000 extracted/uboot.img` |
| `0 USB Device(s) found` | VBUS(GPIO3_C4)、`usb reset` 再試行、別のポート |
| USB は見えるが extlinux が無い | `usb part`、`ls usb 0:1 /extlinux`(FAT32 のパーティション 1 か) |
| カーネルが `Starting kernel ...` で止まる | `debug` エントリ(earlycon)。DTB / DRAM / TOS 領域(7 章 2, 5) |
| `VFS: Unable to mount root fs` | USB ホストの認識待ち(`rootwait` 済み)。`PARTUUID` の一致 |

## 9. 実機ログからの分かったこと(初回の SD 起動、2026-10-10)

SD から起動した最初のログ(抜粋):

```
DDR Version V1.11 20200910_dbg ... 300MHz  LPDDR3  Bus Width=32 Col=10 Bank=8 Row=15 CS=1 Size=1024MB
Boot1 Release Time: Sep 29 2018 16:04:10, version: 2.53
mmc2: UserCapSize=7456MB  BootCapSize=2000        <- eMMC (8 GB)
mmc0: UserCapSize=59344MB                          <- SD
LOADER Check OK! 0x61000000, ...   TOS Check OK! 0x68400000, ...   Enter Trust OS
INF TEE-CORE:init_teecore:79: teecore inits done
alloc space exhausted ptr 830 limit 800
initcall_run_f(): initcall initf_dm() failed
```

- **SD からの BootROM 起動は成功**: Multitool の idbloader で DDR 初期化(**LPDDR3** 1024 MB、32bit、300 MHz)、miniloader が SD から LOADER と TOS を検証して OP-TEE に入るところまで動作。
  3.1 章の SD 配置と、`0x61000000` / `0x68400000` のロードアドレスは正しいことが確認できました。
- **メモリは LPDDR3**(DDR3 ではない)。`MIGRATION.md` の「DDR3 1GiB」は訂正が必要です。
- **内蔵は NAND ではなく eMMC**(`mmc2`、7456 MB)。`BootCapSize=2000`(= 4 MiB)は eMMC の**ハードウェアブートパーティション**の大きさで、
  元の idblock はここにある可能性があります(ダンプのユーザー領域に無かった理由として整合的。**未確認**)。
- **U-Boot は初期化で停止**: 再配置前の malloc 領域(`CONFIG_SYS_MALLOC_F_LEN`、rk322x の既定 0x800)が不足。
  USB / reset / regulator のドライバを足した私の変更が原因でした。`rk322x-box_defconfig` と同じ方向で 0x4000 に増やして修正しました
  (初回イメージの `uboot.img` は未修正版。以降は修正版)。

## 10. HDMI 出力(U-Boot と Linux、2026-10-10)

> **ビルドと設定の整合性のみ確認。HDMI の実画面は未検証です。**

### Linux
- 欠けていたのは **`CONFIG_PHY_ROCKCHIP_INNO_HDMI`**(RK3228 の HDMI PHY ドライバ)だけでした。未選択のままだと `rk3228-dw-hdmi` が PHY を待って
  プローブされず、画面が出ません。`=y`(組み込み)にしました。DRM / VOP / dw-hdmi / IOMMU / fbcon は元から有効で、DTS も `&hdmi` `&hdmi_phy` `&vop` `&vop_mmu` が `okay` です。
- cmdline は `console=tty1 console=ttyS2,...` で、カーネルのログは HDMI(fbcon)とシリアルの両方に出ます。`/dev/console` はシリアル、`tty1` には getty が立ちます(USB キーボードで操作可)。

### U-Boot
- ドライバ(`rk3228_hdmi.c`、`rk3228_vop.c`、`phy-rockchip-inno-hdmi.c`)は Armbian パッチ 0001〜0005 で取り込み済みでしたが、MX10 では無効でした。
  `rk322x-box_defconfig` に倣って次を追加: `VIDEO`、`DISPLAY`、`VIDEO_ROCKCHIP`、`DISPLAY_ROCKCHIP_HDMI`、`PHY_ROCKCHIP_INNO_HDMI`(`BACKLIGHT_PWM` と `PANEL` は無効のまま)。
- DTS(`rk3229-mx10-u-boot.dtsi`): `&hdmi` の `assigned-clocks` / `assigned-clock-parents` を削除(U-Boot のクロックドライバが親クロックを扱えないため)。
  `&vop` に `bootph-all`(フレームバッファを再配置前に確保するため。これも初期 malloc を増やした理由の 1 つ)。
- 環境変数: `stdin=serial,usbkbd`、`stdout=serial,vidconsole`、`stderr=serial,vidconsole`。シリアルと HDMI の両方に U-Boot の出力とブートメニューが出ます。
- フレームバッファは最大 3840×2160(約 33 MiB)を DRAM の末尾に確保します。EDID の最初の詳細タイミング(多くは TV の推奨解像度)で出力します。

### 確認したこと
- U-Boot: 警告なしでビルド、`u-boot.bin` 578,952 バイト(1 MiB スロットに収まる)、DTB の HDMI に `assigned-clocks` が無く VOP が `bootph-all` であること。
- Linux: 警告なしでビルド、`vmlinux` に HDMI PHY / dw-hdmi / VOP ドライバが組み込まれていること。

### 未検証・注意
1. RK3228 の HDMI は最大 4K@30 程度です。**4K TV の先頭タイミングが 4K@60 だと映らない**可能性があります。その場合は 1080p のモニタで確認してください(U-Boot で解像度を固定する手段は未実装)。
2. U-Boot の HDMI 初期化は、このクロックドライバと Armbian パッチの組み合わせです。画面が出なくても、**シリアルの出力は変わらず出る**ので起動自体は進みます。
3. HDMI 音声(I2S0 → dw-hdmi)は DTS にありますが、動作は未確認です。
