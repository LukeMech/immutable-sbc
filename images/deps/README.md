# deps

Not a variant (no `[deps]` table in [`../variants.toml`](../variants.toml), no board ever runs this) --
a side image, `ghcr.io/lukemech/immutable-sbc-deps`, containing nothing but prebuilt RPMs the main
`Containerfile` bind-mounts in at `/deps-rpms` (`RUN --mount=type=bind,from=deps,source=/rpms,
target=/deps-rpms`). It's `FROM scratch`: no shell, no `rpm` binary, nothing installed in it -- just files
under `/rpms/kernel/`, `/rpms/kmods/`, `/rpms/hailort/`, copied straight out of a throwaway Fedora builder
stage. Never pulled by a booted bootc system, so none of the cosign/chunkah machinery `build.yml` uses for
the actual bootable images applies here -- see [`../../.github/workflows/build-deps.yml`](../../.github/workflows/build-deps.yml).

**Why a separate image**: kmod and HailoRT builds were the heaviest, most failure-prone part of every
image build in this repo. Building them here instead means `build.yml`'s own builds no longer pay that
cost on every push, and this image's own rebuild is gated to only when something here actually changed (an
`images/deps/` push) or on its own schedule (biweekly, one day ahead of `build.yml`'s own, so a fresh deps
image always exists before a scheduled main build picks it up).

**Contents**:

- `/rpms/kernel/` -- [`build_files/00-kernel.sh`](build_files/00-kernel.sh). The one thing here NOT pinned
  the way everything else in `versions.env` is -- it resolves whatever Fedora's current `kernel-core` is at
  build time, deliberately, so kernel security updates keep flowing without a manual pin bump every time.
  The main image's own `build_files/00-pre-build.sh` is what actually replaces `fedora-bootc:44`'s own
  floating kernel with this pinned one (the confirmed, non-deprecated `ublue-os/bazzite`+`ublue-os/ucore`
  mechanism: shim `kernel-install.d`, `rpm --erase --nodeps`, install the pinned RPMs, `dnf5 versionlock`,
  restore the hooks -- see that file's own comments), so every kmod/HailoRT build below matches the exact
  kernel this image ships.
- `/rpms/kmods/` -- [`build_files/10-aic8800.sh`](build_files/10-aic8800.sh),
  [`11-gasket.sh`](build_files/11-gasket.sh), [`20-hailo8-pci.sh`](build_files/20-hailo8-pci.sh),
  [`21-hailo1x-pci.sh`](build_files/21-hailo1x-pci.sh) -- the same Kbuild-against-`/deps-rpms/kernel`'s
  `kernel-devel`, then wrap-in-a-throwaway-rpm approach these hooks always used, just built here instead of
  inline in `images/rk3588/`/`images/rpi/`. Migrated with their original comments/verification checks
  intact -- see each file for the actual driver-specific story (radxa-pkg/aic8800's quilt patch series,
  kylegospo/gasket-dkms vs. upstream google/gasket-driver, hailo-ai/hailort-drivers' two chip generations).
- `/rpms/hailort/` -- [`build_files/30-hailort-hailo8.sh`](build_files/30-hailort-hailo8.sh),
  [`31-hailort-hailo1x.sh`](build_files/31-hailort-hailo1x.sh) -- one rpm each, covering the *whole* isolated
  `/opt/hailort-<version>` prefix: both the C++ library/CLI (protobuf-from-source, the heaviest single build
  in this repo) and the `hailo_platform` Python bindings (pybind11), which used to be a separate build step
  in the main image. The Python venv has to be built against a real, non-buildroot path (venvs bake in
  absolute paths -- shebangs, `pyvenv.cfg`, the `python3` symlink -- none of that is relocatable), so these
  hooks make the C++ build genuinely live at `${PREFIX}` first, build the venv against that real path, then
  capture the whole complete tree into the buildroot the shipped rpm is built from.

`libedgetpu` (Coral USB Accelerator runtime) stays in the main image's own
[`build_files/11-coral-accelerator.sh`](../../build_files/11-coral-accelerator.sh) -- it's pure userspace
(USB via libusb, no kernel module), so it never belonged here; only that same file's gasket/apex kmod half
moved.
