#!/bin/bash

set -ouex pipefail

### HailoRT userspace runtime (libhailort + hailortcli + hailo_platform Python
# bindings) for Hailo-8/8L, pairing with 20-hailo8-pci.sh's kernel driver.
#
# Merges what used to be two separate build steps in the main image:
# images/rpi/build_files/20-hailort-hailo8.sh (C++ lib/CLI) and half of
# images/rpi/build_files/30-hailo-npu-run.sh's build_hailo_python_bindings() (Python
# bindings) -- now ONE rpm covering the whole isolated /opt/hailort-4.24.0 prefix,
# since npu-run's Hailo backend needs both and they were always installed under the
# same prefix anyway.
#
# MIT-licensed (libhailort/hailortcli themselves -- LICENSE-3RD-PARTY.md covers bundled
# deps), pinned commit matching 20-hailo8-pci.sh's driver v4.24.0 exactly: HailoRT and
# its driver are version-locked pairs (same release date on both repos, confirmed) --
# this build will never get an upstream fix for a future toolchain incompatibility,
# since nothing here is ever going to move to a newer commit. Builds with a vendored,
# pinned CMake (versions.env) rather than Fedora's own package for exactly that reason:
# a future Fedora cmake bump breaking this permanently-frozen build, with no upstream
# fix ever coming, is a real risk already hit twice (protobuf's nested sub-build
# assuming lib not lib64; one of the bundled deps' cmake_minimum_required being older
# than CMake 4.0 now allows) -- both only fixable here, not by re-pinning to a newer
# HailoRT commit.
#
# Genuinely heavy build: CMake fetches and compiles protobuf v21.12 from source itself
# (no system package, no sha256 pin possible -- that's their build tooling's own git
# clone, outside our control), then the hailort C++ library/CLI on top, then the
# pybind11 Python extension. Installed under its own prefix (/opt/hailort-4.24.0), not
# /usr -- 31-hailort-hailo1x.sh installs a DIFFERENT, incompatible HailoRT version
# (5.4.0) for the other chip, and the two can't share one libhailort.so/hailortcli/venv.
# A hailortcli-hailo8 symlink in /usr/bin reaches into the isolated prefix instead.
#
# The Python venv can't be created at a buildroot-relative fake path -- venvs bake in
# the real absolute path they were created at (shebangs, pyvenv.cfg, the python3
# symlink), none of that is relocatable. So this hook makes the C++ build genuinely
# real at ${PREFIX} first (a plain `cp -a` from its own buildroot, not `dnf5 install`
# -- there's no rpm yet to install it from), builds the venv directly against that real
# path exactly like the original hook did, THEN copies the now-complete real ${PREFIX}
# (C++ + venv both) into the buildroot the one shipped rpm actually gets built from.

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

# Vendored CMake, not Fedora's cmake package -- see header comment. hailort/cmake/
# execute_cmake.cmake's nested protobuf sub-build invokes cmake via ${CMAKE_COMMAND}
# (always an absolute path), so it picks this same binary up automatically -- no
# separate patching needed for that.
curl -fsSL -o "${TMP}/cmake.tar.gz" "${CMAKE_URL}"
echo "${CMAKE_SHA256}  ${TMP}/cmake.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/cmake.tar.gz" -C "${TMP}"
CMAKE="${TMP}/cmake-${CMAKE_VERSION}-linux-aarch64/bin/cmake"
CMAKE_BIN_DIR="${TMP}/cmake-${CMAKE_VERSION}-linux-aarch64/bin"
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
# exactly that, confirmed in CI.
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

# Make the C++ build genuinely real at ${PREFIX} -- the venv built next has to be
# created directly at this real path (see header comment), it can't be built inside
# the buildroot and copied in afterward like everything else here.
install -d "${PREFIX}"
cp -a "${BUILDROOT}${PREFIX}/." "${PREFIX}/"

BIN_DIR="${BUILDROOT}/usr/bin"
install -d "${BIN_DIR}"
ln -s "${PREFIX}/bin/hailortcli" "${BIN_DIR}/hailortcli-hailo8"

### Python bindings (hailo_platform) -- reuses ${SRC_DIR} already fetched above, same
# source tree and version the C++ build just came from.

python3 -m venv --system-site-packages "${PREFIX}/pyvenv"

# PATH: setup.py's own build_ext shells out to a bare `cmake` -- prepend our vendored
# one so that resolves instead of failing outright (no system cmake package).
# --ignore-requires-python: this package's own metadata declares Requires-Python
# <3.14,>=3.10 (confirmed in CI: "Package 'hailort' requires a different Python:
# 3.14.7 not in '<3.14,>=3.10'") -- a stale upper bound from before Fedora shipped
# 3.14, not a real incompatibility (pybind11 2.13.6, what this actually builds
# against, has no issue with 3.14).
PATH="${CMAKE_BIN_DIR}:${PATH}" \
    LIBHAILORT_PATH="${PREFIX}/lib/libhailort.so" \
    HAILORT_INCLUDE_DIR="${PREFIX}/include" \
    "${PREFIX}/pyvenv/bin/pip" install --no-cache-dir --ignore-requires-python \
    "${SRC_DIR}/hailort/libhailort/bindings/python/platform"

# Upstream bug: the bindings' own CMakeLists.txt sets INSTALL_RPATH to the
# libhailort.so *file* path instead of its directory, but setup.py's own install step
# doesn't even use the CMake-installed copy -- it globs _pyhailort*.so straight out of
# the raw build tree and copies that, so patching INSTALL_RPATH never reaches the
# shipped file (confirmed in CI: "ImportError: libhailort.so.4.24.0: cannot open
# shared object file" persisted after that patch). Fix the actual shipped file
# directly instead.
PYHAILORT_SO=$(find "${PREFIX}/pyvenv" -name '_pyhailort*.so' -print -quit)
if [[ -z "${PYHAILORT_SO}" ]]; then
    echo "error: _pyhailort*.so not found under ${PREFIX}/pyvenv after pip install" >&2
    exit 1
fi
patchelf --set-rpath "${PREFIX}/lib" "${PYHAILORT_SO}"

"${PREFIX}/pyvenv/bin/python3" -c "import hailo_platform" || {
    echo "error: hailo_platform didn't import after building for ${PREFIX}" >&2
    exit 1
}

# ${PREFIX} now genuinely holds both the C++ build and the venv -- capture the WHOLE
# thing (overwriting the C++-only copy already there) into the buildroot the one
# shipped rpm gets built from.
rm -rf "${BUILDROOT}${PREFIX}"
install -d "${BUILDROOT}${PREFIX}"
cp -a "${PREFIX}/." "${BUILDROOT}${PREFIX}/"

RPM_NAME="hailort-hailo8"
SPEC=$(mktemp --suffix=.spec)
cat >"${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${HAILORT_VERSION}
Release: 1
Summary: HailoRT userspace runtime (libhailort/hailortcli) and Python bindings for Hailo-8/8L
License: MIT
BuildArch: ${ARCH}

%description
libhailort.so, hailortcli and the hailo_platform Python bindings (pyhailort), built
from hailo-ai/hailort (commit ${HAILORT_COMMIT}), installed under ${PREFIX} --
isolated from hailort-hailo1x's incompatible v5.4.0 build. Run as hailortcli-hailo8;
the Python bindings' isolated venv lives at ${PREFIX}/pyvenv.

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

# Fail the build rather than ship silently without the runtime -- checked against the
# real ${PREFIX} (already live, see above), not a fresh dnf5 install of the rpm.
[[ -x "${PREFIX}/bin/hailortcli" ]]
[[ -f "${PREFIX}/lib/libhailort.so.${HAILORT_VERSION}" ]]
[[ -x "${PREFIX}/pyvenv/bin/python3" ]]
"${PREFIX}/pyvenv/bin/python3" -c "import hailo_platform"

cp "${RPM_PATH}" /rpms/hailort/

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
