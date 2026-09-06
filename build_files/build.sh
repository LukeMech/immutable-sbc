#!/bin/bash

set -ouex pipefail

VARIANT="${1:?usage: $0 <variant>}"
# Exported: 00-pre-build.sh/post-build.sh (both shared hooks) need it for their
# per-variant cases, same as every hook run below inherits it.
export VARIANT
VARIANT_DIR="/ctx/images/${VARIANT}"

# Copy system_files/ onto / -- includes the root-filesystem declaration
# (system_files/usr/lib/bootc/install/00-root-filesystem.toml), shared by every variant.
cp -avf "/ctx/system_files"/. /

# A variant can also ship its own system_files/ overlay for per-variant
# differences (none exist today) -- same cp-a-tree convention, scoped to it.
if [[ -d "${VARIANT_DIR}/system_files" ]]; then
    cp -avf "${VARIANT_DIR}/system_files"/. /
fi

# Shared build hooks, run in numbered order (00-, 10-, ...) -- add new hooks to
# build_files/ without touching this script. post-build.sh is the one exception:
# skipped here, invoked explicitly near the end instead (see that block below for why).
for hook in /ctx/*.sh; do
    [[ -e "${hook}" ]] || continue
    case "$(basename "${hook}")" in
        build.sh | post-build.sh) continue ;;
    esac
    bash "${hook}"
done

# This variant's own build hooks, same numbered-order convention as above --
# add new hooks to images/<variant>/build_files/ without touching this script.
for hook in "${VARIANT_DIR}/build_files"/*.sh; do
    [[ -e "${hook}" ]] || continue
    bash "${hook}"
done

# COPR repos, build-time-only deps (00-pre-build.sh), and the dnf cache -- removed
# only now, after every hook above, so nothing later needs any of it back.
bash /ctx/post-build.sh
