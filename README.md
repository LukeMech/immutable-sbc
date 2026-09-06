# immutable-sbc

A [Universal Blue](https://universal-blue.org/)-style, OTA-updatable,
minimal GNOME [bootc](https://containers.github.io/bootc/) image builder
for single-board computers. Everything lives under [`images/`](images/)
-- see [`images/README.md`](images/README.md) for how variants and
boards fit together. Today there's two variants across three boards:

## Flashing

1. Download the latest disk image from a [Release](../../releases) --
   `immutable-sbc-<board>-<tag>.img.zst`.
2. Decompress and write it to a microSD card or eMMC module (≥8 GiB),
   substituting the filename you actually downloaded:

   ```bash
   zstd -d immutable-sbc-<board>.img.zst -o flash.raw
   sudo dd if=flash.raw of=/dev/sdX bs=4M status=progress conv=fsync
   ```
   
   (Balena Etcher and Raspberry Pi Imager can also write a `.zst`-
   compressed raw image directly, if you prefer a GUI.)
3. Boot the board from that card -- GDM autologins straight to the
   desktop as the baked-in `lm` account, no first-boot setup wizard and
   no password to type.
4. The root filesystem grows to fill the rest of the card/eMMC automatically on first boot
   (`immutable-sbc-growroot.service`, see [`build_files/05-gnome-minimal.sh`](build_files/05-gnome-minimal.sh))
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
  ghcr.io/lukemech/immutable-sbc-rk3588:latest
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
just build              # container image, variant defaults to "rk3588"
just build-raw          # disk image for the rock-5c board -- what CI actually ships
```

Every recipe takes an optional `variant` argument (defaults to `rk3588`,
one of two variants today, the other being `rpi`) -- e.g. `just build rpi`. Package name is
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
| [`images/rk3588/`](images/rk3588/) | The `rk3588` variant's own overlay: `build_files/` (aic8800 driver, mesa-libTeflon) -- see [`images/rk3588/README.md`](images/rk3588/README.md) |
| [`images/rpi/`](images/rpi/) | The `rpi` variant's own overlay: `build_files/` (Hailo PCIe drivers for the optional AI HAT+ and AI HAT+ 2) -- see [`images/rpi/README.md`](images/rpi/README.md) |
| [`disk_config/`](disk_config/) | bootc-image-builder disk configs (deliberately small partition floors, not final sizes -- see the growroot service), referenced by path from `images/boards.toml` |
| `Containerfile`, `build_files/`, `system_files/` | The OCI image, generic across variants: base Fedora bootc, minimal GNOME, the default account (`sysusers.d`/`tmpfiles.d`), power defaults (`dconf`), the root-growth service, the enforced signature policy (`policy.json` + `registries.d/`), and Coral USB/PCIe accelerator support (`libedgetpu`, `gasket`/`apex`) for any board. Base image and chunkah are floating tags, not digest pins -- see their own comments for why. |
| `scripts/` | Generic, parameterized tools shared across every variant/board: firmware fetch+verify, disk composition (`compose-sdcard-image.sh`: dd+GPT rebuild for `firmware_layout = "raw"`, `mtools` ESP copy for `"fat"`), changelog generation |
| `.github/workflows/build.yml` | Matrixes over every variant; builds, rechunks, pushes and signs each OCI image to GHCR on push to `main`, a biweekly schedule, or manual dispatch (PRs skip rechunk/push/sign). Diffs against the last release's commit to build a changelog and skip publishing on a no-op schedule run; `release-meta` then tags and publishes the release before build-flash.yml starts. |
| `.github/workflows/build-flash.yml` | Reusable workflow (`uses:`) called after `release-meta` publishes a release; builds each board's raw disk image and attaches it to that release. A direct dispatch builds images without attaching them. |
| `.github/dependabot.yml` | Keeps every GitHub Actions SHA pin current; its docker-ecosystem entry stays configured for whenever a `FROM ...@sha256:...` digest pin is reintroduced, but nothing currently uses one |

## Credits

- [`ublue-os/image-template`](https://github.com/ublue-os/image-template) --
  the base tooling this repo is built on
- [`lukemech/edk2-rk3588`](https://github.com/lukemech/edk2-rk3588) -- UEFI
  firmware for RK3588 boards
- [`pftf/RPi4`](https://github.com/pftf/RPi4) -- UEFI firmware for the Raspberry Pi 4B
- [`worproject/rpi5-uefi`](https://github.com/worproject/rpi5-uefi) -- UEFI firmware for the Raspberry Pi 5
- [`coreos/chunkah`](https://github.com/coreos/chunkah) -- image rechunking
