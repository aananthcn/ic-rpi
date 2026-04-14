# Static IP Configuration for Raspberry Pi 5 (Android AOSP)

## Overview
Configure a persistent static IP address on `eth0` for RPi5 running Android AOSP/Automotive.

---

## Step 1 — Create the shell script

Create `device/brcm/rpi5/eth_static.sh`:

```bash
#!/vendor/bin/sh
sleep 10
/system/bin/ip addr flush dev eth0
/system/bin/ip addr add 192.168.10.20/24 dev eth0
/system/bin/ip link set eth0 up
/system/bin/ip route show default | /system/bin/grep -q default || \
/system/bin/ip route add default via 192.168.10.1
```

> **Note:** Always use full paths in scripts launched by init — PATH is minimal at boot time.

---

## Step 2 — Create the init rc file

Create `device/brcm/rpi5/eth_static.rc`:

```rc
service vendor.eth_static /vendor/bin/sh /vendor/bin/eth_static.sh
    class late_start
    user root
    group net_admin net_raw
    seclabel u:r:vendor_eth_static:s0
    oneshot
    disabled

on property:sys.boot_completed=1
    start vendor.eth_static
```

> **Note:** Service name must have `vendor.` prefix. The `seclabel` line is mandatory — without it init refuses to start the service even in permissive SELinux mode.

---

## Step 3 — Create SELinux policy

Append to `device/brcm/rpi5/sepolicy/file_contexts`:

```
# Ethernet static IP script
/vendor/bin/eth_static\.sh    u:object_r:vendor_shell_exec:s0
```

Create `device/brcm/rpi5/sepolicy/vendor_eth_static.te`:

```
type vendor_eth_static, domain;
type vendor_eth_static_exec, exec_type, vendor_file_type, file_type;

init_daemon_domain(vendor_eth_static)
```

---

## Step 4 — Register files in device.mk

In `device/brcm/rpi5/device.mk`, add:

```makefile
PRODUCT_COPY_FILES += \
    device/brcm/rpi5/eth_static.sh:$(TARGET_COPY_OUT_VENDOR)/bin/eth_static.sh \
    device/brcm/rpi5/eth_static.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/eth_static.rc
```

> **Note:** Place `eth_static.rc` in `/vendor/etc/init/` directly — **not** in the `hw/` subdirectory. Files in `hw/` are parsed by `vendor_init` which cannot register services. Files directly in `/vendor/etc/init/` are parsed by system init.

---

## Step 5 — Build and flash

```bash
# Force clean rebuild
rm $OUT/vendor/bin/eth_static.sh
rm $OUT/vendor/etc/init/eth_static.rc

# Build
make vendorimage -j$(nproc)

# Verify before flashing
cat $OUT/vendor/bin/eth_static.sh
cat $OUT/vendor/etc/init/eth_static.rc
ls -la $OUT/vendor/bin/eth_static.sh   # must show -rwxr-xr-x
```

Flash via SD card:
```bash
# On device console
dd if=/mnt/sdcard_ext/vendor.img of=/dev/block/by-name/vendor bs=4M status=progress
sync
reboot
```

---

## Step 6 — Verify after reboot

```bash
# Service ran successfully (oneshot completed)
adb shell getprop init.svc.vendor.eth_static
# Expected: stopped

# IP is set
adb shell ifconfig eth0
# Expected: inet addr:192.168.10.20

# Reachable from host
ping 192.168.10.20
```

---

## Key lessons learned

| What failed | Why | Fix |
|---|---|---|
| Modifying `ramdisk/init.rpi5.rc` | RPi5 uses vendor init, not ramdisk | Use `/vendor/etc/init/` |
| Placing rc in `/vendor/etc/init/hw/` | Parsed by `vendor_init`, cannot register services | Place directly in `/vendor/etc/init/` |
| Missing `vendor.` prefix on service name | SELinux policy requires it for vendor services | Rename to `vendor.eth_static` |
| Missing `seclabel` | Init refuses domain transition without explicit label | Add `seclabel u:r:vendor_eth_static:s0` |
| Using `ip` without full path | Init runs with minimal PATH | Use `/system/bin/ip` explicitly |
| Script not executable | AOSP build cache preserved wrong permissions | Use `Android.bp` `prebuilt_etc` with `mode: "0755"` or `rm` output file before rebuild |
