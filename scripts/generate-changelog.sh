#!/bin/bash
#
# Generates a Bazzite-style changelog: a package version diff table plus
# the git commits since the previous build. Much simpler than Bazzite's
# own SBOM/registry-diffing changelog.py -- we only ever build one image,
# no variants, so a plain `rpm -qa` diff between the previous and new
# image is enough.
#
# Usage: generate-changelog.sh <previous-image-ref> <new-image-ref> <output.md>
#
# <previous-image-ref> may not exist yet (first-ever build) -- that's
# handled, it just means no package diff, only "initial build".

set -euo pipefail

PREV_IMAGE="${1:?usage: $0 <previous-image-ref> <new-image-ref> <output.md>}"
NEW_IMAGE="${2:?usage: $0 <previous-image-ref> <new-image-ref> <output.md>}"
OUTPUT="${3:?usage: $0 <previous-image-ref> <new-image-ref> <output.md>}"

get_packages() {
    # name<TAB>epoch:version-release, sorted by name for `join` below.
    # Sort by both fields, not just name: multiple gpg-pubkey entries (one
    # per imported signing key) share the same name, and a name-only sort
    # doesn't order ties deterministically -- they'd randomly swap
    # positions between the previous/new dumps and show up as a fake
    # version change.
    podman run --rm --entrypoint rpm "$1" -qa --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\n' 2>/dev/null \
        | sed 's/\t(none):/\t/' \
        | sort -k1,1 -k2,2
}

get_git_sha() {
    # Our own Justfile embeds this as org.opencontainers.image.version=
    # <tag>.<date>-<shortsha> (see `just build`'s LABELS).
    podman inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$1" 2>/dev/null \
        | grep -oE '[0-9a-f]{7,40}$' || true
}

PREV_PKGS="$(mktemp)"
NEW_PKGS="$(mktemp)"
trap 'rm -f "${PREV_PKGS}" "${NEW_PKGS}"' EXIT

HAVE_PREV=0
if podman pull --quiet "${PREV_IMAGE}" >/dev/null 2>&1; then
    HAVE_PREV=1
    get_packages "${PREV_IMAGE}" >"${PREV_PKGS}"
else
    : >"${PREV_PKGS}"
fi

get_packages "${NEW_IMAGE}" >"${NEW_PKGS}"

: >"${OUTPUT}"

if [[ "${HAVE_PREV}" -eq 1 ]]; then
    echo "## Package changes" >>"${OUTPUT}"
    echo >>"${OUTPUT}"
    echo "| Package | Previous | New |" >>"${OUTPUT}"
    echo "|---|---|---|" >>"${OUTPUT}"
    join -t $'\t' -a1 -a2 -e '-' -o 0,1.2,2.2 -j1 "${PREV_PKGS}" "${NEW_PKGS}" \
        | awk -F'\t' '$2 != $3 { printf "| %s | %s | %s |\n", $1, $2, $3 }' >>"${OUTPUT}"
    echo >>"${OUTPUT}"
else
    echo "## Initial build" >>"${OUTPUT}"
    echo >>"${OUTPUT}"
    echo "No previous image to diff against." >>"${OUTPUT}"
    echo >>"${OUTPUT}"
fi

PREV_SHA=""
if [[ "${HAVE_PREV}" -eq 1 ]]; then
    PREV_SHA="$(get_git_sha "${PREV_IMAGE}")"
fi

echo "## Commits" >>"${OUTPUT}"
echo >>"${OUTPUT}"
if [[ -n "${PREV_SHA}" ]] && git cat-file -e "${PREV_SHA}" 2>/dev/null; then
    git log --pretty='- %h %s' "${PREV_SHA}..HEAD" >>"${OUTPUT}"
else
    echo "(previous build's commit unavailable -- showing latest commit only)" >>"${OUTPUT}"
    git log --pretty='- %h %s' -1 >>"${OUTPUT}"
fi
echo >>"${OUTPUT}"

cat "${OUTPUT}"
