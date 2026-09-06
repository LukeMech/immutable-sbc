#!/bin/bash

set -ouex pipefail

### mesa-libTeflon: libteflon.so, a TFLite delegate for Mesa's "rocket" Gallium
# driver (RK3588(S) NPU only -- not applicable to other SoCs, so this stays
# variant-specific rather than shared).
dnf5 install -y mesa-libTeflon
