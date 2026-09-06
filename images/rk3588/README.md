# rk3588

RK3588(S)-family boards needing the AIC8800 Wi-Fi/BT combo-chip driver.
See the `[rk3588]` table in [`../variants.toml`](../variants.toml).

Built from [`ublue-os/image-template`](https://github.com/ublue-os/image-template)'s tooling, on top of a
minimal, Wayland-only GNOME session: shell, settings, a file manager and a terminal.

The onboard AIC8800D80 combo chip needs the
[`aic8800-usb-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/) COPR package for Wi-Fi/BT,
built once at container *build* time, not on the deployed read-only system. Neither the kernel module nor
its firmware ship as bare files or depend on the COPR packages surviving into the final image -- both get
pulled into one self-contained `kmod-aic8800-usb` rpm instead. See
[`build_files/10-aic8800-wifi-bt.sh`](build_files/10-aic8800-wifi-bt.sh) for the full story (tightened twice
after real-hardware testing found two ways bare/upstream-owned files were getting dropped).

[`build_files/20-mesa-teflon.sh`](build_files/20-mesa-teflon.sh) installs `mesa-libTeflon`, the TFLite
delegate for the RK3588(S) NPU (`rocket` Gallium driver) -- Rockchip-specific, so it stays a board hook here
rather than the shared [`build_files/10-prepare-npu-run-module.sh`](../../build_files/10-prepare-npu-run-module.sh) CLI it backs (that one
runs on every variant, falling back to CPU-only where there's no delegate). Exposing the NPU at the
kernel/devicetree level is handled upstream by this board's [`edk2_url`](../boards.toml) firmware instead.

**A container image** on `ghcr.io/lukemech/immutable-sbc-rk3588`, rebuilt on every push to `main` plus a
biweekly schedule (`build.yml`). `bootc upgrade` pulls updates like any bootc/ostree system. Images are
rechunked with [chunkah](https://github.com/coreos/chunkah) rather than `rpm-ostree compose build-chunked-oci`,
which was implicated in one of the two dropped-file bugs above.
