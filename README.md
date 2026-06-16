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
   dpkg -i linux-headers-6.12.30-meson64_20250522_arm64.deb
   sudo apt install build-essential
   ```

---

## 3. Build the driver

### 3a. Native build (on the target ARM64 board)

```bash
cd project_w1
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

## 4. Load the modules

```bash
# Load SDIO bus driver first, then the WiFi driver
sudo insmod vmac/aml_sdio.ko
sudo insmod vmac/vlsicomm.ko
```

To verify the modules loaded:
```bash
lsmod | grep -E 'aml_sdio|vlsicomm'
dmesg | tail -30
```

---

## 5. Connect to WiFi

### 5a. Bring up the interface

```bash
ip link set wlan0 up
```

### 5b. Scan available networks

```bash
iw dev wlan0 scan | grep -E 'SSID|signal|freq'
```

### 5c. Create wpa_supplicant config

> **Important:** `country=` must be set to your actual country code. Without it, the kernel
> uses world regulatory domain (`00`) which restricts many 5 GHz channels and causes AUTH
> timeout on DFS channels (e.g. ch100 / 5500 MHz).
> Replace `VN` with your country code (e.g. `US`, `DE`, `JP`, etc.)

```bash
# Set regulatory domain first (required for 5 GHz DFS channels)
iw reg set VN

printf 'ctrl_interface=/var/run/wpa_supplicant\nctrl_interface_group=0\nupdate_config=1\ncountry=VN\n' > /tmp/wpa.conf
wpa_passphrase "YOUR_SSID" "YOUR_PASSWORD" >> /tmp/wpa.conf
```

### 5d. Start wpa_supplicant and connect

```bash
wpa_supplicant -B -i wlan0 -c /tmp/wpa.conf
sleep 5
wpa_cli -i wlan0 status
```

Expected output when connected:
```
wpa_state=COMPLETED
ip_address=192.168.x.x
```

### 5e. Get IP address

```bash
dhclient wlan0
```

---

### Install permanently (survive reboot)

**1. Install the kernel modules:**

```bash
sudo cp vmac/aml_sdio.ko vmac/vlsicomm.ko \
  /lib/modules/$(uname -r)/kernel/drivers/net/wireless/
sudo depmod -a
```

**2. Save wpa_supplicant config to a permanent location:**

```bash
cp /tmp/wpa.conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

**3. Enable wpa_supplicant service on boot:**

```bash
systemctl enable wpa_supplicant@wlan0
systemctl start wpa_supplicant@wlan0
```

**4. Enable DHCP on wlan0 at boot** — create `/etc/network/interfaces.d/wlan0`:

```bash
printf 'auto wlan0\niface wlan0 inet dhcp\n' > /etc/network/interfaces.d/wlan0
```

> **Note on kernel updates:** If you update the kernel (e.g. `dpkg -i linux-image-*.deb`),
> the manually installed `.ko` files will no longer match and WiFi will stop working after reboot.
> You must rebuild and reinstall the modules against the new kernel version.
> This will **not** brick the device — it will just boot without WiFi.

---

### Troubleshooting

**`Failed to connect to non-global ctrl_ifname`**

`wpa_supplicant` was started without `ctrl_interface`. Recreate the config with `ctrl_interface` as shown in step 5c.

**`wpa_state=ASSOCIATING` stuck / AUTH timeout**

```
wifi_mac_mgmt_tx_timeout vm_state AUTH
```

Cause: missing `country=` in config, or DFS channel restrictions.
Fix: add `country=VN` (or your country code) to the config file.

**`nl80211: kernel reports: Match already configured`**

A previous `wpa_supplicant` process is still running. Kill it first:
```bash
pkill wpa_supplicant
sleep 1
# then re-run wpa_supplicant
```

**`ip link set wlan0 up` fails / wlan0 not visible**

Modules not loaded yet. Run step 4 first.

---

## 6. MAC address

On non-Amlogic platforms the driver reads the MAC from the chip's EFUSE registers.
If EFUSE is blank (all zeros), a randomly-generated MAC is assigned.

To set a persistent MAC address, write it to `/data/vendor/wifi/wifimac.txt`
(or adjust `WIFIMAC_PATH` in the Makefile):

```bash
echo "aa:bb:cc:dd:ee:ff" > /data/vendor/wifi/wifimac.txt
```

---

## Notes — differences from the original Amlogic BSP build

When building without `PROJ_NAME` set (default path), the Makefile automatically:

- Sets `KERNELDIR = /lib/modules/$(uname -r)/build`
- Defines `-DNOT_AMLOGIC_PLATFORM` which:
  - Removes dependency on `<linux/amlogic/wlan_plat.h>` and `<linux/amlogic/aml_gpio_consumer.h>`
  - Stubs out `sdio_reinit()`, `amlwifi_set_sdio_host_clk()`, `set_usb_bt_power()`, `set_usb_wifi_power()`
  - Disables `CONFIG_MAC_SUPPORT` (driver falls back to EFUSE or random MAC)
- Disables `-Werror` to allow building against kernel 6.x headers without treating warnings as errors
- Replaces removed `prandom_bytes()` with `get_random_bytes()` (API removed in kernel 6.11)
