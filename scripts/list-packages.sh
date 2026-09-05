#!/bin/bash
#
# Prints name<TAB>epoch:version-release for every installed package,
# sorted by name -- gpg-pubkey entries filtered out (rpm's pseudo-package
# per imported signing key; a repo rotating its key would otherwise look
# like a package "change"). Shared by diff-packages.sh and build.yml's
# own pre-push check, so both agree on what counts as "changed".
#
# Usage: list-packages.sh <image-ref>

set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref>}"

podman run --rm --entrypoint rpm "${IMAGE}" -qa --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\n' 2>/dev/null \
    | sed 's/\t(none):/\t/' \
    | grep -v $'^gpg-pubkey\t' \
    | sort -k1,1
