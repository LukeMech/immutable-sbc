#!/bin/bash

set -ouex pipefail

### Final cleanup: every COPR repo any hook enabled, every build-time-only dependency
# 00-pre-build.sh installed, and the dnf cache -- all build-time-only convenience,
# none of it should survive into the final image.
#
# Not picked up by either hook loop in build.sh -- invoked explicitly there, after
# every hook (shared and variant) has already run. The shared build_files/*.sh loop
# finishes in full before the variant loop even starts, so a shared "99-"-style hook
# picked up by that loop's own glob would still run before any variant hook, not after
# (and those variant hooks are exactly the ones still needing kernel-devel/gcc-c++ etc.)
# -- hence invoking this explicitly instead.
#
# `copr remove` (unlike `disable`) cleans up the .repo file and imported GPG key, and
# must run before the plugin package providing it is removed. Repo id is the standard
# `_copr:<host>:<owner>:<project>.repo` naming, so owner/project comes straight back
# out of the filename rather than needing each hook to report what it enabled.
shopt -s nullglob
for repo_file in /etc/yum.repos.d/_copr:*.repo; do
    project=$(basename "${repo_file}" .repo | cut -d: -f3-4 --output-delimiter=/)
    dnf5 -y copr remove "${project}"
done

case "${VARIANT}" in
    rk3588)
        # Nothing to remove -- see 00-pre-build.sh's matching case.
        ;;
    rpi)
        dnf5 -y remove gcc-c++ git
        ;;
esac

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
dnf5 -y remove "kernel-devel-${KVER}" gcc make binutils dnf5-plugins terra-release terra-gpg-keys rpm-build

# Final housekeeping
dnf5 -y clean all
