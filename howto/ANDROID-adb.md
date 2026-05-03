# Android on Raspberry Pi 5 — Developer Guide

---

## Section 1: Configure ADB Debugging over WiFi

This section covers how to enable persistent ADB-over-TCP so that `adb connect` works automatically on every boot, without any manual `start adbd` steps.

---

### 1.1 Enable Developer Options on the Device

ADB debugging must be enabled via the Android UI before it can be used.

**Method 1 — Build number tap (standard Android):**

1. Open **Settings → About phone** (or **About device**)
2. Locate **Build number**
3. Tap it **7 times** in quick succession
4. You will see a toast: _"You are now a developer!"_
5. Go back to **Settings → System → Developer options**
6. Enable **USB debugging** (this also gates TCP/IP ADB)

**Method 2 — Bake it into the build (recommended for development images):**

Add the following to your device `.mk` file to ship with Developer Options and ADB pre-enabled, so you never need the UI tap:

```makefile
# device/brcm/rpi/aosp_rpi_car.mk
PRODUCT_SYSTEM_PROPERTIES += \
    ro.debuggable=1 \
    persist.service.adb.enable=1 \
    persist.adb.tcp.port=5555
```

> **Note:** `ro.debuggable=1` is typically already set in `eng` and `userdebug` build variants via `BuildDefaults`. If you are on a `user` build, you must set it explicitly.

---

### 1.2 Configure ADB TCP Port in the Build

In your device Makefile, set the following properties so the TCP port persists across reboots:

```makefile
# device/brcm/rpi/aosp_rpi_car.mk
PRODUCT_SYSTEM_PROPERTIES += \
    persist.adb.tcp.port=5555 \
    persist.service.adb.enable=1
```

**Do not set `service.adb.tcp.port` here.** That is a runtime-only property and has no effect when baked into a system image. `persist.adb.tcp.port` is the correct persistent form.

---

### 1.3 Add TCP Trigger to the Device Init File

The `adbd` daemon is started by USB init triggers by default. For TCP/IP ADB to activate automatically on boot, you must add property-based triggers to your device init file.

Edit `device/brcm/rpi/ramdisk/init.rpi.rc` and add the following blocks:

```rc
# Restart adbd when the TCP port property is set at runtime
on property:persist.adb.tcp.port=5555
    restart adbd

on property:service.adb.tcp.port=5555
    restart adbd

# Re-arm TCP ADB on boot if the port is already persisted.
# This covers the race where persist.adb.tcp.port was set in a prior boot
# and the on property: trigger does not re-fire for an already-set value.
on property:sys.boot_completed=1 && property:persist.adb.tcp.port=5555
    restart adbd
```

> **Android version note:** The `&&` compound property syntax in `on property:` requires **Android 11 or later**. If you are on Android 10 or below, replace the last block with:
>
> ```rc
> on property:sys.boot_completed=1
>     setprop service.adb.tcp.port ${persist.adb.tcp.port}
> ```
>
> This copies the persisted value into the runtime property on every boot, which reliably fires the `service.adb.tcp.port` trigger regardless of `adbd` startup timing.

---

### 1.4 Rebuild and Flash

After making the above source changes, rebuild the affected images:

```bash
# Rebuild vendor image (contains init.rpi.rc via ramdisk)
make vendorimage -j$(nproc)

# Flash to device
fastboot flash vendor vendor.img
fastboot reboot
```

Or pull the SD Card out, and do the following:

```bash
sudo umount /dev/sdc*
sudo dd if=out/target/product/rpi/vendor.img of=/dev/sdc6 bs=1M status=progress conv=fsync
sync
sudo eject /dev/sdc 
```

---

### 1.5 Connect from the Host PC

Once the device has booted, connect from your Ubuntu/Linux PC:

```bash
# Find the device IP address (Settings → About → Status → IP address)
adb connect 192.168.68.55:5555

# Verify
adb devices
```

Expected output:
```
connected to 192.168.68.55:5555
List of devices attached
192.168.68.55:5555    device
```

To disconnect:
```bash
adb disconnect 192.168.68.55:5555
```

---

### 1.6 Verify Persistent Properties on the Device

If ADB does not connect after reboot, verify the properties are set correctly from a serial console:

```bash
getprop | grep -i adb
```

Expected output:
```
[persist.adb.tcp.port]: [5555]
[persist.service.adb.enable]: [1]
[service.adb.tcp.port]: [5555]
[init.svc.adbd]: [running]
```

If `init.svc.adbd` shows `stopped` instead of `running`, trigger it manually for the current session:

```bash
stop adbd && start adbd
```

If this works but does not survive reboot, the init trigger in Section 1.3 is missing or not being loaded — verify the `.rc` file was included in the vendor image.

---

### 1.7 Summary of Files Changed

| File | Change |
|------|--------|
| `device/brcm/rpi/aosp_rpi_car.mk` | Add `persist.adb.tcp.port`, `persist.service.adb.enable` to `PRODUCT_SYSTEM_PROPERTIES` |
| `device/brcm/rpi/ramdisk/init.rpi.rc` | Add `on property:` triggers to restart `adbd` on boot and on property change |

---
