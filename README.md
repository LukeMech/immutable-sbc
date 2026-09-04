# immutable-sbc

A [Universal Blue](https://universal-blue.org/)-style, OTA-updatable,
minimal GNOME [bootc](https://containers.github.io/bootc/) image builder
for single-board computers. Everything lives under [`images/`](images/):

- **A variant** (`images/<variant>/`, e.g. [`images/rock5/`](images/rock5/))
  is a shared OSTree/container image variant -- what
  [`build.yml`](.github/workflows/build.yml) matrixes over. It's a real
  directory, since it can bundle actual build hook scripts and
  `system_files/` overlays. Package name is always `immutable-sbc-<variant>`.
- **A board** (a `[boards.<board>]` table in [`images/boards.toml`](images/boards.toml))
  is one physical, flashable board -- what
  [`build-flash.yml`](.github/workflows/build-flash.yml) matrixes over.
  Its config never needs more than a few fields plus maybe a firmware
  blob's URL/checksum, so every board is just a table in one shared file
  rather than its own directory. Each board picks which variant's image
  to flash and declares its own disk layout and (if needed) firmware.

A variant isn't tied to one board: multiple boards can share a variant if
they need identical OS content but different disk layouts. Today there's
one of each:

## rock5: RK3588(S) boards needing the AIC8800 Wi-Fi/BT driver

See [`images/rock5/variant.toml`](images/rock5/variant.toml). Built from
[`ublue-os/image-template`](https://github.com/ublue-os/image-template)'s
tooling, extended with a DKMS-built Wi-Fi/Bluetooth driver baked into the
image at build time (the onboard AIC8800D80 combo chip needs the
[`aic8800-usb-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/)
COPR package -- built once, at container *build* time in a writable
layer, not on the deployed read-only system, then repackaged as a
`kmod-*` rpm rather than a bare `dkms install`, so it's rpm-database
tracked and survives the `rpm-ostree compose build-chunked-oci`
rechunking pass in `build.yml`; see
[`images/rock5/10-aic8800-wifi-bt.sh`](images/rock5/10-aic8800-wifi-bt.sh)).

**A container image** on `ghcr.io/lukemech/immutable-sbc-rock5`, rebuilt
nightly and on every push to `main`. Once installed, `bootc upgrade` pulls
updates the same way any bootc/ostree system does -- no reflashing
required.

## rock-5c: Radxa ROCK 5C (RK3588S)

See the `[boards.rock-5c]` table in [`images/boards.toml`](images/boards.toml).
Flashes the `rock5` variant above.

### What you get

- **A microSD/eMMC image** (`.raw`, zstd-compressed) -- the primary way to
  get this onto a bare board. Built on demand via the *Build flash image*
  workflow, or attached to a [Release](../../releases) when a `vX.Y.Z` tag
  is pushed.
- **A qcow2 image**, for testing in a VM before touching real hardware.
- **An ISO**, for local (re)installs -- see the caveat below before you
  reach for it.

### Why this needed more than the stock template

Two things about the ROCK 5C that a generic x86 ublue image doesn't have
to deal with:

1. **No ROM UEFI.** RK3588 boards boot via Rockchip's own boot ROM ->
   SPL -> firmware chain. [`edk2-rk3588`](https://github.com/edk2-porting/edk2-rk3588)
   provides a real UEFI environment on top of that, which is what lets a
   completely standard Fedora/GRUB/aarch64 boot flow work at all. The
   ROCK 5C has no onboard SPI-NOR (it's an optional, eMMC-connector-
   exclusive accessory), so this firmware has to live on the same medium
   as the OS on every image. [`scripts/compose-sdcard-image.sh`](scripts/compose-sdcard-image.sh)
   handles this: it dd's the firmware image (fetched generically by
   [`scripts/fetch-firmware.sh`](scripts/fetch-firmware.sh), pinned +
   sha256-verified, URL/checksum declared in this board's own
   `edk2_url`/`edk2_sha256` fields in `images/boards.toml`) to the front
   of the disk, then
   relocates the normal bootc-image-builder GPT (ESP + boot + root) to
   start right after it, preserving every filesystem UUID and partition
   UUID along the way.
2. **Wi-Fi/BT.** Handled by the `rock5` variant above, not by this board
   -- it's a property of the OS image, not the disk.

Everything else -- kernel, GPU (Panthor/Mali G610), display -- comes from
stock Fedora. The `rk3588s-rock-5c` device tree and the RK3588 kernel
drivers needed for storage/USB/ethernet/GPU/display are upstream in
mainline Linux, so no vendor kernel is used.

### Flashing

1. Download the latest `immutable-sbc-rock-5c.img.zst` from a
   [Release](../../releases) or a *Build flash image* workflow run.
2. Decompress and write it to a microSD card or eMMC module (≥8 GiB):

   ```bash
   zstd -d immutable-sbc-rock-5c.img.zst -o immutable-sbc-rock-5c.raw
   sudo dd if=immutable-sbc-rock-5c.raw of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   (Balena Etcher and Raspberry Pi Imager can also write a `.zst`-
   compressed raw image directly, if you prefer a GUI.)
3. Boot the ROCK 5C from that card. First boot runs GNOME's account
   setup wizard -- no default username/password is baked into the image.
4. The root filesystem grows to fill the rest of the card/eMMC
   automatically on first boot.

### ISO caveat

The ISO is a normal Anaconda installer image, but the ROCK 5C has no ROM
UEFI to boot it with in the first place -- unlike a PC, this board can
only reach a UEFI shell if the EDK2 firmware is *already resident* on
whatever medium it's booting from. In practice that means the ISO is only
useful for:

- reinstalling/resetting the OS on a board that's already running a
  `.raw`-flashed card (the firmware region is untouched by a fresh
  install to a different partition/disk), or
- testing in a UEFI-capable VM.

It is **not** a bare-metal-from-nothing installer the way a PC ISO is. Use
the `.raw` image for first-time bring-up.

## OTA updates

Once installed, this is a normal bootc system:

```bash
sudo bootc upgrade
sudo systemctl reboot
```

Images are signed with [cosign](https://github.com/sigstore/cosign); the
public key is at [`cosign.pub`](cosign.pub).

## Rebuilding it yourself

```bash
just build              # container image, variant defaults to "rock5"
just build-raw          # or build-qcow2 / build-iso -- disk image for the rock-5c board
```

Every recipe takes an optional `variant` argument (defaults to `rock5`,
this repo's only variant today) -- e.g. `just build rock5`. Package name is
always `<IMAGE_NAME>-<variant>` (`image-template.env`'s `IMAGE_NAME` is
just the repo name; the variant is appended automatically).

See [`ublue-os/image-template`](https://github.com/ublue-os/image-template)
for the general shape of this repo -- `Containerfile` + `build_files/` +
`images/<variant>/` + a `Justfile` driving everything.

## Repo layout

| Path | Purpose |
|---|---|
| [`images/boards.toml`](images/boards.toml) | Every physical board this repo flashes for -- one `[boards.<board>]` table each: which variant it flashes, where its disk config lives, EDK2 firmware URL/sha256 |
| [`images/rock5/`](images/rock5/) | The `rock5` OSTree image variant: `variant.toml` and the aic8800 driver script |
| [`disk_config/`](disk_config/) | bootc-image-builder disk configs, referenced by path from `images/boards.toml` |
| `Containerfile`, `build_files/`, `system_files/` | The OCI image: base Fedora bootc (aarch64) + minimal GNOME + the shared root-fs declaration, generic across every variant |
| `scripts/` | Generic, parameterized tools shared across every variant/board: firmware fetch+verify, disk composition, changelog generation |
| `.github/workflows/build.yml` | Matrixes over every variant; builds + signs + pushes each OCI image to GHCR (the OTA path) |
| `.github/workflows/build-flash.yml` | Matrixes over every board; builds the raw/qcow2/iso artifacts on demand and on release tags; publishes the release for `vX.Y.Z` tags |
| `.github/dependabot.yml` | Keeps every GitHub Actions SHA pin and the Containerfile's base image digest current |

## Known limitations / please report back

I don't have a physical ROCK 5C to test against, so these are the things
most likely to need a follow-up fix once this actually boots on hardware:

- **Bluetooth**: `aic8800-usb-dkms` is confirmed for Wi-Fi. Whether BT on
  the combo chip comes up automatically or needs an extra `btattach`/udev
  rule is untested.
- **Reserved firmware region size**: the firmware image is ~6.6 MiB;
  `compose-sdcard-image.sh` reserves 16 MiB for it. Should be safe
  headroom, but worth double-checking against `sgdisk -p` output on a
  flashed card if boot fails.
- **First real boot**: partition layout is sanity-checked with
  `sgdisk --verify` in CI, but actual firmware hand-off / GRUB / kernel
  boot on real hardware hasn't been verified by me.

If you hit any of these, please open an issue.

## Credits

- [`ublue-os/image-template`](https://github.com/ublue-os/image-template) --
  the base tooling this repo is built on
- [`edk2-porting/edk2-rk3588`](https://github.com/edk2-porting/edk2-rk3588) /
  [`kwankiu/edk2-rk3588`](https://github.com/kwankiu/edk2-rk3588) -- UEFI
  firmware for RK3588 boards
- [`ausil/aic8800-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/) --
  Wi-Fi/BT driver COPR
