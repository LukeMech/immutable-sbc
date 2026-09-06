#!/bin/bash

set -ouex pipefail

VARIANT="${1:?usage: $0 <variant>}"
VARIANT_DIR="/ctx/images/${VARIANT}"

# quay.io/fedora/fedora-bootc doesn't bundle the copr plugin the way ublue-os base
# images do -- install it once here so any hook below can just `dnf5 copr enable ...`
# without repeating this itself. Removed again in final housekeeping, below.
dnf5 -y install 'dnf5-command(copr)'

# Copy system_files/ onto / -- includes the root-filesystem declaration
# (system_files/usr/lib/bootc/install/00-root-filesystem.toml), shared by every variant.
cp -avf "/ctx/system_files"/. /

# A variant can also ship its own system_files/ overlay for per-variant
# differences (none exist today) -- same cp-a-tree convention, scoped to it.
if [[ -d "${VARIANT_DIR}/system_files" ]]; then
    cp -avf "${VARIANT_DIR}/system_files"/. /
fi

# Shared build hooks, run in numbered order (00-, 10-, ...) --
# add new hooks to build_files/ without touching this script.
for hook in /ctx/*.sh; do
    [[ -e "${hook}" ]] || continue
    [[ "$(basename "${hook}")" == "build.sh" ]] && continue
    bash "${hook}"
done

# This variant's own build hooks, same numbered-order convention as above --
# add new hooks to images/<variant>/build_files/ without touching this script.
for hook in "${VARIANT_DIR}/build_files"/*.sh; do
    [[ -e "${hook}" ]] || continue
    bash "${hook}"
done

# Remove every COPR repo any hook enabled -- COPR is a build-time-only convenience,
# no third-party repo config/GPG key should survive into the final image. `copr
# remove` (unlike `disable`) cleans up the .repo file and imported GPG key, and must
# run before the plugin package providing it is removed. Repo id is the standard
# `_copr:<host>:<owner>:<project>.repo` naming, so owner/project comes straight
# back out of the filename rather than needing each hook to report what it enabled.
shopt -s nullglob
for repo_file in /etc/yum.repos.d/_copr:*.repo; do
    project=$(basename "${repo_file}" .repo | cut -d: -f3-4 --output-delimiter=/)
    dnf5 -y copr remove "${project}"
done
dnf5 -y remove 'dnf5-command(copr)'

# Final housekeeping
dnf5 -y clean all
