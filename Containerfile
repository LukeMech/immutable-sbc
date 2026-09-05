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

# Never built (nothing depends on it, and it sits before the real final
# stage below so it can't accidentally become the default build target
# either) -- exists purely so Dependabot's docker ecosystem has a real
# `FROM ...@sha256:...` line to bump. The Justfile's `rechunk` recipe
# reads this line back out at runtime, so this is the only place the
# chunkah image version needs updating.
FROM quay.io/coreos/chunkah@sha256:ff8b8b466a942ec6000445d4001fc661e2fc5a952ad9ee29b4de9ab09d1d1708 AS chunkah-pin

# Base Image: Fedora bootc, aarch64. Generic across every variant --
# any board/variant-specific kernel or driver need belongs in that
# variant's own build hooks (images/<variant>/build_files/), not here.
# (Today's only variant, rock5, needs none: see README.md's rock-5c
# section for why.)
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
