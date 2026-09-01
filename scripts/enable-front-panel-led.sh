#!/bin/bash
# Enable the front-panel LED display (4-digit + icons) on a Magicsee N5 Max X4.
#
#   sudo ./scripts/enable-front-panel-led.sh          # install, then reboot
#   sudo ./scripts/enable-front-panel-led.sh --test   # show a test pattern on a working panel
#   sudo ./scripts/enable-front-panel-led.sh --revert # undo everything
#
# Why this is needed: devmfc's Debian image boots meson-sc2-x96x4.dtb on this box because it is
# the closest match, but that DTB describes the *X96 X4* front panel (TM1628, 3-wire, GPIOA_14 /
# GPIOA_15 / GPIOD_10). The Magicsee N5 Max X4 carries an FD6551 driven over 2 wires on GPIOD_6 /
# GPIOD_7 and has no STB line, so the stock DTB leaves the panel dead — only the discrete power
# LED (wired straight to the board, not to the display controller) stays lit.
#
# Values come from the stock Android openvfd config for this box:
#   https://github.com/arthur-liberman/vfd-configurations/blob/master/magicsee-n5-max-x4-vfd.conf
#     vfd_gpio_clk='0,35,0'  vfd_gpio_dat='0,36,0'  vfd_gpio_stb='0,0,0xFF'
#     vfd_display_type='0x01,0x00,0x00,0x06'   -> display type 1 (T95), controller 6 (FD6551)
# Pin numbers are indexes into dt-bindings/gpio/meson-sc2-gpio.h: 35 = GPIOD_6, 36 = GPIOD_7.
#
# What gets installed, and why it is split in three:
#   1. the booted DTB is edited in place — u-boot's boot.scr has no `fdt apply`, so device-tree
#      overlays are not an option on this image;
#   2. the segment map lives in its own systemd unit instead of a patch to
#      /usr/lib/tm16xx-display/display_service.sh, because that file belongs to the
#      `tm16xx-display` package and any update would silently revert an in-file patch;
#   3. a /etc/kernel/postinst.d hook re-patches the DTB of every newly installed kernel, since
#      each linux-image package ships its own unpatched /boot/dtb-<version>/ tree.
set -euo pipefail

VFD_COMPATIBLE="${VFD_COMPATIBLE:-devmfc,fd6551}"
VFD_CLK="${VFD_CLK:-35}"          # GPIOD_6
VFD_DAT="${VFD_DAT:-36}"          # GPIOD_7
VFD_GPIO_FLAGS="${VFD_GPIO_FLAGS:-0x06}"

# map6 from /usr/lib/tm16xx-display/tm16xx-map.sh: 5 digits, reverse order, FD6551 (T95 family).
# Each byte is (display-RAM byte index << 4) | bit index; 0xff means "segment not wired".
VFD_MAP="${VFD_MAP:-13 14 15 10 11 12 16 ff \
23 24 25 20 21 22 26 ff \
33 34 35 30 31 32 36 ff \
43 44 45 40 41 42 46 ff \
ff 05 06 ff ff ff ff ff \
01 02 03 ff ff ff ff ff}"

SELF_INSTALLED=/usr/local/sbin/enable-front-panel-led.sh
MAP_HELPER=/usr/local/sbin/front-panel-led-map
MAP_UNIT=/etc/systemd/system/front-panel-led-map.service
MAP_RULE=/etc/udev/rules.d/86-front-panel-led-map.rules
KERNEL_HOOK=/etc/kernel/postinst.d/zz-front-panel-led
RUNFILE=/run/tm16xx.run

die() { echo "error: $*" >&2; exit 1; }

# The platform device keeps its device-tree node name, so it stays tm1628 even after the
# compatible string is switched to fd6551.
dev_path() { dirname /sys/bus/platform/drivers/tm16xx/*/digits 2>/dev/null; }

# ---------------------------------------------------------------- DTB helpers

# u-boot picks the DTB via /boot/boot.config -> /boot/box-config/box-<box>.config, and the path
# there contains a literal ${release} placeholder.
dtb_for_release() {
    local rel="$1" box img
    box=$(sed -n 's/^box=//p' /boot/boot.config 2>/dev/null | tail -1)
    [ -n "$box" ] && [ -n "$rel" ] || return 1
    img=$(sed -n 's/^dtb_img=//p' "/boot/box-config/box-${box}.config" 2>/dev/null | tail -1)
    [ -n "$img" ] || return 1
    echo "/boot/${img//\$\{release\}/${rel}}"
}

find_dtb() {
    dtb_for_release "$(sed -n 's/^release=//p' /boot/boot.config 2>/dev/null | tail -1)"
}

# The VFD node is whichever root-level node the tm16xx driver claims.
find_vfd_node() {
    local n c
    for n in $(fdtget -l "$1" / 2>/dev/null); do
        c=$(fdtget -t s "$1" "/$n" compatible 2>/dev/null || true)
        case "$c" in devmfc,*) echo "/$n"; return 0 ;; esac
    done
    return 1
}

patch_dtb() {
    local dtb="$1" node phandle cur

    node="${VFD_NODE:-$(find_vfd_node "$dtb" || true)}"
    [ -n "$node" ] || die "no devmfc VFD node in $dtb — this box has no supported front panel"

    cur=$(fdtget -t x "$dtb" "$node" clk-gpios 2>/dev/null || true)
    # Reuse the phandle already in the DTB rather than hardcoding it — it differs per DTB variant.
    phandle=$(echo "$cur" | awk '{print $1}')
    [ -n "$phandle" ] || die "$node has no clk-gpios to take the GPIO controller phandle from"

    echo "    node:   $node"
    echo "    before: compatible=$(fdtget -t s "$dtb" "$node" compatible 2>/dev/null) clk-gpios=($cur)"

    cp -n "$dtb" "$dtb.pre-vfd" 2>/dev/null || true
    fdtput -t s "$dtb" "$node" compatible "$VFD_COMPATIBLE"
    fdtput -t x "$dtb" "$node" clk-gpios "0x$phandle" "$(printf '0x%x' "$VFD_CLK")" "$VFD_GPIO_FLAGS"
    fdtput -t x "$dtb" "$node" dat-gpios "0x$phandle" "$(printf '0x%x' "$VFD_DAT")" "$VFD_GPIO_FLAGS"
    # FD6551 is a 2-wire part: a leftover strobe line makes the driver speak a protocol the chip
    # does not understand, so the property has to go rather than just be ignored.
    fdtput -d "$dtb" "$node" stb-gpios 2>/dev/null || true

    echo "    after:  compatible=$(fdtget -t s "$dtb" "$node" compatible)" \
         "clk-gpios=($(fdtget -t x "$dtb" "$node" clk-gpios))" \
         "dat-gpios=($(fdtget -t x "$dtb" "$node" dat-gpios))" \
         "stb-gpios=$(fdtget -t x "$dtb" "$node" stb-gpios 2>/dev/null || echo removed)"

    # Only the exit status matters; these DTBs always emit a pile of style warnings.
    dtc -I dtb -O dts "$dtb" >/dev/null 2>&1 || die "patched DTB no longer parses — restore $dtb.pre-vfd"
}

# ---------------------------------------------------------------- modes

live_test() {
    local dev
    dev="$(dev_path)"
    [ -d "$dev" ] || die "no tm16xx device bound — run without arguments and reboot first"
    echo "==> device: $dev  ($(tr -d '\0' < /proc/device-tree/tm1628/compatible 2>/dev/null))"
    # Never use `systemctl stop tm16xx-display`: that unit is DefaultDependencies=no and stopping
    # it takes the whole box down. It polls this run file, so removing it ends the loop cleanly.
    rm -f "$RUNFILE"; sleep 6; pkill -f 'display_service.sh start' 2>/dev/null || true; sleep 1
    echo "$VFD_MAP" > "$dev/mapping"
    echo 7 > "$dev/brightness"
    echo '8888+COLON' > "$dev/digits"
    echo "==> '8888' + colon for 5s — every segment should light"
    sleep 5
    echo '1234-COLON' > "$dev/digits"
    echo "==> '1234' for 5s — check the digit order reads left to right"
    sleep 5
    systemctl start tm16xx-display.service
    echo "==> normal display service restarted"
}

revert() {
    local dtb rel
    for rel in $(ls -d /boot/dtb-*/ 2>/dev/null | sed 's#.*/boot/dtb-##; s#/##'); do
        dtb="$(dtb_for_release "$rel" || true)"
        [ -n "$dtb" ] && [ -f "$dtb.pre-vfd" ] && { cp "$dtb.pre-vfd" "$dtb"; echo "restored $dtb"; }
    done
    systemctl disable --now front-panel-led-map.service 2>/dev/null || true
    rm -f "$MAP_UNIT" "$MAP_RULE" "$MAP_HELPER" "$KERNEL_HOOK" "$SELF_INSTALLED"
    systemctl daemon-reload
    udevadm control --reload 2>/dev/null || true
    echo "removed the map service, its udev rule, the kernel hook and the installed copy"
    echo "reboot to go back to the stock device tree"
}

install_map_service() {
    cat > "$MAP_HELPER" <<EOF
#!/bin/sh
# The tm16xx driver derives its segment map at probe time from a built-in TM1628 default, so the
# real map for this panel has to be pushed in from userspace on every boot.
for _ in 1 2 3 4 5; do
    dev=\$(dirname /sys/bus/platform/drivers/tm16xx/*/digits 2>/dev/null)
    [ -d "\$dev" ] && break
    sleep 1
done
[ -d "\$dev" ] || exit 0
echo "$VFD_MAP" > "\$dev/mapping"
echo 7 > "\$dev/brightness"
EOF
    chmod 755 "$MAP_HELPER"

    cat > "$MAP_UNIT" <<EOF
[Unit]
Description=Front-panel LED segment map

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$MAP_HELPER
EOF

    # Pulled the same way the tm16xx-display package pulls its own service. Declaring
    # Wants=/After= on sys-devices-platform-tm1628.device instead makes systemd "expect" that
    # device before udev delivers the uevent, and the vendor's SYSTEMD_WANTS then never fires —
    # which silently leaves tm16xx-display.service dead.
    cat > "$MAP_RULE" <<EOF
ACTION=="add", SUBSYSTEM=="platform", DRIVER=="tm16xx", TAG+="systemd", ENV{SYSTEMD_WANTS}+="front-panel-led-map.service"
EOF

    systemctl daemon-reload
    udevadm control --reload 2>/dev/null || true
    echo "    $MAP_UNIT"
    echo "    $MAP_RULE"
}

install_kernel_hook() {
    install -m 755 "$(readlink -f "$0")" "$SELF_INSTALLED"
    cat > "$KERNEL_HOOK" <<EOF
#!/bin/bash
# Re-apply the front-panel device-tree patch to a freshly installed kernel: every linux-image
# package ships its own /boot/dtb-<version>/ tree, which arrives unpatched.
set -e
[ -x "$SELF_INSTALLED" ] || exit 0
box=\$(sed -n 's/^box=//p' /boot/boot.config 2>/dev/null | tail -1)
img=\$(sed -n 's/^dtb_img=//p' "/boot/box-config/box-\${box}.config" 2>/dev/null | tail -1)
[ -n "\$img" ] || exit 0
dtb="/boot/\${img//\\\$\\{release\\}/\$1}"
[ -f "\$dtb" ] || exit 0
DTB="\$dtb" "$SELF_INSTALLED" --dtb-only
EOF
    chmod 755 "$KERNEL_HOOK"
    echo "    $KERNEL_HOOK"
}

# ---------------------------------------------------------------- main

MODE=install
case "${1:-}" in
    --test)     MODE=test ;;
    --revert)   MODE=revert ;;
    --dtb-only) MODE=dtb ;;
    "")         ;;
    *)          die "unknown option '$1' (use --test, --revert or --dtb-only)" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo $0 ${1:-})"

case "$MODE" in
    test)   live_test; exit 0 ;;
    revert) revert; exit 0 ;;
esac

command -v fdtput >/dev/null || die "fdtput missing — sudo apt install device-tree-compiler"

DTB="${DTB:-$(find_dtb || true)}"
[ -n "$DTB" ] && [ -f "$DTB" ] || die "could not locate the active DTB — set DTB=/path/to.dtb"

echo "==> Patching the device tree"
echo "    dtb:    $DTB"
patch_dtb "$DTB"

# The kernel hook only needs the DTB step; everything below is already in place at that point.
if [ "$MODE" = dtb ]; then
    sync
    exit 0
fi

RUNNING="$(uname -r)"
BOOT_REL="$(sed -n 's/^release=//p' /boot/boot.config 2>/dev/null | tail -1)"
if [ -n "$BOOT_REL" ] && [ "$BOOT_REL" != "$RUNNING" ]; then
    echo "    NOTE: running kernel is '$RUNNING' but u-boot boots '$BOOT_REL' — patched the latter."
fi

echo "==> Installing the segment map service"
install_map_service

echo "==> Installing the kernel-update hook"
install_kernel_hook

# An older revision of this script edited display_service.sh directly; undo that so the package
# file goes back to stock and the map service is the only thing setting the map.
SVC=/usr/lib/tm16xx-display/display_service.sh
for bak in "$SVC.pre-vfd" "$SVC.bak-x96x4"; do
    if [ -f "$bak" ]; then
        cp "$bak" "$SVC"
        echo "==> Reverted the old in-file patch to $SVC (from $(basename "$bak"))"
        break
    fi
done

sync
echo
echo "Done. Reboot to load the patched device tree:"
echo "    sudo reboot"
echo "Then verify with:"
echo "    sudo $0 --test"
