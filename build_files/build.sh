#!/bin/bash

set -ouex pipefail

VARIANT="${1:?usage: $0 <variant>}"
VARIANT_DIR="/ctx/images/${VARIANT}"

# Copy the contents of system_files/ of the git repo to / -- this
# includes the root-filesystem declaration
# (system_files/usr/lib/bootc/install/00-root-filesystem.toml), shared by
# every variant, not just this one.
cp -avf "/ctx/system_files"/. /

# A variant can also ship its own system_files/ overlay for anything that
# genuinely varies per variant (not the case for anything today) -- same
# cp-a-tree-onto-/ convention as the generic one above, just scoped to
# this one variant.
if [[ -d "${VARIANT_DIR}/system_files" ]]; then
    cp -avf "${VARIANT_DIR}/system_files"/. /
fi

# Shared build stage, common to every variant.
bash /ctx/00-gnome-minimal.sh

# This variant's own build hooks, run in order. Numbered-prefix naming
# (00-, 10-, ...) controls execution order, same convention as the
# shared stage above -- add new hooks to images/<variant>/ without
# touching this script.
for hook in "${VARIANT_DIR}"/*.sh; do
    [[ -e "${hook}" ]] || continue
    bash "${hook}"
done

# Final housekeeping
dnf5 -y clean all
