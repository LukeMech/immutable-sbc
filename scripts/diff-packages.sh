#!/bin/bash
#
# Package-changes section of the changelog: an rpm -qa diff between
# <previous-image-ref> and <new-image-ref>, split into added/removed/
# updated (each only shown if non-empty) -- a plain "No package changes."
# line if nothing differs, or "## Initial build" if <previous-image-ref>
# doesn't exist yet.
#
# Runs pre-push, in build.yml's build_push job, right after the image is
# built -- not just for the changelog, but because that's also how a
# schedule-triggered run (the biweekly cron fallback for quiet periods)
# decides whether it found anything new to publish at all: grep the
# output for the "No package changes." line.
#
# Usage: diff-packages.sh <previous-image-ref> <new-image-ref> <output.md>
#
# <previous-image-ref> may not exist yet (first-ever build) -- that's
# handled, it just means no diff, only "initial build".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREV_IMAGE="${1:?usage: $0 <previous-image-ref> <new-image-ref> <output.md>}"
NEW_IMAGE="${2:?usage: $0 <previous-image-ref> <new-image-ref> <output.md>}"
OUTPUT="${3:?usage: $0 <previous-image-ref> <new-image-ref> <output.md>}"

PREV_PKGS="$(mktemp)"
NEW_PKGS="$(mktemp)"
ADDED="$(mktemp)"
REMOVED="$(mktemp)"
UPDATED="$(mktemp)"
trap 'rm -f "${PREV_PKGS}" "${NEW_PKGS}" "${ADDED}" "${REMOVED}" "${UPDATED}"' EXIT

HAVE_PREV=0
if podman pull --quiet "${PREV_IMAGE}" >/dev/null 2>&1; then
    HAVE_PREV=1
    "${SCRIPT_DIR}/list-packages.sh" "${PREV_IMAGE}" >"${PREV_PKGS}"
else
    : >"${PREV_PKGS}"
fi

"${SCRIPT_DIR}/list-packages.sh" "${NEW_IMAGE}" >"${NEW_PKGS}"

: >"${OUTPUT}"

if [[ "${HAVE_PREV}" -eq 1 ]]; then
    # name<TAB>previous<TAB>new for every package on either side ('-' for
    # whichever side doesn't have it), routed into one of three buckets --
    # never a single mixed table, so a release with (say) only updates
    # doesn't show two empty "Added"/"Removed" headers for nothing.
    while IFS=$'\t' read -r name prev new; do
        if [[ "${prev}" == "${new}" ]]; then
            continue
        elif [[ "${prev}" == "-" ]]; then
            printf '| %s | %s |\n' "${name}" "${new}" >>"${ADDED}"
        elif [[ "${new}" == "-" ]]; then
            printf '| %s | %s |\n' "${name}" "${prev}" >>"${REMOVED}"
        else
            printf '| %s | %s | %s |\n' "${name}" "${prev}" "${new}" >>"${UPDATED}"
        fi
    done < <(join -t $'\t' -a1 -a2 -e '-' -o 0,1.2,2.2 -j1 "${PREV_PKGS}" "${NEW_PKGS}")

    if [[ -s "${ADDED}" || -s "${REMOVED}" || -s "${UPDATED}" ]]; then
        echo "## 📦 Package changes" >>"${OUTPUT}"
        echo >>"${OUTPUT}"

        if [[ -s "${ADDED}" ]]; then
            echo "### ✨ Added" >>"${OUTPUT}"
            echo >>"${OUTPUT}"
            echo "| Package | Version |" >>"${OUTPUT}"
            echo "|---|---|" >>"${OUTPUT}"
            cat "${ADDED}" >>"${OUTPUT}"
            echo >>"${OUTPUT}"
        fi

        if [[ -s "${UPDATED}" ]]; then
            echo "### 🔄 Updated" >>"${OUTPUT}"
            echo >>"${OUTPUT}"
            echo "| Package | Previous | New |" >>"${OUTPUT}"
            echo "|---|---|---|" >>"${OUTPUT}"
            cat "${UPDATED}" >>"${OUTPUT}"
            echo >>"${OUTPUT}"
        fi

        if [[ -s "${REMOVED}" ]]; then
            echo "### ❌ Removed" >>"${OUTPUT}"
            echo >>"${OUTPUT}"
            echo "| Package | Version |" >>"${OUTPUT}"
            echo "|---|---|" >>"${OUTPUT}"
            cat "${REMOVED}" >>"${OUTPUT}"
            echo >>"${OUTPUT}"
        fi
    else
        echo "## 📦 Package changes" >>"${OUTPUT}"
        echo >>"${OUTPUT}"
        echo "No package changes." >>"${OUTPUT}"
        echo >>"${OUTPUT}"
    fi
else
    echo "## Initial build" >>"${OUTPUT}"
    echo >>"${OUTPUT}"
    echo "No previous image to diff against." >>"${OUTPUT}"
    echo >>"${OUTPUT}"
fi

cat "${OUTPUT}"
