# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
# Whole images/ tree (not just the variant dir), bind-mounted and never persisted --
# copying boards.toml too costs nothing; it's read later, by build-flash.yml.
COPY images /images
# fetch-firmware.sh: installed into the image by 01-uefi-updater.sh and reused
# verbatim by the deployed uefi-updater.py service, so it downloads/verifies
# firmware the exact same way build-flash.yml does -- one implementation, not
# two copies to keep in sync.
COPY scripts /scripts

# Prebuilt kernel + kmod + HailoRT RPMs (images/deps/, built and pushed separately by
# build-deps.yml -- kernel floats to whatever Fedora currently ships, so this can't be
# a digest pin; see that workflow for why a floating tag here is still safe). Never
# runs on a booted system, only bind-mounted at this build's own build time, so
# bootc's runtime signature policy doesn't apply to it (see images/deps/README.md).
FROM ghcr.io/lukemech/immutable-sbc-deps:latest AS deps

# Fedora bootc aarch64, generic across variants (driver/kernel needs go in
# that variant's own images/<variant>/build_files/).
#
# Floating tag: a pinned digest 404'd after quay.io GC'd it,
# breaking builds until re-pinned.
FROM quay.io/fedora/fedora-bootc:44

# Which images/<VARIANT>/ this image builds -- see build.yml, which
# matrixes over every directory under images/ and passes each one here.
ARG VARIANT=rk3588

### MODIFICATIONS
## Modify the image or install packages by editing build.sh, run below as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=deps,source=/rpms,target=/deps-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh "${VARIANT}"

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
