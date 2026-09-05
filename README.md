# immutable-sbc

A [Universal Blue](https://universal-blue.org/)-style, OTA-updatable,
minimal GNOME [bootc](https://containers.github.io/bootc/) image builder
for single-board computers. Everything lives under [`images/`](images/):

- **A variant** (a `[<name>]` table in [`images/variants.toml`](images/variants.toml),
  e.g. `[rock5]`) is a shared OSTree/container image variant -- what
  [`build.yml`](.github/workflows/build.yml) matrixes over. Each
  one also has a real directory (`images/<suffix>/`, e.g.
  [`images/rock5/`](images/rock5/)) mirroring the top-level repo layout
  -- `build_files/` for its own numbered build hooks, an optional
  `system_files/` overlay -- since a variant can bundle both. Package
  name is always `immutable-sbc-<suffix>`.
- **A board** (a `[<board>]` table in [`images/boards.toml`](images/boards.toml))
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

See the `[rock5]` table in [`images/variants.toml`](images/variants.toml).
Built from
[`ublue-os/image-template`](https://github.com/ublue-os/image-template)'s
tooling, on top of a minimal, Wayland-only GNOME session: shell, settings,
a file manager and a terminal. No games, no extra bundled GNOME apps, no
Flatpak/Flathub, no `gnome-initial-setup` wizard -- GDM autologins
straight to the desktop as the baked-in `lm` account instead (fixed by
design: this is a personal SBC image, not a multi-user/shared
deployment). The account's password is locked, not merely blank --
nothing ever prompts for one, since GDM autologin, passwordless sudo
(`system_files/etc/sudoers.d/lm-nopasswd`) and a matching polkit rule
(`system_files/etc/polkit-1/rules.d/90-nopasswd-lm.rules`) don't need it
either. Screen locking is disabled outright, not just deferred
(`system_files/etc/dconf/db/local.d/04-no-lock`) -- a locked account has
no password that could ever authenticate a locked session back open, so
manually locking (Super+L, the system-menu "Lock" entry) would otherwise
strand you at an unsolvable password prompt, recoverable only by
power-cycling the board. Locale defaults to `en_US.UTF-8` and the
keyboard layout to `us` (`system_files/etc/locale.conf`, `vconsole.conf`,
`X11/xorg.conf.d/00-keyboard.conf`, and GNOME's own input source via
`dconf`; also seeded into `system_files/usr/share/factory/var/lib/
AccountsService/users/lm`, copied into place at first boot by
`system_files/usr/lib/tmpfiles.d/lm-accountsservice.conf` -- content
placed directly under `system_files/var/` never reaches a real
deployment, since bootc/ostree discards whatever's baked into `/var` in
the container image). The screen never blanks and the system never
suspends (also set via `dconf`, still changeable in Settings afterward --
see [`build_files/01-gnome-minimal.sh`](build_files/01-gnome-minimal.sh)).

The onboard AIC8800D80 combo chip needs the
[`aic8800-usb-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/)
COPR package for Wi-Fi/BT, built once at container *build* time in a
writable layer, not on the deployed read-only system. Neither the built
kernel module nor the firmware it loads at runtime ship as bare files or
depend on the upstream `aic8800-usb-dkms`/`aic8800-firmware` packages
surviving into the final image -- both get pulled into one
self-contained `kmod-aic8800-usb` rpm instead, so they're rpm-database
tracked and don't depend on how any later step in the pipeline
re-derives the image. See
[`images/rock5/build_files/10-aic8800-wifi-bt.sh`](images/rock5/build_files/10-aic8800-wifi-bt.sh)
for the full story (this was tightened twice after real-hardware testing
turned up two separate ways bare/upstream-owned files were getting
dropped before ever reaching a deployed board).

**A container image** on `ghcr.io/lukemech/immutable-sbc-rock5`, rebuilt
nightly and on every push to `main`. Once installed, `bootc upgrade` pulls
updates the same way any bootc/ostree system does -- no reflashing
required. Images are rechunked with [chunkah](https://github.com/coreos/chunkah)
(`just rechunk`, in the `Justfile`) rather than `rpm-ostree compose
build-chunked-oci` -- chunkah has no special-casing for bootable/kernel
content, which the classic rechunker does and which was implicated in one
of the two dropped-file bugs above.

## rock-5c: Radxa ROCK 5C (RK3588S)

See the `[rock-5c]` table in [`images/boards.toml`](images/boards.toml).
Flashes the `rock5` variant above.

### What you get

- **A microSD/eMMC image** (`.raw`, zstd-compressed) -- the only thing
  the *Build flash image* workflow and [Release](../../releases) assets
  actually produce. Built on demand, or attached to a [Release](../../releases)
  when a `vX.Y.Z` tag is pushed.

`just build-qcow2`/`just build-iso` also exist in the Justfile (see
"Rebuilding it yourself" below), but neither is part of this pipeline or
currently verified -- `build-iso` specifically is broken as of this
writing, since it references `disk_config/iso.toml`, which doesn't
exist.

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
   of the disk, then relocates the normal bootc-image-builder GPT
   (ESP + boot + root) to start right after it, preserving every
   filesystem UUID, partition UUID and GPT attribute bit along the way.
   The result is checked, not assumed: the composed disk is confirmed to
   have a genuine protective (not corrupt/hybrid) MBR, a consistent GPT,
   and a real EFI System Partition before the build is allowed to
   succeed.
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
3. Boot the ROCK 5C from that card -- GDM autologins straight to the
   desktop as the baked-in `lm` account, no first-boot setup wizard and
   no password to type.
4. The root filesystem grows to fill the rest of the card/eMMC
   automatically on first boot
   (`immutable-sbc-growroot.service`, see
   [`build_files/00-default-config.sh`](build_files/00-default-config.sh))
   -- the raw image itself is deliberately built small
   ([`disk_config/disk.toml`](disk_config/disk.toml)), it isn't meant to
   reflect the actual capacity of the card you're flashing onto.

## OTA updates

Once installed, this is a normal bootc system:

```bash
sudo bootc upgrade
sudo systemctl reboot
```

Images are signed with [cosign](https://github.com/sigstore/cosign); the
public key -- the same one baked into the image at
`/etc/pki/containers/lukemech-cosign.pub` -- lives at
[`system_files/etc/pki/containers/lukemech-cosign.pub`](system_files/etc/pki/containers/lukemech-cosign.pub)
(one canonical copy, not duplicated at the repo root). Verify a pulled
image yourself with:

```bash
cosign verify --key system_files/etc/pki/containers/lukemech-cosign.pub \
  ghcr.io/lukemech/immutable-sbc-rock5:latest
```

The deployed system enforces this itself, too, and strictly:
`system_files/etc/containers/policy.json`'s top-level default is
`reject`, with exactly one carve-out on the `docker` transport --
`ghcr.io/lukemech` requires a valid cosign signature. That's the actual
gate: it's checked against anything being *pulled* over the network, so
no other registry is reachable at all (a plain `podman pull` of anything
else, including toolbox/distrobox images, is refused outright until
explicitly added to the policy). The matching
`system_files/etc/containers/registries.d/lukemech.yaml` points
podman/skopeo/bootc at cosign's signature storage.

The `containers-storage` transport (images already resolved into local
storage, rather than being pulled) is left `insecureAcceptAnything` --
re-checking a signature there wouldn't catch anything the `docker`
transport didn't already catch on the way in, it would only block
legitimate local reads of an already-verified image. `bootc-image-builder`
installs from exactly such a local reference when baking a fresh disk
image (confirmed in CI: scoping this to `ghcr.io/lukemech` the same way
as `docker` doesn't work -- `containers-storage` scopes require a
`[graph-driver@graph-root]` store-specifier prefix, and osbuild's build
root is a different, unpredictable path every run).
`system_files/usr/lib/bootc/install/01-sigpolicy.toml` sets
`enforce-container-sigpolicy = true`, so every install path -- fresh
flashes via bootc-image-builder included -- records the deployment's
origin as `ostree-image-signed` instead of `ostree-unverified-registry`.
That's what actually makes policy.json's rule get consulted on every
`sudo bootc upgrade`; an unsigned or wrongly-signed image is refused.

## Rebuilding it yourself

```bash
just build              # container image, variant defaults to "rock5"
just build-raw          # disk image for the rock-5c board -- what CI actually ships
```

`build-qcow2` also exists for local VM testing, but isn't part of this
project's CI and isn't currently verified. `build-iso` is broken as of
this writing (references the now-removed `disk_config/iso.toml`).

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
| [`images/boards.toml`](images/boards.toml) | Every physical board this repo flashes for -- one `[<board>]` table each: which variant it flashes, where its disk config lives, EDK2 firmware URL/sha256 |
| [`images/variants.toml`](images/variants.toml) | Every OSTree/container image variant this repo builds -- one `[<name>]` table each: its `suffix` (-> `images/<suffix>/` and the package name) and `description` |
| [`images/rock5/`](images/rock5/) | The `rock5` variant's own overlay, mirroring the top-level layout: `build_files/` (the aic8800 driver hook) and, if it ever needs one, a `system_files/` |
| [`disk_config/`](disk_config/) | bootc-image-builder disk configs (deliberately small partition floors, not final sizes -- see the growroot service), referenced by path from `images/boards.toml` |
| `Containerfile`, `build_files/`, `system_files/` | The OCI image, generic across every variant: base Fedora bootc (aarch64), minimal GNOME, the default account (`sysusers.d`/`tmpfiles.d`), never-blank/never-sleep power defaults (`dconf`), the root-growth service, the shared root-fs declaration, and the enforced container signature policy (`policy.json`, `registries.d/lukemech.yaml`, `bootc/install/01-sigpolicy.toml`). Base image and chunkah (Justfile's `rechunk` recipe) are both floating tags, not digest pins -- see their own comments for why. |
| `scripts/` | Generic, parameterized tools shared across every variant/board: firmware fetch+verify, disk composition (with GPT/MBR/ESP verification), changelog generation |
| `.github/workflows/build.yml` | Matrixes over every variant; builds, rechunks (chunkah), signs and pushes each OCI image to GHCR (the OTA path) on every push to `main`, its own biweekly schedule, or manual dispatch -- rechunking/tagging/signing all skip on pull requests, which only need to prove the image still builds. Its own `release-meta` job then publishes a release (tagged `v<fedora-version>.<date>.<N>`, auto-incrementing per day) with a changelog, as soon as the container image itself is live on GHCR -- before build-flash.yml even starts, since the release is about the container image someone's `bootc upgrade` already pulled, not the (much slower) disk images. |
| `.github/workflows/build-flash.yml` | Called as a reusable workflow (`uses:`, not a separate triggered run) only after build.yml's `release-meta` job has already published a release -- receives that release's tag as an input and builds each board's raw disk image, attaching it to that already-live release once ready. A direct `workflow_dispatch` builds the flash images without attaching them to anything (no tag to attach to). |
| `.github/dependabot.yml` | Keeps every GitHub Actions SHA pin current; its docker-ecosystem entry stays configured for whenever a `FROM ...@sha256:...` digest pin is reintroduced, but nothing currently uses one |

## Known limitations / please report back

This has had real hardware time on a ROCK 5C, but not a full clean
first-flash-to-daily-use pass yet. Confirmed so far: the board boots off
a flashed card through the EDK2/GRUB chain, GDM comes up, the baked-in
account logs in, and the `aic_load_fw` kernel module loads (tainting the
kernel as expected for an unsigned out-of-tree module -- not a bug).
Still open:

- **Wi-Fi/BT actually associating end-to-end** on the latest build --
  earlier testing caught the kernel module *and* its firmware getting
  silently dropped before reaching a deployed image (now fixed twice
  over, see the `rock5` section above), but a full "connects to a
  network" / "pairs a BT device" confirmation on that fixed build is
  still pending.
- **The root-growth service and the smaller raw image size** are new and
  unverified on real hardware -- confirm the partition/filesystem
  actually grow to fill the card on first boot, not just that the image
  builds.
- **Reserved firmware region size**: the firmware image is ~6.6 MiB;
  `compose-sdcard-image.sh` reserves 16 MiB for it. Should be safe
  headroom, but worth double-checking against `sgdisk -p` output on a
  flashed card if boot fails.

If you hit any of these, please open an issue.

## Credits

- [`ublue-os/image-template`](https://github.com/ublue-os/image-template) --
  the base tooling this repo is built on
- [`edk2-porting/edk2-rk3588`](https://github.com/edk2-porting/edk2-rk3588) /
  [`kwankiu/edk2-rk3588`](https://github.com/kwankiu/edk2-rk3588) -- UEFI
  firmware for RK3588 boards
- [`ausil/aic8800-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/) --
  Wi-Fi/BT driver COPR
- [`coreos/chunkah`](https://github.com/coreos/chunkah) -- image rechunking
