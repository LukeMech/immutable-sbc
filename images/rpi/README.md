# rpi

Raspberry Pi boards. See the `[rpi]` table in [`../variants.toml`](../variants.toml).

Built from [`ublue-os/image-template`](https://github.com/ublue-os/image-template)'s tooling, on top of a
minimal, Wayland-only GNOME session.

No AIC8800-style driver hook needed for Wi-Fi/BT: the Pi 4B/5's Broadcom chips (`brcmfmac`) and GPU/display
are upstream in mainline Linux, firmware already in Fedora's `linux-firmware`.

No built-in NPU, unlike [`rk3588`](../rk3588/README.md) -- `npu-run` (shared across variants) runs CPU-only
here, since `mesa-libTeflon` is Rockchip/rocket-specific and stays an rk3588-only build hook. A Coral USB
Accelerator works via `npu-run --delegate /usr/lib64/libedgetpu.so.1` instead (see the top-level
[README](../../README.md)'s repo-layout table for `libedgetpu`/`gasket`-`apex` -- generic, not rpi-specific,
since Coral is a USB/PCIe peripheral rather than a property of the board).

Two optional Hailo NPU HATs, each its own driver hook and kernel module -- different chip generations, on
separate upstream branches that don't share a driver:

- [`build_files/10-hailo8-pcie-driver.sh`](build_files/10-hailo8-pcie-driver.sh) +
  [`build_files/20-hailort-hailo8.sh`](build_files/20-hailort-hailo8.sh): the original AI HAT+/Kit
  (Hailo-8/8L). Kernel module `hailo_pci` from [`hailo-ai/hailort-drivers`](https://github.com/hailo-ai/hailort-drivers)'s
  `hailo8` branch (frozen at v4.24.0), device node `/dev/hailoN`, ~150 KiB firmware blob. Userspace runtime
  (`libhailort`/`hailortcli-hailo8`) from `hailo-ai/hailort`'s matching v4.24.0 tag.
- [`build_files/11-hailo1x-pcie-driver.sh`](build_files/11-hailo1x-pcie-driver.sh) +
  [`build_files/21-hailort-hailo1x.sh`](build_files/21-hailort-hailo1x.sh): AI HAT+ 2 (Hailo-10H, released
  Jan 2026). Kernel module `hailo1x_pci` from the same driver repo's `master` branch (v5.4.0 -- unrelated to
  and not a newer version of the hailo8 branch above), device node `/dev/h1x-N`. Firmware is a full
  U-Boot+kernel+rootfs bundle the chip boots as its own embedded OS (for on-chip LLM/VLM inference) -- ~38 MiB
  download, ~115 MiB installed. Userspace runtime from `hailo-ai/hailort`'s matching v5.4.0 tag.

Drivers: GPL-2.0, pinned commit (no COPR/DKMS package exists), driver + firmware only, packaged the same
self-contained-rpm way as rk3588's `kmod-aic8800-usb` -- no bare files, no build-time-only package surviving
into the image. Neither shows up under `/dev/accel` -- Hailo doesn't use the kernel's DRM accel subsystem,
each chip registers its own character-device class instead.

HailoRT (MIT-licensed): the two versions are incompatible and can't share one `libhailort.so`/`hailortcli`,
so each installs under its own isolated prefix (`/opt/hailort-4.24.0`, `/opt/hailort-5.4.0`), reachable via
the `hailortcli-hailo8`/`hailortcli-hailo1x` symlinks in `/usr/bin`. By far the heaviest build hooks in this
repo -- CMake fetches and compiles Google's protobuf from source itself (no system package, and that fetch
isn't sha256-pinned by us -- it's their build tooling's own git clone, outside our control), on top of
HailoRT's own sizeable C++ codebase, twice over. Both hooks build with a pinned, vendored CMake
(`versions.env`) rather than Fedora's own package -- these builds are version-locked forever, so a future
Fedora cmake release breaking something here would have no upstream fix to re-pin to. This gets the runtime installed and callable, but doesn't
wire it into `npu-run` -- Hailo has no standard TFLite delegate (there's an open upstream request for one,
unresolved), so using it means `hailortcli`/`libhailort`'s own API directly, not `npu-run --delegate`.

Everything Hailo-related here is entirely untested on real hardware, the HailoRT builds most of all -- they've
never been compiled even once, let alone run.

UEFI firmware is board-specific, same as `rk3588`, but installed differently: a Pi's EEPROM bootloader just
wants a FAT32 first partition, the same one bootc-image-builder already makes the ESP, so
[`compose-sdcard-image.sh`](../../scripts/compose-sdcard-image.sh) copies firmware into that filesystem
(`firmware_layout = "fat"`) instead of dd'ing it to a fixed offset like RK3588's `"raw"` -- no GPT surgery
needed.

**A container image** on `ghcr.io/lukemech/immutable-sbc-rpi`, rebuilt on every push to `main` plus a
biweekly schedule (`build.yml`). `bootc upgrade` pulls updates like any bootc/ostree system.
