# Amlogic W155S1 WiFi Driver (aml_w1 / 0x8888)

Out-of-tree Linux kernel module for the Amlogic W155S1 (chip ID `0x8888`) WiFi SDIO card.

> **Bluetooth too?** The W155S1 is a combo chip — its BT core is driven by the companion repo
> [aml_bt](https://github.com/thanhnhu/aml_bt), which builds on top of this driver.
> See [section VII](#vii-bluetooth-optional).
>
> **Front panel dark?** Unrelated to WiFi, but same box: see
> [Bonus — front-panel LED display](#bonus--front-panel-led-display-magicsee-n5-max-x4).

## Compatibility

### Kernels

| Kernel | Status |
|--------|--------|
| 4.14 – 5.15 | Original target (Amlogic Android/BSP kernels) |
| 5.15+ | Supported (VFS import namespace added) |
| 6.x — mainline | Supported |
| 6.13 – 6.18 | Supported (ccflags-y, cfg80211/timer/hrtimer/crypto API updates, version-guarded) |
| 6.x — [devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic) (`*-meson64`) | **Tested OK** — kernels 6.12.30-meson64 and 6.18.40-meson64, 2.4 GHz + 5 GHz DFS connected |

### Devices (TV boxes)

Any Amlogic TV box whose WiFi module is the **W155S1 / W155S2 (chip ID `0x8888`)** on the SDIO bus,
for example:

| TV box | SoC | Status |
|--------|-----|--------|
| Magicsee N5 Max X4 | S905X4 | **Tested OK** — 2.4 GHz + 5 GHz |
| X96 Max+ / X96 Max Plus (X4 variants) | S905X4 | Expected to work (same W155S1 SDIO module) |
| Other S905X4 / S905X2 / S922X boxes | S905X4, S905X2, S922X | Expected to work if the WiFi chip ID is `0x8888` |

**Check your device before building** — the driver only matches chip ID `0x8888`:

```bash
# Vendor/device of the SDIO WiFi card
cat /sys/bus/sdio/devices/*/{vendor,device} 2>/dev/null
# After loading the module, the chip ID is printed in the kernel log
dmesg | grep -i -E 'aml_|w155|8888'
```

---

## Quick install (prebuilt release)

If a [release](../../releases) exists for **your exact kernel version** (`uname -r`), you can skip
building and just install the prebuilt modules:

```bash
# Download the tarball matching your kernel from the Releases page, then:
tar xzf aml-w1-<kernel-version>.tar.gz
cd aml-w1-<kernel-version>
sudo ./install.sh
```

`install.sh` copies the modules, runs `depmod`, adds them to `/etc/modules` (auto-load on boot),
and loads them immediately — i.e. it does [section IV](#iv-install-and-connect-survive-reboot) steps 1
and 2 for you. Next, continue from **section IV, step 3** to set up WiFi auto-connect.

> The `.ko` files only load on the **exact** kernel they were built for. If there is no release
> for your `uname -r`, build from source below. Releases are produced automatically by the
> [Build and Release workflow](.github/workflows/build-release.yml) when a `v*` tag is pushed
> (or [trigger a build manually](#build-a-release-manually-github-actions)).

---

## I. Get the source

```bash
git clone https://github.com/thanhnhu/wifi-amlogic-w1.git
cd wifi-amlogic-w1
```

---

## II. Install kernel headers

First, check your kernel version:

```bash
uname -r
```

| Output | Use |
|--------|-----|
| `6.x.x` (no suffix, standard mainline) | **2a** |
| `6.x.x-meson64` (devmfc/debian-on-amlogic) | **2b** |

### 2a. Mainline kernel (standard `linux-headers` package available)

```bash
sudo apt install linux-headers-$(uname -r) build-essential
```

### 2b. devmfc/debian-on-amlogic (meson64 kernel)

The `linux-headers-$(uname -r)` package is **not** in the standard apt repo.
Headers are distributed as `.deb` files in the
[GitHub releases](https://github.com/devmfc/debian-on-amlogic/releases).

**Steps:**

1. Go to https://github.com/devmfc/debian-on-amlogic/releases and find the release
   matching your kernel version (e.g. `v6.12.30` or `v6.18.40`).

2. Download and install the headers `.deb`:
   ```bash
   # Replace the filename with the one from the matching release
   wget https://github.com/devmfc/debian-on-amlogic/releases/download/v6.18.40/linux-headers-6.18.40-meson64_20260726_arm64.deb
   sudo dpkg -i linux-headers-6.18.40-meson64_20260726_arm64.deb
   sudo apt install build-essential
   ```

---

## III. Build the driver

### 3a. Native build (on the target ARM64 board)

```bash
cd project_w1
make clean
make -j4 driver
# Output modules: vmac/vlsicomm.ko  vmac/aml_sdio.ko
```

### 3b. Cross-compilation (ARM64 target, x86 host)

1. Install the cross-compiler toolchain on the host:
   ```bash
   sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
   ```

2. Build:
   ```bash
   cd project_w1
   make -j4 driver \
     ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- \
     KERNELDIR=/path/to/arm64/kernel/build
   ```

> **Tip:** Build-time dependencies (headers, gcc, etc.) can be removed after building:
> ```bash
> sudo apt remove linux-headers-$(uname -r) build-essential \
>   gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
> sudo apt autoremove
> ```

---

## IV. Install and connect (survive reboot)

**1. Install the kernel modules:**

```bash
sudo cp vmac/aml_sdio.ko vmac/vlsicomm.ko \
  /lib/modules/$(uname -r)/kernel/drivers/net/wireless/
sudo depmod -a
```

**2. Auto-load modules on boot (and load them now):**

```bash
# Register the modules for automatic load on every boot
printf 'aml_sdio\nvlsicomm\n' >> /etc/modules

# Load them now so you can finish the rest without rebooting
sudo depmod -a
sudo modprobe aml_sdio
sudo modprobe vlsicomm

# Bring up the interface and find your SSID names for the config below
sudo ip link set wlan0 up
sudo timeout 15 iw dev wlan0 scan | grep -E 'SSID|freq'
```

> **`iw dev wlan0 scan` hangs?** This command only works while **no one else owns wlan0**. If you
> already set up `wpa_supplicant@wlan0` (steps 4–5), it is holding the interface and the chip will
> not run a second, parallel scan — `iw scan` then blocks forever (hence the `timeout 15` wrapper
> above, which makes it give up instead of hanging). Ask the running `wpa_supplicant` to scan
> instead:
> ```bash
> wpa_cli -i wlan0 scan && sleep 3 && wpa_cli -i wlan0 scan_results
> ```

**3. Set regulatory domain on boot** (required for 5 GHz DFS channels):

> **Easiest option — change the router channel instead of fighting DFS:**
>
> If you control the router, the simplest path is to move its 5 GHz radio off the DFS band so the
> chip never has to wait for a Channel Availability Check (CAC). Set the router's 5 GHz channel to a
> **non-DFS** channel — **36, 40, 44, or 48** (5180–5240 MHz) — in its admin panel (usually
> *Wireless → 5 GHz → Channel*, change from *Auto*/a DFS channel like 100/5500 to a fixed 36–48).
>
> Benefits:
>
> - No DFS TX block → the chip associates to 5 GHz **immediately at boot**, so the 5 GHz warm-up
>   service in step 6 below becomes unnecessary (you can skip it).
> - More stable: DFS channels can force the AP off-air for radar avoidance; non-DFS channels don't.
>
> You should still set the correct country/regulatory domain below so the non-DFS channels are
> permitted at full power — but you avoid the DFS-specific timing problems entirely.

On **devmfc/debian-on-amlogic** kernels, `cfg80211` is a **loadable module** that verifies the
regulatory database against compiled-in X.509 keys at load time. The kernel ships only the
`sforshee` (upstream) and `wens` keys — it has **no Debian key**. So you must use the **upstream**
regulatory db, not the Debian one, otherwise the kernel logs
`loaded regulatory.db is malformed or signature is missing/invalid` and stays at `country 00`.

```bash
# Use the UPSTREAM regulatory db (matches the kernel's compiled-in sforshee key)
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
ln -sf /lib/firmware/regulatory.db.p7s-upstream /etc/alternatives/regulatory.db.p7s

# Set the country at boot via the kernel cmdline (devmfc/debian-on-amlogic only).
# Replace 6.x.y with your kernel version (e.g. kernel-6.12.30.config)
echo 'bootargs8=cfg80211.ieee80211_regdom=VN' >> /boot/box-config/kernel-6.x.y.config
```

> Replace `VN` with your country code (e.g. `US`, `DE`, `JP`).
>
> **Verify after reboot:** `iw reg get | grep country` should show `country VN: DFS-FCC` (not `country 00`).
> Check `dmesg | grep cfg80211` for signature errors if it stays at `00`.
>
> **Note on 5 GHz DFS after reboot:** after a cold boot the W1 firmware does **not transmit on a DFS
> channel** (e.g. ch52 / 5260 MHz, ch100 / 5500 MHz) until the chip has completed one connection on
> 2.4 GHz. The AP is found by the scan, but every AUTH frame is dropped without being sent (TX status
> `4` = `AGED`), and this can last many minutes — waiting for CAC alone does not fix it. Step 6 below
> works around it automatically; the non-DFS router channel above avoids it entirely.

**4. Create the per-interface wpa_supplicant config** `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`:

The `wpa_supplicant@wlan0` systemd service (used below) reads this exact filename. Include
`country=VN` and one `network` block per band. Use `priority=` so the higher value (5 GHz here)
is preferred and 2.4 GHz is the fallback.

```bash
cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=VN

network={
    ssid="YOUR_5G_SSID"
    psk="YOUR_PASSWORD"
    priority=10
}

network={
    ssid="YOUR_24G_SSID"
    psk="YOUR_PASSWORD"
    priority=5
}
EOF
chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

**5. Use ONE network stack — systemd-networkd + `wpa_supplicant@wlan0`:**

This image (devmfc/debian-on-amlogic) already uses **systemd-networkd** for DHCP
(`/etc/systemd/network/20-wlan0.network`). Let it keep doing DHCP, and let the
per-interface `wpa_supplicant@wlan0.service` do the association. The `@wlan0` template binds to
`wlan0.device`, so it starts only once the driver has created the interface — no boot-timing race.

> **Important — do not run two managers.** `ifupdown` and `systemd-networkd` will fight over
> wlan0 (each reboot connects differently or drops entirely). If you previously added an
> `ifupdown` stanza, remove it:
> ```bash
> rm -f /etc/network/interfaces.d/wlan0
> ```

```bash
# Associate with wpa_supplicant@wlan0 (reads wpa_supplicant-wlan0.conf), let networkd do DHCP
systemctl enable wpa_supplicant@wlan0.service
systemctl disable wpa_supplicant 2>/dev/null   # avoid a second, global instance
```

**6. (Optional) 5 GHz DFS warm-up at boot:**

> **Skip this step if you used the non-DFS router channel option in step 3** — with a non-DFS
> channel the chip connects to 5 GHz immediately.

After a cold boot the firmware will not transmit on a DFS channel until it has completed one
connection on 2.4 GHz (see the note in step 3). `wpa_supplicant` alone therefore loops on
`CTRL-EVENT-DISCONNECTED reason=0` / `SSID-TEMP-DISABLED` for a long time. The one-shot
`wlan-5g-warmup` service fixes this: each time `wpa_supplicant@wlan0` starts it connects to the
2.4 GHz SSID for a few seconds, then selects the 5 GHz SSID, which then associates at once. It runs
once and exits — no background loop — and never rewrites the wpa_supplicant config.

```bash
sudo install -m 755 scripts/wlan-5g-warmup.sh /usr/local/sbin/wlan-5g-warmup.sh
sudo install -m 644 scripts/wlan-5g-warmup.service /etc/systemd/system/wlan-5g-warmup.service
sudo install -m 644 scripts/wlan-5g-warmup.default /etc/default/wlan-5g-warmup
sudo nano /etc/default/wlan-5g-warmup      # set SSID_24, SSID_5 (and KEEP_24G)
sudo systemctl daemon-reload
sudo systemctl enable wlan-5g-warmup.service
```

`KEEP_24G` chooses what happens to 2.4 GHz afterwards:

| `KEEP_24G` | After reaching 5 GHz | Use when |
|---|---|---|
| `0` (default) | 2.4 GHz stays disabled; used only for the warm-up | Bluetooth is in use (e.g. Home Assistant BLE scanning) — the shared radio makes 2.4 GHz WiFi drop most of its TX frames. Also set `disabled=1` on the 2.4 GHz block in `wpa_supplicant-wlan0.conf` |
| `1` | 2.4 GHz re-enabled as a fallback (lower `priority`) | No heavy Bluetooth use |

For a 5 GHz-only setup also add `autoscan=periodic:5` to `wpa_supplicant-wlan0.conf`, so
`wpa_supplicant` rescans every 5 s while disconnected.

> Replaces the older `wlan0-watchdog.sh` from previous versions of this README, which waited for
> CAC and could not get past the DFS TX block. If you installed it, remove it:
> `sudo rm -f /etc/systemd/system/wpa_supplicant@wlan0.service.d/wait-driver.conf /usr/local/sbin/wlan0-watchdog.sh && sudo systemctl daemon-reload`

**7. Reboot and check:**

```bash
reboot
# after ~60 s, check:
journalctl -b -t wlan-5g-warmup          # attempt 1: warming up ... / connected to ... (freq 5260)
wpa_cli -i wlan0 status | grep -E 'wpa_state=|^freq=|^ssid='
ip addr show wlan0
```

> Expected: `wpa_state=COMPLETED`, an `inet 192.168.x.x` address and `freq=5xxx`. Tested on a
> Magicsee N5 Max X4 (6.18.40-meson64) with the AP on DFS ch52: 5 GHz up ~35 s after boot, on the
> first attempt.

> **Note on kernel updates:** If you update the kernel (e.g. `dpkg -i linux-image-*.deb`),
> the manually installed `.ko` files will no longer match and WiFi will stop working after reboot.
> You must rebuild and reinstall the modules against the new kernel version.
> This will **not** brick the device — it will just boot without WiFi.

---

### Troubleshooting

**`Failed to connect to non-global ctrl_ifname`**

`wpa_supplicant` was started without `ctrl_interface`. Recreate the config with `ctrl_interface` as shown in step 4.

**`wpa_state=ASSOCIATING` stuck / AUTH timeout**

```
wifi_mac_mgmt_tx_timeout vm_state AUTH
```

Cause: missing `country=` in config, or DFS channel restrictions.
Fix: add `country=VN` (or your country code) to the config file.

If `country=` is already set and the AP is on a DFS channel, check the TX status of the AUTH frames:
```bash
dmesg | grep drv_tx_complete_mgmt_handle | tail
# drv_tx_complete_mgmt_handle, txdesc_frame_flag:7, status=4, rate:04
```
`status=4` (`TX_DESCRIPTOR_STATUS_AGED`) means the firmware never sent the frame — the cold-boot DFS
TX block described in step 3. Use the warm-up service in step 6, or move the AP to channel 36–48.

**`nl80211: kernel reports: Match already configured`**

A stale `wpa_supplicant` process is still holding wlan0. Restart the service to clear it:
```bash
sudo pkill wpa_supplicant
sudo systemctl restart wpa_supplicant@wlan0.service
```

**`ip link set wlan0 up` fails / wlan0 not visible**

Modules not loaded yet. Run step 2 first.

**`iw dev wlan0 scan` hangs forever**

`wpa_supplicant` (or NetworkManager) is already holding wlan0, and the chip won't run a second,
parallel scan. This is expected once steps 4–5 are done — it does **not** mean a conflict. Use the
running supplicant to scan instead:
```bash
wpa_cli -i wlan0 scan && sleep 3 && wpa_cli -i wlan0 scan_results
```
To force `iw` to work, stop the holder first (`sudo systemctl stop wpa_supplicant@wlan0.service`),
or just wrap it: `sudo timeout 15 iw dev wlan0 scan`.

**`country 00` stuck after reboot / `loaded regulatory.db is malformed or signature is missing/invalid`**

The kernel is verifying the regulatory db against a key it doesn't have. Switch to the **upstream**
db (see section IV, step 3): `update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream`
and relink `regulatory.db.p7s-upstream`, then reboot. Confirm with `dmesg | grep cfg80211`.

**Network drops entirely after reboot / `wpa_state=SCANNING`, `CTRL-EVENT-SSID-TEMP-DISABLED`**

Two causes seen on this platform:
1. Two network managers (`ifupdown` **and** `systemd-networkd`) both controlling wlan0 \u2014 they fight
   and the result differs every boot. Use only one (see section IV, step 5; remove
   `/etc/network/interfaces.d/wlan0`).
2. The AP is on a DFS 5 GHz channel and the firmware is still blocking TX after a cold boot, so
   `wpa_supplicant` failed a few times and temporarily disabled the SSID. Use the warm-up service in
   step 6, or recover manually:
   ```bash
   systemctl restart wpa_supplicant@wlan0.service
   sleep 10
   wpa_cli -i wlan0 status
   ```

---

## V. Prefer WiFi 5 GHz over wired LAN (optional)

Many of these TV boxes have a **100 Mbps Fast Ethernet** port (not Gigabit), so a good 5 GHz WiFi
link is actually **faster** than the cable. But when both `eth0` and `wlan0` are up, the kernel
sends all internet traffic over whichever default route has the **lower metric** — and `eth0`
usually wins by default. To prefer 5 GHz WiFi, give `wlan0` a **lower** route metric than `eth0`.

**1. See the current default routes and their metrics:**

```bash
ip route | grep default
# e.g.  default via 192.168.1.1 dev eth0  metric 100
#       default via 192.168.1.1 dev wlan0 metric 600   ← higher = lower priority
```

**2. Find the `.network` file managing `eth0`:**

```bash
networkctl status eth0 | grep -i 'Network File'
ls -l /etc/systemd/network/
```

**3. Set the metrics** (WiFi lower than LAN). Edit the section in each file, or append with bash
(run `bash` first if your shell is fish):

```bash
# WiFi = high priority (low metric)
cat >> /etc/systemd/network/20-wlan0.network <<'EOF'

[DHCPv4]
RouteMetric=100
EOF

# LAN = low priority (high metric) — replace 10-eth0.network with the file from step 2
cat >> /etc/systemd/network/10-eth0.network <<'EOF'

[DHCPv4]
RouteMetric=600
EOF
```

> If a file already has a `[DHCPv4]` section, don't add a second one — just put the
> `RouteMetric=` line inside the existing section (edit with `nano`).

**4. Apply and verify:**

```bash
systemctl restart systemd-networkd
sleep 3
ip route | grep default          # wlan0 should now have the lower metric
ip route get 8.8.8.8             # should say "dev wlan0"
```

> **Automatic failover stays intact:** keep the LAN cable plugged in. If WiFi drops, its default
> route disappears and the kernel falls back to `eth0` automatically — then returns to WiFi once
> 5 GHz is back. Only lower the LAN priority **after** 5 GHz associates reliably (ideally on a
> non-DFS channel 36–48), otherwise a flaky DFS link will be slower than the cable.

---

## VI. MAC address

On non-Amlogic platforms the driver reads the MAC from the chip's EFUSE registers.
If EFUSE is blank (all zeros), the first boot generates a random MAC and now auto-persists it.

Default `WIFIMAC_PATH`:
- Mainline/Debian fallback build: `/etc/wifimac.txt`
- Amlogic BSP build: `/data/vendor/wifi/wifimac.txt`

To set a specific persistent MAC manually, write it to the active path (or adjust `WIFIMAC_PATH` in the Makefile):

```bash
echo "aa:bb:cc:dd:ee:ff" > /etc/wifimac.txt
```

---

## VII. Bluetooth (optional)

The W155S1 is a **combo chip**: the same die carries a Bluetooth core. It is not handled by this
driver, but it depends on it — the BT core has no power rail of its own and is switched on by
poking the chip's PMU registers **over this driver's SDIO link**. HCI then runs over a separate
UART.

```
aml_sdio.ko ──SDIO──> [ W155S1 : WiFi core | BT core ]
                                              │
sdio_bt.ko  ──SDIO──> PMU power-on            │ UART
                                              ▼
aml_hciattach ──/dev/ttyS7──> firmware download ──> hci0
```

That is what [**thanhnhu/aml_bt**](https://github.com/thanhnhu/aml_bt) provides. It links against
symbols exported here (`g_w1_hif_ops`, `host_wake_w1_req`, `aml_wifi_sdio_power_lock`,
`set_wifi_bt_sdio_driver_bit`, ...), so **install this WiFi driver first** — `sdio_bt.ko` will not
load otherwise.

The two coexist safely: `set_wifi_bt_sdio_driver_bit()` refcounts WiFi and BT, so the shared SDIO
power driver is only torn down once *both* are unloaded.

```bash
# after WiFi works:
git clone -b 6.18.40 https://github.com/thanhnhu/aml_bt.git
cd aml_bt && sudo ./scripts/install-w1-bt.sh && sudo reboot
```

Tested on the same Magicsee N5 Max X4 (S905X4) — BT 5.0, BLE + Classic. Note that it also needs a
small device-tree patch, which its README explains.

---

## Bonus — front-panel LED display (Magicsee N5 Max X4)

Unrelated to WiFi, but the same box, the same class of problem: on devmfc's Debian image the
4-digit front panel stays dark and only the power LED is lit.

**Why:** the image boots `meson-sc2-x96x4.dtb` because it is the closest match for this board, but
that DTB describes the *X96 X4* panel — a **TM1628** on 3 wires (`GPIOA_14` / `GPIOA_15` /
`GPIOD_10`). The Magicsee N5 Max X4 actually carries an **FD6551** driven over **2 wires** on
`GPIOD_6` / `GPIOD_7`, with no strobe line. Wrong chip, wrong pins, wrong protocol — so the
`tm16xx` driver talks to nothing. The power LED you still see is a discrete LED wired straight to
the board, not to the display controller, which is why it survives.

| | DTB as shipped (X96 X4) | Magicsee N5 Max X4 |
|---|---|---|
| controller | `devmfc,tm1628`, 3-wire | **`devmfc,fd6551`, 2-wire** |
| clk | `GPIOA_15` (line 1) | **`GPIOD_6` (line 35)** |
| dat | `GPIOA_14` (line 0) | **`GPIOD_7` (line 36)** |
| stb | `GPIOD_10` (line 39) | *not used* |
| segment map | driver default (TM1628) | **`map6`** (T95 family, from `tm16xx-map.sh`) |

**Fix:**

```bash
sudo ./scripts/enable-front-panel-led.sh
sudo reboot
# after the reboot, confirm the panel renders correctly
sudo ./scripts/enable-front-panel-led.sh --test
```

Three things get installed, and the split is deliberate:

| What | Where | Why not somewhere simpler |
|------|-------|---------------------------|
| device-tree patch | the DTB u-boot actually loads | this image's `boot.scr` has no `fdt apply`, so **overlays are not an option** — the DTB has to be edited in place |
| segment map | `front-panel-led-map.service` + its own udev rule | the obvious spot, `/usr/lib/tm16xx-display/display_service.sh`, belongs to the `tm16xx-display` package and an update would silently revert an in-file patch |
| re-patch on kernel update | `/etc/kernel/postinst.d/zz-front-panel-led` | every `linux-image` package ships its own unpatched `/boot/dtb-<version>/` tree, so without this the panel dies at the next kernel upgrade |

Backups are kept as `*.pre-vfd`; `--revert` restores them and removes the service, rule and hook.

> **Why a map service at all?** The `tm16xx` driver derives its segment map at probe time from a
> built-in TM1628 default and offers no device-tree property to override it, so the correct map has
> to be written to `/sys/.../mapping` from userspace on every boot.

> **Why a udev rule instead of `Wants=`/`After=` on the device unit?** Because pointing a unit at
> `sys-devices-platform-tm1628.device` makes systemd *expect* that device before udev delivers the
> uevent, and the vendor's own `SYSTEMD_WANTS` rule then never fires — leaving
> `tm16xx-display.service` dead. The script uses the same mechanism the vendor does.

**Verified end to end** on kernel 6.18.40-meson64: after a reboot both
`tm16xx-display.service` and `front-panel-led-map.service` come up on their own, and the kernel log
shows the driver auto-detecting the 2-wire bus:

```
tm16xx tm1628: DEVMFC: tm16xx driver v1.97 probe
tm16xx tm1628: Get stb GPIO failed: -2, assuming two wire protocol
```

> `display_service.sh` logs two harmless `tm16xx::power: No such file or directory` lines per boot —
> this panel has no POWER icon, and the file is left untouched on purpose (see the table above).

> **Different box?** The pin numbers come from the stock Android openvfd config for this model
> ([magicsee-n5-max-x4-vfd.conf](https://github.com/arthur-liberman/vfd-configurations/blob/master/magicsee-n5-max-x4-vfd.conf)),
> where `vfd_gpio_clk='0,35,0'` and `vfd_gpio_dat='0,36,0'` index into
> `dt-bindings/gpio/meson-sc2-gpio.h`. Find the `*-vfd.conf` for your box in that repo and override
> the defaults:
> ```bash
> sudo VFD_COMPATIBLE=devmfc,tm1650 VFD_CLK=31 VFD_DAT=30 ./scripts/enable-front-panel-led.sh
> ```
> The driver understands `devmfc,tm1628` (3-wire), `devmfc,fd6551` and `devmfc,tm1650` (2-wire).
> If the panel lights up but the segments are scrambled, pick a different `map1`..`map6` from
> `/usr/lib/tm16xx-display/tm16xx-map.sh` and pass it as `VFD_MAP`.

> **Do not run `systemctl stop tm16xx-display`.** That unit is declared `DefaultDependencies=no`
> and stopping it reboots the box. Stop the display loop with
> `sudo rm -f /run/tm16xx.run` instead (the script does this for you).

---

## Notes — differences from the original Amlogic BSP build

When building without `PROJ_NAME` set (default path), the Makefile automatically:

- Sets `KERNELDIR = /lib/modules/$(uname -r)/build`
- Defines `-DNOT_AMLOGIC_PLATFORM` which:
  - Removes dependency on `<linux/amlogic/wlan_plat.h>` and `<linux/amlogic/aml_gpio_consumer.h>`
  - Stubs out `sdio_reinit()`, `amlwifi_set_sdio_host_clk()`, `set_usb_bt_power()`, `set_usb_wifi_power()`
  - Keeps `CONFIG_MAC_SUPPORT` enabled (driver can use `WIFIMAC_PATH`; fallback remains EFUSE/random if file/EFUSE is unavailable)
- Disables `-Werror` to allow building against kernel 6.x headers without treating warnings as errors
- Replaces removed `prandom_bytes()` with `get_random_bytes()` (API removed in kernel 6.11)

### Module parameter `dfs_dwell_ms`

Passive dwell time per DFS channel during a scan, in ms (clamped to 100–500, default **210**). The
vendor driver used a fixed 100 ms — shorter than the standard 102.4 ms beacon interval — so a scan
often missed an AP on a DFS channel. 210 ms covers two beacons; a full scan takes ~1.5 s longer.
This makes the AP *visible* sooner; it does not lift the cold-boot DFS TX block (see section IV,
step 6).

```bash
cat /sys/module/vlsicomm/parameters/dfs_dwell_ms            # current value
echo 250 | sudo tee /sys/module/vlsicomm/parameters/dfs_dwell_ms   # change at runtime
echo 'options vlsicomm dfs_dwell_ms=250' | sudo tee /etc/modprobe.d/vlsicomm.conf  # persist
```

---

## Build a release manually (GitHub Actions)

Releases are built automatically when a `v*` git tag is pushed. To build for a kernel version that
has no release yet, trigger the workflow by hand:

1. Repo → **Actions** tab → **Build and Release** → **Run workflow**.
2. Fill in:
   - **kernel_version** — your target `uname -r` (e.g. `6.12.30-meson64`).
   - **headers_deb_url** — URL of the matching `linux-headers` `.deb` from the
     [devmfc/debian-on-amlogic releases](https://github.com/devmfc/debian-on-amlogic/releases).
   - **release_tag** — leave **empty** to only get a downloadable artifact, or set a tag
     (e.g. `v6.12.30-meson64-1`) to publish a **Release** as well.

Or with the GitHub CLI:

```bash
gh workflow run build-release.yml \
  -f kernel_version=6.12.30-meson64 \
  -f headers_deb_url=https://github.com/devmfc/debian-on-amlogic/releases/download/v6.12.30/linux-headers-6.12.30-meson64_20250522_arm64.deb \
  -f release_tag=v6.12.30-meson64-1   # omit this flag to skip publishing a release
```
