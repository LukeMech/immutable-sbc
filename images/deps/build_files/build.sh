#!/bin/bash

set -ouex pipefail

# Every kmod/HailoRT hook below needs some subset of this -- installed once here
# rather than piecemeal per-hook since nothing in this builder stage survives into
# the published image anyway (only /rpms does, copied out by the final FROM scratch
# stage in the Containerfile), so unlike the main image's 00-pre-build.sh/
# post-build.sh there's no matching removal step to keep in sync.
#
# python3-numpy specifically: 30-/31-hailort-hailo*.sh create their pyvenv with
# --system-site-packages, so hailo_platform's own `pip install` sees a numpy already
# satisfied here and reuses it instead of pulling its own PyPI wheel. That matters
# because PyPI's manylinux numpy wheel vendors its own OpenBLAS/gfortran under a
# hash-suffixed filename (e.g. libgfortran-<hash>.so.5.0.0) private to that wheel --
# rpm's automatic dependency scanner picks up a Requires on that exact hashed name
# from numpy's own .so files, which nothing in the final image (installing just the
# hailort-hailo8/1x rpm on its own) can ever provide. Fedora's own python3-numpy
# links against its normally-packaged libopenblas/libgfortran instead (a plain
# Requires any image already has, see build_files/10-prepare-npu-run-module.sh),
# avoiding the mismatch entirely (confirmed in CI: "nothing provides
# libgfortran-e1b7dfc8-d8198c01.so.5.0.0(GFORTRAN_8)(64bit)").
dnf5 -y install dnf5-plugins gcc gcc-c++ make binutils git python3-devel python3-numpy patchelf rpm-build

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
