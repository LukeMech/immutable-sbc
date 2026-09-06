#!/bin/bash

set -ouex pipefail

### Enable the RK3588(S) NPU (accel/rocket driver) for every rock-5* board
#
# The NPU's three cores (rknn_core_0/1/2) and their IOMMUs are fully wired
# in upstream rk3588-base.dtsi -- real register addresses, clocks, resets,
# power-domains -- but shipped `status = "disabled"` on the RK3588S boards
# (rock-5a, rock-5c) specifically; the full-RK3588 rock-5* boards already
# enable them upstream. Confirmed by compiling every current upstream
# rock-5* board's actual .dts (cpp + dtc, real source from torvalds/linux)
# and diffing before/after: patching status to "okay" changes only that
# one property on the boards where it was disabled, and is a harmless
# no-op on the boards where it's already enabled -- so it's applied to
# every rock-5* dtb uniformly rather than special-cased per board.
#
# Patches the kernel package's already-compiled .dtb files directly
# (fdtput, by node path) instead of recompiling from .dts source: no
# kernel-devel/dts-source version to keep in sync, works on whatever
# exact .dtb this exact kernel build shipped, and re-applies on every
# image rebuild so it never goes stale across kernel updates.

dnf5 -y install dtc

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
DTB_DIR="/usr/lib/modules/${KVER}/dtb/rockchip"

# NPU core + IOMMU node paths, identical across every rock-5* board (all
# direct children of the root node -- confirmed against rk3588-base.dtsi).
NPU_NODES=(
    /npu@fdab0000
    /iommu@fdab9000
    /npu@fdac0000
    /iommu@fdaca000
    /npu@fdad0000
    /iommu@fdada000
)

mapfile -t DTBS < <(find "${DTB_DIR}" -maxdepth 1 -iname 'rk3588*-rock-5*.dtb')
if [[ ${#DTBS[@]} -eq 0 ]]; then
    echo "error: no rk3588*-rock-5*.dtb found under ${DTB_DIR}" >&2
    exit 1
fi

for dtb in "${DTBS[@]}"; do
    for node in "${NPU_NODES[@]}"; do
        # fdtget fails loudly if the node doesn't exist at all -- catches
        # a future kernel update moving/removing it, rather than fdtput
        # silently fabricating an incomplete node in its place.
        if ! fdtget "${dtb}" "${node}" status >/dev/null 2>&1; then
            echo "error: ${dtb} has no ${node} node -- upstream devicetree layout changed, patch needs updating" >&2
            exit 1
        fi
        fdtput -t s "${dtb}" "${node}" status okay
    done
done

# Confirmed, not assumed: every targeted node on every targeted dtb
# actually reads back "okay" post-patch.
for dtb in "${DTBS[@]}"; do
    for node in "${NPU_NODES[@]}"; do
        status=$(fdtget "${dtb}" "${node}" status)
        if [[ "${status}" != "okay" ]]; then
            echo "error: ${dtb} ${node} status is '${status}', not 'okay' after patching" >&2
            exit 1
        fi
    done
done

dnf5 -y remove dtc
