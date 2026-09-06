#!/bin/bash

set -ouex pipefail

### HailoRT userspace runtime (libhailort + hailortcli) for Hailo-8/8L, pairing with
# 10-hailo8-pcie-driver.sh's kernel driver.
#
# MIT-licensed (libhailort/hailortcli themselves -- LICENSE-3RD-PARTY.md covers bundled
# deps), pinned commit matching that driver's v4.24.0 exactly: HailoRT and its driver
# are version-locked pairs (same release date on both repos, confirmed) -- this build
# will never get an upstream fix for a future toolchain incompatibility, since nothing
# here is ever going to move to a newer commit. Builds with a vendored, pinned CMake
# (versions.env) rather than Fedora's own package for exactly that reason: a future
# Fedora cmake bump breaking this permanently-frozen build, with no upstream fix ever
# coming, is a real risk we've already hit twice (protobuf's nested sub-build assuming
# lib not lib64; one of the bundled deps' cmake_minimum_required being older than
# CMake 4.0 now allows) -- both only fixable by us, not by re-pinning to a newer
# HailoRT commit.
#
# Genuinely heavy build, unlike every other hook here: CMake fetches and compiles
# protobuf v21.12 from source itself (no system package, no sha256 pin possible --
# that's their build tooling's own git clone, outside our control), then the hailort
# C++ library/CLI on top. Expect this to noticeably lengthen the image build.
#
# Installed under its own prefix (/opt/hailort-4.24.0), not /usr --
# 21-hailort-hailo1x.sh installs a DIFFERENT, incompatible HailoRT version (5.4.0) for
# the other chip, and the two can't share one libhailort.so/hailortcli. A
# hailortcli-hailo8 symlink in /usr/bin reaches into the isolated prefix instead.

. /ctx/versions.env
HAILORT_VERSION="${HAILORT_HAILO8_VERSION}"
HAILORT_COMMIT="${HAILORT_HAILO8_COMMIT}"

PREFIX="/opt/hailort-${HAILORT_VERSION}"
ARCH=$(uname -m)

TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/hailort.tar.gz" "${HAILORT_HAILO8_URL}"
echo "${HAILORT_HAILO8_SHA256}  ${TMP}/hailort.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/hailort.tar.gz" -C "${TMP}"
SRC_DIR=$(find "${TMP}" -maxdepth 1 -iname 'hailort-*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: hailort archive didn't extract as expected" >&2
    exit 1
fi

# Vendored CMake, not Fedora's cmake package -- this build is version-locked forever
# (see header comment), so a future Fedora cmake bump could break it again with no
# way to fix it upstream. Pinning the exact build already confirmed to work here means
# that can't happen. hailort/cmake/execute_cmake.cmake's nested protobuf sub-build
# invokes cmake via ${CMAKE_COMMAND} (always an absolute path), so it picks this same
# binary up automatically -- no separate patching needed for that.
curl -fsSL -o "${TMP}/cmake.tar.gz" "${CMAKE_URL}"
echo "${CMAKE_SHA256}  ${TMP}/cmake.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/cmake.tar.gz" -C "${TMP}"
CMAKE="${TMP}/cmake-${CMAKE_VERSION}-linux-aarch64/bin/cmake"
if [[ ! -x "${CMAKE}" ]]; then
    echo "error: cmake archive didn't extract as expected" >&2
    exit 1
fi

# hailort/cmake/external/protobuf.cmake builds protobuf as its own separate, nested
# cmake sub-build, then unconditionally `include()`s its cmake config from a hardcoded
# ".../lib/cmake/protobuf" -- but never passes CMAKE_INSTALL_LIBDIR to that sub-build,
# so on a lib64 system (Fedora aarch64 included) protobuf installs into lib64 instead
# and that include() fails outright ("could not find requested file"). Confirmed
# upstream bug, fix not yet merged (hailo-ai/hailort#34) -- inject the same one-line
# fix that PR uses ourselves rather than wait on it.
sed -i '/-Dprotobuf_BUILD_TESTS:BOOL=OFF/i\                -DCMAKE_INSTALL_LIBDIR=lib' \
    "${SRC_DIR}/hailort/cmake/external/protobuf.cmake"
if ! grep -q 'CMAKE_INSTALL_LIBDIR=lib' "${SRC_DIR}/hailort/cmake/external/protobuf.cmake"; then
    echo "error: protobuf.cmake patch didn't apply -- upstream file layout changed?" >&2
    exit 1
fi

BUILD_DIR="${TMP}/build"
# CMAKE_INSTALL_LIBDIR pinned explicitly -- GNUInstallDirs' lib-vs-lib64 guess isn't
# something we also want to have to guess right when setting RPATH below.
# CMAKE_INSTALL_RPATH + CMAKE_BUILD_WITH_INSTALL_RPATH: without this, hailortcli has no
# baked-in path to find libhailort.so.4.24.0 -- this isolated prefix is never on the
# system's default library search path.
# CMAKE_POLICY_VERSION_MINIMUM: one of the FetchContent-bundled deps (cli11)
# cmake_minimum_requires a version below 3.5, which modern CMake refuses outright
# ("Compatibility with CMake < 3.5 has been removed") rather than just warning, unlike
# the other bundled deps here -- this is CMake's own documented escape hatch for
# exactly that, confirmed in CI. Applies to every add_subdirectory()'d dep in this one
# configure (cli11 included); protobuf's separate nested sub-build above doesn't need
# it -- its own minimum is still above 3.5, just old enough to warn.
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
ln -s "${PREFIX}/bin/hailortcli" "${BIN_DIR}/hailortcli-hailo8"

RPM_NAME="hailort-hailo8"
SPEC=$(mktemp --suffix=.spec)
cat >"${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${HAILORT_VERSION}
Release: 1
Summary: HailoRT userspace runtime (libhailort/hailortcli) for Hailo-8/8L
License: MIT
BuildArch: ${ARCH}

%description
libhailort.so and hailortcli, built from hailo-ai/hailort (commit ${HAILORT_COMMIT}),
installed under ${PREFIX} -- isolated from 21-hailort-hailo1x.sh's incompatible v5.4.0
build. Run as hailortcli-hailo8.

%files
${PREFIX}
/usr/bin/hailortcli-hailo8

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
[[ -x /usr/bin/hailortcli-hailo8 ]]
[[ -f "${PREFIX}/lib/libhailort.so.${HAILORT_VERSION}" ]]

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
