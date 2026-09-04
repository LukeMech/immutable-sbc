# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
# images/, not just images/<variant>/: this bind-mounts into the build
# below and is never persisted into the final image either way, so
# there's no cost to including images/boards.toml alongside it even
# though only the variant-level files are actually used here -- board
# config (disk configs, firmware) is only read later, by build-flash.yml.
COPY images /images

# Base Image: Fedora bootc, aarch64.
# The Radxa ROCK 5C (RK3588S) has no vendor kernel requirement -- the
# rk3588s-rock-5c device tree and the RK3588 GPU/display drivers are
# upstream in mainline Linux, so the stock Fedora kernel is used as-is.
#
# Pinned by digest; bumped automatically by Dependabot (docker ecosystem).
# Digest is the aarch64 child of the "44" manifest list -- podman/buildah
# resolve by digest regardless of the tag text, so this always pulls the
# same aarch64 image either way.
FROM quay.io/fedora/fedora-bootc:44@sha256:bc8170813188572139a6d01a3c03ab6b95c2c07152d4d313be4941c0870d8a6f

# Which images/<VARIANT>/ this image builds -- see build.yml, which
# matrixes over every directory under images/ and passes each one here.
ARG VARIANT=rock5

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh "${VARIANT}"

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
