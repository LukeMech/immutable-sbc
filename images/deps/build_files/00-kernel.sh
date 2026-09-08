#!/bin/bash

set -ouex pipefail

### Fedora's current kernel, resolved fresh every run -- deliberately NOT a pin in
# versions.env like every other version this project builds. This is what lets the
# main image's own build_files/00-pre-build.sh replace whatever fedora-bootc:44's
# floating tag happens to have with a version this repo actually controls, while
# still tracking Fedora's kernel security updates automatically instead of needing a
# manual pin bump for every kernel release (see
# .github/workflows/build-deps.yml's schedule + push-only-if-changed logic, which is
# what keeps this floating version from publishing a no-op image every run).

install -d /rpms/kernel
cd /rpms/kernel

# kernel-modules(-core/-extra) cover what the main image's kernel swap
# (build_files/00-pre-build.sh) needs, plus kernel-devel for the kmod builds below.
# Deliberately NOT downloading kernel-devel-matched or kernel-headers: nothing here
# or in the main image ever consumes either (kernel-devel-matched exists to match
# whatever kernel a *running* system currently has, which doesn't apply to a plain
# image build; kernel-headers is userspace UAPI headers, unrelated to out-of-tree
# module builds, which need kernel-devel's /usr/src tree instead) -- and Fedora
# doesn't always rebuild kernel-headers in lockstep with kernel-core (confirmed in
# CI: a real kernel-headers-7.1.3 vs. kernel-core-7.1.13 mismatch at the same
# resolution), so requiring it to match KVER below would just be its own source of
# false failures for a package nothing needs.
dnf5 -y download \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel

# Sanity check: every one of the 6 above genuinely landed, all at the SAME version --
# Fedora ships them together in lockstep as one kernel update, so a mismatch here
# means something resolved inconsistently, and the main image's kernel swap would
# otherwise silently mix versions.
KVER=$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core-*.rpm)
for name in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra \
    kernel-devel; do
    if [[ ! -f "${name}-${KVER}.rpm" ]]; then
        echo "error: ${name}-${KVER}.rpm didn't download -- versions resolved inconsistently?" >&2
        ls -la . >&2
        exit 1
    fi
done

echo "Resolved kernel: ${KVER}"

# Install kernel-core/kernel-modules/kernel-devel for THIS version into the builder
# itself -- every later hook (10-aic8800.sh onward) builds kmods against
# /usr/lib/modules/${KVER}/build, which only appears once kernel-devel's own %post
# can find a matching /usr/lib/modules/${KVER} directory, which kernel-core/
# kernel-modules provide. Parallel-installed alongside whatever fedora-bootc:44
# already ships (kernel packages are designed to coexist across versions) -- no
# erase needed here, unlike the real swap in the main image's own 00-pre-build.sh.
dnf5 -y install "./kernel-core-${KVER}.rpm" "./kernel-modules-${KVER}.rpm" \
    "./kernel-devel-${KVER}.rpm"

if [[ ! -e "/usr/lib/modules/${KVER}/build" ]]; then
    echo "error: /usr/lib/modules/${KVER}/build missing after installing kernel-devel" >&2
    exit 1
fi

# Plain-text marker, not embedded in an rpm db (this image is FROM scratch, nothing
# is ever installed in it) -- build-deps.yml's "push only if changed" check reads
# this back out via `podman create` + `podman cp` (no entrypoint to `podman run`)
# rather than reusing scripts/diff-packages.sh, which assumes an installed rpm db.
echo "${KVER}" >/rpms/KVER
