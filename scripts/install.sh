#!/bin/sh
# Install the prebuilt aml_w1 WiFi driver modules from a release tarball.
# Run as root:  sudo ./install.sh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNING="$(uname -r)"
TARGET_KVER="$(cat "$DIR/KERNEL_VERSION" 2>/dev/null || true)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo ./install.sh" >&2
  exit 1
fi

if [ -n "$TARGET_KVER" ] && [ "$TARGET_KVER" != "$RUNNING" ]; then
  echo "WARNING: these modules were built for kernel '$TARGET_KVER'"
  echo "         but you are running '$RUNNING'."
  echo "         They will almost certainly fail to load. Build from source instead."
  printf "Continue anyway? [y/N] "
  read ans
  case "$ans" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

DEST="/lib/modules/${RUNNING}/kernel/drivers/net/wireless"
echo "Installing modules to $DEST"
mkdir -p "$DEST"
cp "$DIR/aml_sdio.ko" "$DIR/vlsicomm.ko" "$DEST/"
depmod -a

# Auto-load on boot (load aml_sdio first, then vlsicomm).
for m in aml_sdio vlsicomm; do
  grep -qxF "$m" /etc/modules 2>/dev/null || echo "$m" >> /etc/modules
done

# Load now.
modprobe aml_sdio
modprobe vlsicomm

echo "Done. Check the interface with:  ip link show wlan0"
echo "Next: set up WiFi auto-connect — README section 4, steps 3-7 (steps 1-2 are done)."
