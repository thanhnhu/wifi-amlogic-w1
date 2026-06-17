# Amlogic W155S1 WiFi Driver (aml_w1 / 0x8888)

Out-of-tree Linux kernel module for the Amlogic W155S1 (chip ID `0x8888`) WiFi SDIO card.

## Compatibility

| Kernel | Status |
|--------|--------|
| 4.14 – 5.15 | Original target (Amlogic Android/BSP kernels) |
| 5.15+ | Supported (VFS import namespace added) |
| 6.x — mainline | Supported |
| 6.x — [devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic) (`*-meson64`) | **Tested OK** — kernel 6.12.30-meson64, 2.4 GHz + 5 GHz DFS connected |

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
and loads them immediately — i.e. it does [section 4](#4-install-and-connect-survive-reboot) steps 1
and 2 for you. Next, continue from **section 4, step 3** to set up WiFi auto-connect.

> The `.ko` files only load on the **exact** kernel they were built for. If there is no release
> for your `uname -r`, build from source below. Releases are produced automatically by the
> [Build and Release workflow](.github/workflows/build-release.yml) when a `v*` tag is pushed
> (or [trigger a build manually](#build-a-release-manually-github-actions)).

---

## 1. Get the source

```bash
git clone https://github.com/thanhnhu/wifi-amlogic-w1.git
cd wifi-amlogic-w1
```

---

## 2. Install kernel headers

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
   matching your kernel version (e.g. `v6.12.30`).

2. Download and install the headers `.deb`:
   ```bash
   # Replace the filename with the one from the matching release
   wget https://github.com/devmfc/debian-on-amlogic/releases/download/v6.12.30/linux-headers-6.12.30-meson64_20250522_arm64.deb
   sudo dpkg -i linux-headers-6.12.30-meson64_20250522_arm64.deb
   sudo apt install build-essential
   ```

---

## 3. Build the driver

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

## 4. Install and connect (survive reboot)

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
iw dev wlan0 scan | grep -E 'SSID|freq'
```

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
> - No CAC wait → the chip associates to 5 GHz **immediately at boot**, so the 5 GHz watchdog in
>   step 6 below becomes unnecessary (you can skip it).
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
> **Note on 5 GHz DFS after reboot:** DFS channels (e.g. ch100 / 5500 MHz) require a ~60 s Channel
> Availability Check (CAC) before the radio can be used, so the chip cannot associate to 5 GHz
> immediately at boot. The permanent setup below brings up 2.4 GHz first, then upgrades to 5 GHz
> after CAC — or use the non-DFS router channel above to skip the wait entirely.

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

**6. (Optional) 5 GHz DFS auto-upgrade watchdog:**

> **Skip this step if you used the non-DFS router channel option in step 3** — with a non-DFS
> channel the chip connects to 5 GHz immediately and no watchdog is needed.

At boot the chip's TX path needs a moment to calibrate and the 5 GHz DFS channel needs ~60 s of
CAC, so `wpa_supplicant` may first land on 2.4 GHz (or temporarily disable both SSIDs after a few
failed associations and sit in `SCANNING`). This watchdog gets you online immediately, then
upgrades to 5 GHz once CAC completes. Skip it if your router uses a non-DFS 5 GHz channel.

```bash
cat > /usr/local/sbin/wlan0-watchdog.sh <<'EOF'
#!/bin/sh
I=wlan0
W="/sbin/wpa_cli -i $I"
# Phase 1: get any connection (wpa prefers 5 GHz via priority=10).
# enable_network all clears wpa's temporary SSID block after early association failures.
n=0
while [ $n -lt 30 ]; do
  $W status 2>/dev/null | grep -q wpa_state=COMPLETED && break
  $W enable_network all >/dev/null 2>&1
  $W reassociate >/dev/null 2>&1
  n=$((n+1)); sleep 5
done
$W status 2>/dev/null | grep -q wpa_state=COMPLETED || exit 0
# Already on 5 GHz? done.
f=$($W status 2>/dev/null | grep ^freq= | cut -d= -f2)
case "$f" in 5*) exit 0;; esac
# On 2.4 GHz: wait for DFS CAC, then try to move to 5 GHz up to 3 times.
sleep 60
m=0
while [ $m -lt 3 ]; do
  $W enable_network all >/dev/null 2>&1
  $W reassociate >/dev/null 2>&1
  sleep 15
  f=$($W status 2>/dev/null | grep ^freq= | cut -d= -f2)
  case "$f" in 5*) exit 0;; esac
  $W status 2>/dev/null | grep -q wpa_state=COMPLETED || $W reconnect >/dev/null 2>&1
  m=$((m+1))
done
# Could not reach 5 GHz: keep 2.4 GHz, just make sure we are still connected.
$W status 2>/dev/null | grep -q wpa_state=COMPLETED || { $W enable_network all >/dev/null 2>&1; $W reconnect >/dev/null 2>&1; }
exit 0
EOF
chmod +x /usr/local/sbin/wlan0-watchdog.sh

# Launch the watchdog in the background after wpa_supplicant@wlan0 starts (never blocks boot)
mkdir -p /etc/systemd/system/wpa_supplicant@wlan0.service.d
cat > /etc/systemd/system/wpa_supplicant@wlan0.service.d/wait-driver.conf <<'EOF'
[Service]
ExecStartPost=/bin/sh -c "/usr/local/sbin/wlan0-watchdog.sh &"
EOF
systemctl daemon-reload
```

**7. Reboot and check:**

```bash
reboot
# after ~90 s (chip init + CAC), check:
systemctl status wpa_supplicant@wlan0.service --no-pager
wpa_cli -i wlan0 status | grep -E 'wpa_state=|^freq=|^ssid='
ip addr show wlan0
```

> Expected: `wpa_state=COMPLETED`, an `inet 192.168.x.x` address, and `freq=5500` (5 GHz) once CAC
> finishes — or `freq=2417` (2.4 GHz) if the DFS channel wasn't ready within the watchdog's window.

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

**`nl80211: kernel reports: Match already configured`**

A stale `wpa_supplicant` process is still holding wlan0. Restart the service to clear it:
```bash
sudo pkill wpa_supplicant
sudo systemctl restart wpa_supplicant@wlan0.service
```

**`ip link set wlan0 up` fails / wlan0 not visible**

Modules not loaded yet. Run step 2 first.

**`country 00` stuck after reboot / `loaded regulatory.db is malformed or signature is missing/invalid`**

The kernel is verifying the regulatory db against a key it doesn't have. Switch to the **upstream**
db (see section 4, step 3): `update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream`
and relink `regulatory.db.p7s-upstream`, then reboot. Confirm with `dmesg | grep cfg80211`.

**Network drops entirely after reboot / `wpa_state=SCANNING`, `CTRL-EVENT-SSID-TEMP-DISABLED`**

Two causes seen on this platform:
1. Two network managers (`ifupdown` **and** `systemd-networkd`) both controlling wlan0 \u2014 they fight
   and the result differs every boot. Use only one (see section 4, step 5; remove
   `/etc/network/interfaces.d/wlan0`).
2. `wpa_supplicant` started before the chip's TX path finished calibrating, failed to associate a few
   times, and temporarily disabled all SSIDs. Recover manually, or use the watchdog in step 6:
   ```bash
   systemctl restart wpa_supplicant@wlan0.service
   sleep 10
   wpa_cli -i wlan0 status
   ```

---

## 5. MAC address

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

## Notes — differences from the original Amlogic BSP build

When building without `PROJ_NAME` set (default path), the Makefile automatically:

- Sets `KERNELDIR = /lib/modules/$(uname -r)/build`
- Defines `-DNOT_AMLOGIC_PLATFORM` which:
  - Removes dependency on `<linux/amlogic/wlan_plat.h>` and `<linux/amlogic/aml_gpio_consumer.h>`
  - Stubs out `sdio_reinit()`, `amlwifi_set_sdio_host_clk()`, `set_usb_bt_power()`, `set_usb_wifi_power()`
  - Keeps `CONFIG_MAC_SUPPORT` enabled (driver can use `WIFIMAC_PATH`; fallback remains EFUSE/random if file/EFUSE is unavailable)
- Disables `-Werror` to allow building against kernel 6.x headers without treating warnings as errors
- Replaces removed `prandom_bytes()` with `get_random_bytes()` (API removed in kernel 6.11)

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
