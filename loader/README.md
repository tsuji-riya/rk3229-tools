# loader/ -- first-stage loader for booting this image from an SD card

`idbloader_ddr_1.11.img` (102,400 bytes) is the Rockchip RK322x idblock (DDR init + miniloader, written to sector 64).
It is a prebuilt Rockchip binary taken unmodified from
<https://github.com/paolosabatino/multitool> (`sources/rk322x/idbloader_ddr_1.11.img`, commit d7dc392).
The Multitool project uses it to boot RK3228/RK3229 TV boxes from SD regardless of the internal flash.

SD layout written by `scripts/build-image.sh` (same as Multitool's `boot_install`):

| sector | content |
|---|---|
| 0x40 (64) | `idbloader_ddr_1.11.img` |
| 0x4000 | `uboot.img` (LOADER container, load addr 0x61000000) -- our mainline U-Boot |
| 0x6000 | trust image (TOS container, load addr 0x68400000, 4 x 1 MiB copies) -- the first 4 MiB of the box's own `trust.img` |
| 0x8000 | p1 FAT32 `RK3229BOOT`, p2 ext4 `alpine-root` |
