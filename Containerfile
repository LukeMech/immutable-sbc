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

# Base Image: Fedora bootc, aarch64. Generic across every variant --
# any board/variant-specific kernel or driver need belongs in that
# variant's own build hooks (images/<variant>/build_files/), not here.
# (Today's only variant, rock5, needs none: see README.md's rock-5c
# section for why.)
#
# Floating tag, not a pinned digest -- confirmed quay.io garbage-collects
# older digests behind fedora-bootc's own tags (a previously-pinned
# digest 404'd with "manifest unknown" after only a few weeks, breaking
# every build until re-pinned). Trades reproducibility for never failing
# on stale upstream digest GC; Fedora's own security updates land in
# this same tag either way.
FROM quay.io/fedora/fedora-bootc:44

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
