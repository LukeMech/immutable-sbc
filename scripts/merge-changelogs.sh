#!/bin/bash
#
# Release changelog's package section, from each variant's diff-packages.sh output
# (package-changelog-<variant>.md/.tsv in <artifact-dir>). Printed to stdout.
#
# With several variants, a change that's identical in every one of them (same package,
# same previous and new version) goes into one "All images" section; each variant's
# own section then keeps only what's specific to it. Only done when every variant has
# a TSV -- an initial build or a missing artifact would make "shared by all" a lie,
# so that case falls back to each variant's full section as-is.
#
# Usage: merge-changelogs.sh <artifact-dir> <variant>...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIR="${1:?usage: $0 <artifact-dir> <variant>...}"
shift
VARIANTS=("$@")
[[ ${#VARIANTS[@]} -gt 0 ]] || { echo "usage: $0 <artifact-dir> <variant>..." >&2; exit 1; }

COMMON="$(mktemp)"
REST="$(mktemp)"
trap 'rm -f "${COMMON}" "${REST}"' EXIT

# A changelog is a nicety, not a reason to block the release -- fall back to a
# placeholder if the artifact's missing.
print_variant_md() {
    local md="${DIR}/package-changelog-${1,,}.md"
    if [[ -f "${md}" ]]; then
        cat "${md}"
    else
        echo "## Notes"
        echo
        echo "Changelog artifact missing for this variant -- see commit history below."
        echo
    fi
}

if [[ ${#VARIANTS[@]} -eq 1 ]]; then
    print_variant_md "${VARIANTS[0]}"
    exit 0
fi

ALL_HAVE_TSV=1
for VARIANT in "${VARIANTS[@]}"; do
    [[ -f "${DIR}/package-changelog-${VARIANT,,}.tsv" ]] || ALL_HAVE_TSV=0
done

if [[ "${ALL_HAVE_TSV}" -eq 0 ]]; then
    for VARIANT in "${VARIANTS[@]}"; do
        echo "# ${VARIANT}"
        echo
        print_variant_md "${VARIANT}"
    done
    exit 0
fi

# Rows present in every variant's TSV, in the first variant's order (already sorted
# by name within each bucket).
TSVS=()
for VARIANT in "${VARIANTS[@]}"; do
    TSVS+=("${DIR}/package-changelog-${VARIANT,,}.tsv")
done
awk -v n="${#TSVS[@]}" '
    FNR == 1 { file++ }
    !seen[file, $0]++ { count[$0]++; if (file == 1) order[++rows] = $0 }
    END { for (i = 1; i <= rows; i++) if (count[order[i]] == n) print order[i] }
' "${TSVS[@]}" >"${COMMON}"

if [[ -s "${COMMON}" ]]; then
    echo "# All images"
    echo
    "${SCRIPT_DIR}/render-package-changes.sh" "${COMMON}"
fi

for VARIANT in "${VARIANTS[@]}"; do
    grep -vxF -f "${COMMON}" "${DIR}/package-changelog-${VARIANT,,}.tsv" >"${REST}" || true
    echo "# ${VARIANT}"
    echo
    if [[ -s "${COMMON}" ]]; then
        "${SCRIPT_DIR}/render-package-changes.sh" "${REST}" "No changes beyond All images."
    else
        "${SCRIPT_DIR}/render-package-changes.sh" "${REST}"
    fi
done
