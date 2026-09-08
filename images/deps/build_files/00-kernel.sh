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

# kernel-modules-*.rpm below also matches kernel-modules-core/-extra (same name
# prefix), and kernel-devel-*.rpm also matches kernel-devel-matched, same reason --
# so these 6 arguments cover the 8 packages the main image's kernel swap needs.
dnf5 -y download \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched \
    kernel-headers

# Sanity check: every one of the 8 above genuinely landed, all at the SAME version --
# Fedora ships them together in lockstep as one kernel update, so a mismatch here
# means something resolved inconsistently, and the main image's kernel swap would
# otherwise silently mix versions.
KVER=$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core-*.rpm)
for name in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra \
    kernel-devel kernel-devel-matched kernel-headers; do
    if [[ ! -f "${name}-${KVER}.rpm" ]]; then
        echo "error: ${name}-${KVER}.rpm didn't download -- versions resolved inconsistently?" >&2
        ls -la . >&2
        exit 1
    fi
done

echo "Resolved kernel: ${KVER}"

# Plain-text marker, not embedded in an rpm db (this image is FROM scratch, nothing
# is ever installed in it) -- build-deps.yml's "push only if changed" check reads
# this back out via `podman create` + `podman cp` (no entrypoint to `podman run`)
# rather than reusing scripts/diff-packages.sh, which assumes an installed rpm db.
echo "${KVER}" >/rpms/KVER
