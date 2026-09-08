#!/bin/bash

set -ouex pipefail

# Every kmod/HailoRT hook below needs some subset of this -- installed once here
# rather than piecemeal per-hook since nothing in this builder stage survives into
# the published image anyway (only /rpms does, copied out by the final FROM scratch
# stage in the Containerfile), so unlike the main image's 00-pre-build.sh/
# post-build.sh there's no matching removal step to keep in sync.
dnf5 -y install dnf5-plugins gcc gcc-c++ make binutils git python3-devel patchelf rpm-build

install -d /rpms/kernel /rpms/kmods /rpms/hailort

# Numbered-hook convention, same as build_files/build.sh in the main project --
# add a new hook here without touching this script.
for hook in /ctx/*.sh; do
    [[ -e "${hook}" ]] || continue
    case "$(basename "${hook}")" in
        build.sh) continue ;;
    esac
    bash "${hook}"
done
