#!/usr/bin/env bash
# Cross-compile the aml_w1 driver for arm64 inside WSL Debian (x86_64 host).
# Run as root, e.g.:  wsl -d Debian -u root -- bash scripts/wsl-build.sh
set -euo pipefail

KVER="6.18.40-meson64"
DEB_URL="https://github.com/devmfc/debian-on-amlogic/releases/download/v6.18.40/linux-headers-6.18.40-meson64_20260726_arm64.deb"
SRCDIR="/usr/src/linux-headers-${KVER}"
KERNELDIR="/lib/modules/${KVER}/build"
XC="aarch64-linux-gnu-"
# Repo root = parent of this script's directory (portable across machines).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Repo: ${REPO}"
echo "==> Kernel: ${KVER}"

echo "==> Installing build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev \
    gcc-aarch64-linux-gnu wget ca-certificates perl git kmod

if [ ! -f "${SRCDIR}/Makefile" ]; then
    echo "==> Downloading kernel headers .deb"
    [ -f /tmp/headers.deb ] || wget -q -O /tmp/headers.deb "${DEB_URL}"
    # Never extract straight into / : the arm64 pkg's ./lib entry would clobber
    # the merged-usr /lib symlink. Unpack to a temp tree and copy only what we need.
    echo "==> Extracting headers (safe, via temp tree)"
    rm -rf /tmp/hdr; mkdir -p /tmp/hdr
    dpkg-deb -x /tmp/headers.deb /tmp/hdr
    cp -a "/tmp/hdr/usr/src/linux-headers-${KVER}" /usr/src/
    mkdir -p "/lib/modules/${KVER}"
    ln -sfn "${SRCDIR}" "${KERNELDIR}"
fi

echo "==> Preparing kernel headers (host scripts + arm64 config)"
cd "${SRCDIR}"
find . -type f -exec touch {} +
make ARCH=arm64 CROSS_COMPILE="${XC}" olddefconfig
make ARCH=arm64 CROSS_COMPILE="${XC}" -s scripts
make ARCH=arm64 CROSS_COMPILE="${XC}" -s M=scripts/mod/

# Ensure /lib/modules/<ver>/build points at the header tree.
if [ ! -e "${KERNELDIR}" ]; then
    mkdir -p "/lib/modules/${KVER}"
    ln -sfn "${SRCDIR}" "${KERNELDIR}"
fi
echo "==> KERNELDIR -> $(readlink -f "${KERNELDIR}")"

# Build out-of-tree on native ext4 to avoid drvfs quirks.
BUILD_SRC="/tmp/aml_w1_build"
echo "==> Copying sources to ${BUILD_SRC}"
rm -rf "${BUILD_SRC}"
mkdir -p "${BUILD_SRC}"
cp -a "${REPO}/project_w1" "${BUILD_SRC}/"

cd "${BUILD_SRC}/project_w1"
echo "==> make clean"
make clean ARCH=arm64 CROSS_COMPILE="${XC}" KERNELDIR="${KERNELDIR}" || true

echo "==> make driver"
make driver ARCH=arm64 CROSS_COMPILE="${XC}" KERNELDIR="${KERNELDIR}"

echo "==> Build finished. Resulting kernel modules:"
find "${BUILD_SRC}/project_w1" -name '*.ko' -exec ls -la {} \;
find "${BUILD_SRC}/project_w1" -name '*.ko' -exec file {} \;
