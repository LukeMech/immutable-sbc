#!/bin/bash

set -ouex pipefail

### Mesa's NPU userspace delegate (mesa-libTeflon)
# libteflon.so, a TensorFlow Lite delegate for Mesa's "rocket" Gallium driver (RK3588(S) NPU) -- its own Fedora package, not bundled with Mesa by default.
dnf5 -y install mesa-libTeflon
