# images/

Every OSTree/container image variant this repo builds lives here.

- **A variant** (a `[<name>]` table in [`variants.toml`](variants.toml), e.g. `[rk3588]`) is what
  [`build.yml`](../.github/workflows/build.yml) matrixes over. Each also has a real directory
  (`<suffix>/`, e.g. [`rk3588/`](rk3588/)) mirroring the top-level layout -- `build_files/` for its own
  numbered build hooks, an optional `system_files/` overlay. Package name is always `immutable-sbc-<suffix>`.
- **A board** (a `[<board>]` table in [`boards.toml`](boards.toml)) is one physical, flashable board --
  what [`build-flash.yml`](../.github/workflows/build-flash.yml) matrixes over. Its config never needs
  more than a few fields plus maybe a firmware URL/checksum, so every board is just a table here rather
  than its own directory. Each board picks which variant to flash and declares its disk layout and firmware.
  `firmware_layout` picks how [`compose-sdcard-image.sh`](../scripts/compose-sdcard-image.sh) installs
  firmware: `"raw"` (default, dd'd to a fixed disk offset) or `"fat"` (copied into the ESP).

A variant isn't tied to one board: multiple boards can share a variant with identical OS content but
different disk layouts. Today there are two of each -- see [`rk3588/README.md`](rk3588/README.md) for the
`rk3588` variant (flashed by the `rock-5c` board) and [`rpi/README.md`](rpi/README.md) for the `rpi` variant
(flashed by `rpi-4b`/`rpi-5`) -- the top-level [README](../README.md) covers each board's flashing steps.
