#!/bin/bash
# Downloads and verifies a firmware blob. Generic on purpose: which URL/checksum
# to use is a per-board concern (images/boards.toml), not this script's.
#
# Usage: fetch-firmware.sh <url> <sha256> <output>

set -euo pipefail

FW_URL="${1:?usage: $0 <url> <sha256> <output>}"
FW_SHA256="${2:?usage: $0 <url> <sha256> <output>}"
OUT="${3:?usage: $0 <url> <sha256> <output>}"

echo "Fetching ${FW_URL}"
curl -fsSL -o "${OUT}" "${FW_URL}"

echo "${FW_SHA256}  ${OUT}" | sha256sum -c -
echo "Verified firmware image: ${OUT}"
