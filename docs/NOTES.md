# 実機で分かったこと (2026-10-09/10)

## Linux: HDMI 初期化で止まる → PD_VIO の電源ドメイン
- 症状: `dwhdmi-rockchip 200a0000.hdmi: supply avdd-1v8 not found, using dummy regulator` を最後にハング。
- 原因: HDMI コントローラ (0x200a0000) は PD_VIO にあり、RK322x のパワードメインは idle 要求のみ (GRF 0x40c = req, 0x488 = ack)。
  ブートローダが PD_VIO を idle のままにすると、`dw_hdmi_probe()` の最初のレジスタ読み出しでバスが止まる。
- 対策: `rk322x.dtsi` の `hdmi@200a0000` に `power-domains = <&power RK3228_PD_VIO>;` を追加
  (コミット "ARM: dts: rockchip: rk322x: Add the VIO power domain to the HDMI node")。デバイス probe 時に genpd が電源を入れる。
- 切り分けに使った手法: `dw-hdmi.c` にチェックポイントの `pr_info` を入れ、GRF/CRU のレジスタをダンプ。
  `clk_ignore_unused pd_ignore_unused` (extlinux の `alpine-safe`) でも回避できる。

## U-Boot: USB キーボード (Apple Magic Keyboard 2024, 05ac:0320)
- フルスピード機器はルートポートの OHCI コンパニオン (`usb@300a0000`) に接続される。
- このキーボードは interface 0 が "Device Management"、interface 1 が Boot Keyboard。
  DM USB のドライバ照合は interface 0 とデバイス ID しか見ないため、デバイス ID を `kbd_id_table` に載せる必要がある
  (コミット "usb: kbd: Bind the 2024 USB-C Apple Magic Keyboards by device ID")。載せないと `usb_dev_generic_drv` に束縛され、`stdin` に `usbkbd` が出ない。
- Apple キーボードの `USB_HID_QUIRK_POLL_NO_REPORT_IDLE` は、割り込みキュー作成の前に return していた。
  `CONFIG_SYS_USB_EVENT_POLL_VIA_INT_QUEUE` と組み合わせるとキューが無いままになる (コミット "usb: kbd: Create the interrupt queue ...")。
- OHCI の `submit_common_msg` は nonblock を無視し、常に 0 を返す (状態は `dev->status`)。
  nonblock 扱いの制御転送ポーリング (`SYS_USB_EVENT_POLL`) は不向きなので、割り込みキュー方式を選んだ。
- キー入力が約 1/3 欠ける問題: OHCI の割り込みキューが DMA バッファのキャッシュを無効化していなかった (コミット "usb: ohci: Do cache maintenance ...")。修正後は欠けなくなった。

## ビルド環境の注意
- Mac (APFS 大文字小文字非区別) 上に Linux ツリーを置くと、`xt_CONNMARK.h` と `xt_connmark.h` のような名前衝突で
  `git status` が常に dirty になる。Docker ボリューム内の clone でビルドするのはこのため (`docker/build-kernel.sh`)。
