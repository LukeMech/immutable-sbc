# images/

Every OSTree/container image variant this repo builds lives here.

- **A variant** (a `[<name>]` table in [`variants.toml`](variants.toml), e.g. `[rock5]`) is what
  [`build.yml`](../.github/workflows/build.yml) matrixes over. Each also has a real directory
  (`<suffix>/`, e.g. [`rock5/`](rock5/)) mirroring the top-level layout -- `build_files/` for its own
  numbered build hooks, an optional `system_files/` overlay. Package name is always `immutable-sbc-<suffix>`.
- **A board** (a `[<board>]` table in [`boards.toml`](boards.toml)) is one physical, flashable board --
  what [`build-flash.yml`](../.github/workflows/build-flash.yml) matrixes over. Its config never needs
  more than a few fields plus maybe a firmware URL/checksum, so every board is just a table here rather
  than its own directory. Each board picks which variant to flash and declares its disk layout and firmware.

A variant isn't tied to one board: multiple boards can share a variant with identical OS content but
different disk layouts. Today there's one of each -- see [`rock5/README.md`](rock5/README.md) for the
`rock5` variant, and the top-level [README](../README.md)'s `rock-5c` section for the board it flashes.
