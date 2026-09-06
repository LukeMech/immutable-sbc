# immutable-sbc

A [Universal Blue](https://universal-blue.org/)-style, OTA-updatable,
minimal GNOME [bootc](https://containers.github.io/bootc/) image builder
for single-board computers. Everything lives under [`images/`](images/)
-- see [`images/README.md`](images/README.md) for how variants and
boards fit together. Today there's one of each:

## rock-5c: Radxa ROCK 5C (RK3588S)

See the `[rock-5c]` table in [`images/boards.toml`](images/boards.toml).
Flashes the `rock5` variant above.

### What you get

- **A microSD/eMMC image** (`.raw`, zstd-compressed) -- built on demand via manual dispatch, or attached
  automatically to the [Release](../../releases) that `build.yml`'s `release-meta` job creates and tags
  (`v<fedora-version>.<date>`, e.g. `v44.20260905`) once the container image has published.

`just build-qcow2`/`just build-iso` also exist (see "Rebuilding it yourself" below) but aren't part of this
pipeline or verified -- `build-iso` is currently broken (references a nonexistent `disk_config/iso.toml`).

### Why this needed more than the stock template

Two things about the ROCK 5C that a generic x86 ublue image doesn't have
to deal with:

1. **No ROM UEFI.** RK3588 boards boot via Rockchip's boot ROM -> SPL -> firmware chain;
   [`edk2-rk3588`](https://github.com/edk2-porting/edk2-rk3588) provides the UEFI environment a standard
   Fedora/GRUB/aarch64 boot flow needs. The ROCK 5C has no onboard SPI-NOR, so this firmware has to share
   the same medium as the OS on every image. [`scripts/compose-sdcard-image.sh`](scripts/compose-sdcard-image.sh)
   dd's the firmware (fetched + sha256-verified by [`scripts/fetch-firmware.sh`](scripts/fetch-firmware.sh),
   URL/checksum from `images/boards.toml`) to the front of the disk, then relocates the bootc-image-builder
   GPT (ESP + boot + root) after it, preserving every UUID and GPT attribute bit -- then verifies the result
   has a genuine protective MBR, a consistent GPT, and a real EFI System Partition before allowing the build to succeed.
2. **Wi-Fi/BT.** Handled by the `rock5` variant above, not by this board
   -- it's a property of the OS image, not the disk.

Everything else -- kernel, GPU (Panthor/Mali G610), display -- comes from stock Fedora: the `rk3588s-rock-5c`
device tree and RK3588 drivers for storage/USB/ethernet/GPU/display are upstream in mainline Linux, no vendor kernel needed.

### Flashing

1. Download the latest disk image from a [Release](../../releases) --
   `immutable-sbc-rock-5c-<tag>.img.zst`, e.g.
   `immutable-sbc-rock-5c-v44.20260905.img.zst` -- or, unversioned, from a
   *Build flash image* workflow run's artifact.
2. Decompress and write it to a microSD card or eMMC module (≥8 GiB),
   substituting the filename you actually downloaded:

   ```bash
   zstd -d immutable-sbc-rock-5c.img.zst -o immutable-sbc-rock-5c.raw
   sudo dd if=immutable-sbc-rock-5c.raw of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   (Balena Etcher and Raspberry Pi Imager can also write a `.zst`-
   compressed raw image directly, if you prefer a GUI.)
3. Boot the ROCK 5C from that card -- GDM autologins straight to the
   desktop as the baked-in `lm` account, no first-boot setup wizard and
   no password to type.
4. The root filesystem grows to fill the rest of the card/eMMC automatically on first boot
   (`immutable-sbc-growroot.service`, see [`build_files/00-default-config.sh`](build_files/00-default-config.sh))
   -- the raw image itself is deliberately built small ([`disk_config/disk.toml`](disk_config/disk.toml)).

## OTA updates

Once installed, this is a normal bootc system:

```bash
sudo bootc upgrade
sudo systemctl reboot
```

Images are signed with [cosign](https://github.com/sigstore/cosign); the public key baked into the image
(`/etc/pki/containers/lukemech-cosign.pub`, canonical copy at
[`system_files/etc/pki/containers/lukemech-cosign.pub`](system_files/etc/pki/containers/lukemech-cosign.pub))
lets you verify a pulled image yourself:

```bash
cosign verify --key system_files/etc/pki/containers/lukemech-cosign.pub \
  ghcr.io/lukemech/immutable-sbc-rock5:latest
```

The deployed system enforces this itself: `system_files/etc/containers/policy.json`'s default is `reject`,
with one carve-out -- `ghcr.io/lukemech` requires a valid cosign signature on the `docker` transport. That's
checked against anything actually *pulled*, so no other registry is reachable until explicitly added to the
policy. `system_files/etc/containers/registries.d/lukemech.yaml` points podman/skopeo/bootc at cosign's signature storage.

The `containers-storage` transport (images already resolved into local storage) stays `insecureAcceptAnything`
-- re-checking there wouldn't catch anything `docker` didn't already catch on the way in, and would only block
legitimate reads of an already-verified image; `bootc-image-builder` installs from exactly such a local
reference when baking a disk image (confirmed in CI: scoping this like `docker` doesn't work --
`containers-storage` needs a `[graph-driver@graph-root]` prefix, and osbuild's build root path is unpredictable).
`system_files/usr/lib/bootc/install/01-sigpolicy.toml` sets `enforce-container-sigpolicy = true`, so every
install path -- fresh flashes included -- records the deployment's origin as `ostree-image-signed`, which is
what makes policy.json's rule get consulted on every `sudo bootc upgrade`.

## Rebuilding it yourself

```bash
just build              # container image, variant defaults to "rock5"
just build-raw          # disk image for the rock-5c board -- what CI actually ships
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
| [`images/README.md`](images/README.md) | What a variant vs. a board is, and how they relate -- start here before `boards.toml`/`variants.toml` |
| [`images/boards.toml`](images/boards.toml) | Every physical board this repo flashes for -- one `[<board>]` table each: which variant it flashes, where its disk config lives, EDK2 firmware URL/sha256 |
| [`images/variants.toml`](images/variants.toml) | Every OSTree/container image variant this repo builds -- one `[<name>]` table each: its `suffix` (-> `images/<suffix>/` and the package name) and `description` |
| [`images/rock5/`](images/rock5/) | The `rock5` variant's own overlay, mirroring the top-level layout: `build_files/` (the aic8800 driver hook, the mesa-libTeflon hook) and, if it ever needs one, a `system_files/` -- see [`images/rock5/README.md`](images/rock5/README.md) |
| [`disk_config/`](disk_config/) | bootc-image-builder disk configs (deliberately small partition floors, not final sizes -- see the growroot service), referenced by path from `images/boards.toml` |
| `Containerfile`, `build_files/`, `system_files/` | The OCI image, generic across variants: base Fedora bootc, minimal GNOME, the default account (`sysusers.d`/`tmpfiles.d`), power defaults (`dconf`), the root-growth service, and the enforced signature policy (`policy.json` + `registries.d/`). Base image and chunkah are floating tags, not digest pins -- see their own comments for why. |
| `scripts/` | Generic, parameterized tools shared across every variant/board: firmware fetch+verify, disk composition (with GPT/MBR/ESP verification), changelog generation |
| `.github/workflows/build.yml` | Matrixes over every variant; builds, rechunks, pushes and signs each OCI image to GHCR on push to `main`, a biweekly schedule, or manual dispatch (PRs skip rechunk/push/sign). Diffs against the last release's commit to build a changelog and skip publishing on a no-op schedule run; `release-meta` then tags and publishes the release before build-flash.yml starts. |
| `.github/workflows/build-flash.yml` | Reusable workflow (`uses:`) called after `release-meta` publishes a release; builds each board's raw disk image and attaches it to that release. A direct dispatch builds images without attaching them. |
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
- [`lukemech/edk2-rk3588`](https://github.com/lukemech/edk2-rk3588) -- UEFI
  firmware for RK3588 boards
- [`ausil/aic8800-dkms`](https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/) --
  Wi-Fi/BT driver COPR
- [`coreos/chunkah`](https://github.com/coreos/chunkah) -- image rechunking
