# rk3588

RK3588(S)-family boards needing the AIC8800 Wi-Fi/BT combo-chip driver.
See the `[rk3588]` table in [`../variants.toml`](../variants.toml).

Built from [`ublue-os/image-template`](https://github.com/ublue-os/image-template)'s tooling, on top of a
minimal, Wayland-only GNOME session: shell, settings, a file manager and a terminal.

The onboard AIC8800D80 combo chip needs its Wi-Fi/BT kernel modules and firmware, built directly from
[`radxa-pkg/aic8800`](https://github.com/radxa-pkg/aic8800)'s USB driver tree (pinned commit, see
`images/deps/versions.env`) -- no DKMS involved, even though upstream's own Debian packaging wraps this in
one. Neither the kernel modules nor their firmware ship as bare files or depend on that source tree
surviving into any image -- both get pulled into one self-contained `kmod-aic8800-usb` rpm instead, built in
[`images/deps/`](../deps/) (see [`images/deps/build_files/10-aic8800.sh`](../deps/build_files/10-aic8800.sh)
for the full story -- packaging this way was tightened twice already, after real-hardware testing found two
ways bare/upstream-owned files were getting dropped) and just installed here by
[`build_files/10-aic8800-wifi-bt.sh`](build_files/10-aic8800-wifi-bt.sh). See
[`images/deps/README.md`](../deps/README.md) for why the build itself lives there instead of in this image.

[`build_files/20-mesa-teflon.sh`](build_files/20-mesa-teflon.sh) installs `mesa-libTeflon`, the TFLite
delegate for the RK3588(S) NPU (`rocket` Gallium driver) -- Rockchip-specific, so it stays a board hook here
rather than the shared [`build_files/10-prepare-npu-run-module.sh`](../../build_files/10-prepare-npu-run-module.sh) CLI it backs (that one
runs on every variant, falling back to CPU-only where there's no delegate). Exposing the NPU at the
kernel/devicetree level is handled upstream by this board's [`edk2_url`](../boards.toml) firmware instead.

**A container image** on `ghcr.io/lukemech/immutable-sbc-rk3588`, rebuilt on every push to `main` plus a
biweekly schedule (`build.yml`). `bootc upgrade` pulls updates like any bootc/ostree system. Images are
rechunked with [chunkah](https://github.com/coreos/chunkah) rather than `rpm-ostree compose build-chunked-oci`,
which was implicated in one of the two dropped-file bugs above.

`system_files/usr/bin/install-internal` clones whatever disk this system is currently booted from (normally
a microSD) onto a second internal disk (the eMMC socket rock-5c boards have) -- sector-for-sector identical
GPT/firmware/partitions, so the eMMC boots exactly like the SD card already does; `growroot.service` handles
the eMMC being a different size on its own next boot, same as it already does for the SD card. rk3588-only:
rpi boards have no second internal disk to install onto.
