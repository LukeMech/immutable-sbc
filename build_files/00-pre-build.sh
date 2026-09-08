#!/bin/bash

set -ouex pipefail

### Never install weak dependencies (Recommends/Supplements)
#
# Runs first so every dnf5 install below is covered -- this is what
# pulled in gnome-tour unasked.
sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

### Replace the base image's own floating kernel with the pinned one from
# images/deps/ (published as ghcr.io/lukemech/immutable-sbc-deps, bind-mounted here
# at /deps-rpms by the main Containerfile) -- every kmod rpm installed by a later
# hook (aic8800/gasket/hailo8-pci/hailo1x-pci) was built in that same deps image
# against this exact kernel version, so the two have to match, and the deps image is
# what actually resolves/downloads Fedora's current kernel (see
# images/deps/build_files/00-kernel.sh) rather than trusting whatever
# fedora-bootc:44's own floating tag happens to have captured that week.
#
# This exact mechanism -- shim kernel-install.d, `rpm --erase --nodeps`, `dnf5
# install` the pinned RPMs, `dnf5 versionlock add`, restore the hooks -- is
# confirmed via ublue-os/bazzite and ublue-os/ucore (aarch64-shipping) as the
# current, non-deprecated way to do this (the older `rpm-ostree override replace`
# pattern is deprecated). Shimming avoids the install.d hooks trying to invoke
# rpm-ostree/dracut mid-transaction -- there's no /run, no booted system, this is a
# plain image build, not a real kernel update. The one real dracut run happens once
# in post-build.sh, after every kmod is also installed -- not here.
pushd /usr/lib/kernel/install.d
mv 05-rpmostree.install 05-rpmostree.install.bak
mv 50-dracut.install 50-dracut.install.bak
printf '%s\n' '#!/bin/sh' 'exit 0' >05-rpmostree.install
printf '%s\n' '#!/bin/sh' 'exit 0' >50-dracut.install
chmod +x 05-rpmostree.install 50-dracut.install
popd

for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
    rpm -q "${pkg}" >/dev/null 2>&1 && rpm --erase "${pkg}" --nodeps
done
rm -rf /usr/lib/modules

# Only the runtime kernel/modules -- NOT kernel-devel/kernel-devel-matched/
# kernel-headers. Nothing compiles in this image any more (every out-of-tree kernel
# module and the whole HailoRT/libedgetpu build now happen in images/deps/ instead,
# installed elsewhere in this build as plain prebuilt rpms), so there's nothing here
# that would ever need a kbuild tree or kernel headers -- installing them would just
# be dead weight shipping in the final image for no reason.
#
# Globs, not exact NVRAs -- images/deps/build_files/00-kernel.sh resolves whatever
# Fedora's current kernel is at ITS build time, so the exact version isn't known
# here. kernel-modules-*.rpm also picks up kernel-modules-core/-extra (same prefix).
dnf5 -y install \
    /deps-rpms/kernel/kernel-[0-9]*.rpm \
    /deps-rpms/kernel/kernel-core-*.rpm \
    /deps-rpms/kernel/kernel-modules-*.rpm

# Guards against some later hook's own `dnf5 install` silently pulling in a
# different kernel as a transitive dependency and undoing the pin above.
dnf5 versionlock add kernel kernel-core kernel-modules kernel-modules-core \
    kernel-modules-extra

pushd /usr/lib/kernel/install.d
mv -f 05-rpmostree.install.bak 05-rpmostree.install
mv -f 50-dracut.install.bak 50-dracut.install
popd

# Confirm the swap actually replaced the base image's kernel rather than somehow
# ending up with both -- exactly one kernel-core installed, and it's the one this
# image is pinned to.
INSTALLED_KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
KERNEL_CORE_COUNT=$(rpm -qa kernel-core | wc -l)
if [[ "${KERNEL_CORE_COUNT}" -ne 1 ]]; then
    echo "error: expected exactly one kernel-core installed after the swap, found ${KERNEL_CORE_COUNT}" >&2
    rpm -qa 'kernel-core*' >&2
    exit 1
fi
if [[ ! -d "/usr/lib/modules/${INSTALLED_KVER}" ]]; then
    echo "error: /usr/lib/modules/${INSTALLED_KVER} missing after the kernel swap" >&2
    exit 1
fi
echo "Kernel swap confirmed: running kernel-core is now ${INSTALLED_KVER}"

# mission-center (below) isn't in Fedora's own repos -- it comes from Terra
# (fyralabs), enabled here just for this install and removed again right after, since
# nothing else in this image needs it.
dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release terra-gpg-keys
