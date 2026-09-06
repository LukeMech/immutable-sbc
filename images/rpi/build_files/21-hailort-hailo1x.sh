#!/bin/bash

set -ouex pipefail

### HailoRT userspace runtime (libhailort + hailortcli) for Hailo-10H/15, pairing with
# 11-hailo1x-pcie-driver.sh's kernel driver. See 20-hailort-hailo8.sh's header for the
# shared reasoning (protobuf-from-source build cost, why this is version-isolated
# under its own prefix rather than /usr) -- this is the same build, just the other
# pinned version/prefix, kept in its own file to mirror the driver hooks' 10/11 split.

. /ctx/versions.env
HAILORT_VERSION="${HAILORT_HAILO1X_VERSION}"
HAILORT_COMMIT="${HAILORT_HAILO1X_COMMIT}"

PREFIX="/opt/hailort-${HAILORT_VERSION}"
ARCH=$(uname -m)

TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/hailort.tar.gz" "${HAILORT_HAILO1X_URL}"
echo "${HAILORT_HAILO1X_SHA256}  ${TMP}/hailort.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/hailort.tar.gz" -C "${TMP}"
SRC_DIR=$(find "${TMP}" -maxdepth 1 -iname 'hailort-*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: hailort archive didn't extract as expected" >&2
    exit 1
fi

# Vendored CMake, not Fedora's cmake package -- see 20-hailort-hailo8.sh's header for
# why (this build is just as version-locked as that one, same risk applies).
curl -fsSL -o "${TMP}/cmake.tar.gz" "${CMAKE_URL}"
echo "${CMAKE_SHA256}  ${TMP}/cmake.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/cmake.tar.gz" -C "${TMP}"
CMAKE="${TMP}/cmake-${CMAKE_VERSION}-linux-aarch64/bin/cmake"
if [[ ! -x "${CMAKE}" ]]; then
    echo "error: cmake archive didn't extract as expected" >&2
    exit 1
fi

# Same nested-protobuf-sub-build lib64 bug as 20-hailort-hailo8.sh -- see its comment
# for the full story (hailo-ai/hailort#34, not yet merged on this branch either).
sed -i '/-Dprotobuf_BUILD_TESTS:BOOL=OFF/i\                -DCMAKE_INSTALL_LIBDIR=lib' \
    "${SRC_DIR}/hailort/cmake/external/protobuf.cmake"
if ! grep -q 'CMAKE_INSTALL_LIBDIR=lib' "${SRC_DIR}/hailort/cmake/external/protobuf.cmake"; then
    echo "error: protobuf.cmake patch didn't apply -- upstream file layout changed?" >&2
    exit 1
fi

BUILD_DIR="${TMP}/build"
# CMAKE_POLICY_VERSION_MINIMUM: see 20-hailort-hailo8.sh's comment -- one of the
# FetchContent-bundled deps (cli11) cmake_minimum_requires below 3.5, which modern
# CMake refuses outright rather than just warning; this is CMake's own documented
# escape hatch for exactly that.
"${CMAKE}" -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib" \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

"${CMAKE}" --build "${BUILD_DIR}" --parallel "$(nproc)"

BUILDROOT=$(mktemp -d)
DESTDIR="${BUILDROOT}" "${CMAKE}" --install "${BUILD_DIR}"

CLI_PATH="${BUILDROOT}${PREFIX}/bin/hailortcli"
if [[ ! -f "${CLI_PATH}" ]]; then
    echo "error: build didn't produce ${PREFIX}/bin/hailortcli" >&2
    exit 1
fi

BIN_DIR="${BUILDROOT}/usr/bin"
install -d "${BIN_DIR}"
ln -s "${PREFIX}/bin/hailortcli" "${BIN_DIR}/hailortcli-hailo1x"

RPM_NAME="hailort-hailo1x"
SPEC=$(mktemp --suffix=.spec)
cat >"${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${HAILORT_VERSION}
Release: 1
Summary: HailoRT userspace runtime (libhailort/hailortcli) for Hailo-10H/15
License: MIT
BuildArch: ${ARCH}

%description
libhailort.so and hailortcli, built from hailo-ai/hailort (commit ${HAILORT_COMMIT}),
installed under ${PREFIX} -- isolated from 20-hailort-hailo8.sh's incompatible v4.24.0
build. Run as hailortcli-hailo1x.

%files
${PREFIX}
/usr/bin/hailortcli-hailo1x

%post
ldconfig

%postun
ldconfig
EOF

TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${TOPDIR}" --buildroot "${BUILDROOT}" "${SPEC}"

RPM_PATH=$(find "${TOPDIR}/RPMS" -iname "${RPM_NAME}-${HAILORT_VERSION}*.rpm" -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce ${RPM_NAME}-${HAILORT_VERSION} under ${TOPDIR}/RPMS" >&2
    exit 1
fi

dnf5 -y install "${RPM_PATH}"

# Fail the build rather than ship silently without the runtime.
rpm -q "${RPM_NAME}"
[[ -x /usr/bin/hailortcli-hailo1x ]]
[[ -f "${PREFIX}/lib/libhailort.so.${HAILORT_VERSION}" ]]

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
