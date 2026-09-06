# rock5

RK3588(S)-family boards needing the AIC8800 Wi-Fi/BT combo-chip driver.
See the `[rock5]` table in [`../variants.toml`](../variants.toml).

Built from [`ublue-os/image-template`](https://github.com/ublue-os/image-template)'s tooling, on top of a
minimal, Wayland-only GNOME session: shell, settings, a file manager and a terminal.

The onboard AIC8800D80 combo chip needs the
[`aic8800-usb-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/) COPR package for Wi-Fi/BT,
built once at container *build* time in a writable layer, not on the deployed read-only system. Neither the
kernel module nor its firmware ship as bare files or depend on the upstream COPR packages surviving into the
final image -- both get pulled into one self-contained `kmod-aic8800-usb` rpm instead. See
[`build_files/10-aic8800-wifi-bt.sh`](build_files/10-aic8800-wifi-bt.sh) for the full story (tightened twice
after real-hardware testing found two separate ways bare/upstream-owned files were getting dropped).

[`build_files/20-mesa-teflon.sh`](build_files/20-mesa-teflon.sh) installs `mesa-libTeflon`, Mesa's TensorFlow
Lite delegate for the RK3588(S) NPU (`teflon` frontend, `rocket` Gallium driver) -- the userspace side of using
the NPU. Exposing the NPU at the kernel/devicetree level is handled upstream instead, by this board's
[`edk2_url`](../boards.toml) firmware rather than a kernel-side devicetree patch.

[`build_files/21-npu-run.sh`](build_files/21-npu-run.sh) installs `npu-run`, a CLI that reports whether
`/dev/accel/accel0` is present and, by default, runs a COCO object detector (SSD MobileNetV1, quantized) on a
dashcam photo through Teflon's NPU delegate alone -- printing what it found (car, person, bicycle, traffic
light, ...), the inference time, and saving an annotated copy (previewed inline via `chafa` when it's
installed, which it is here). `--check` also runs the same model on CPU and prints both for comparison;
`--benchmark N` instead measures N-iteration throughput (FPS) per backend, running CPU and NPU concurrently
by default (a mixed-workload number) or one after another with `--isolate` (a clean per-backend number).
`--image`/`--model`/`--labels`/`--delegate`/`--output` swap in your own files instead of the bundled
defaults, and `--threads` sets how many CPU threads the CPU-side run gets (defaults to all cores -- the
interpreter defaults to one otherwise). Reading `dmesg` needs root (Fedora's default
`kernel.dmesg_restrict`), so run as `sudo npu-run` to see rocket's own kernel log lines.

**A container image** on `ghcr.io/lukemech/immutable-sbc-rock5`, rebuilt on every push to `main` plus a
biweekly schedule (`build.yml`) as a fallback for quiet periods. Once installed, `bootc upgrade` pulls updates
like any bootc/ostree system -- no reflashing required. Images are rechunked with
[chunkah](https://github.com/coreos/chunkah) rather than `rpm-ostree compose build-chunked-oci`, which was
implicated in one of the two dropped-file bugs above.
