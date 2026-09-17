# dream2lte Droidspaces Kernel

A patched kernel for the Samsung Galaxy S8+ (`dream2lte`, SM-G955F) running **LineageOS 18.1** (Android 11), built from the [exynos8895/android_kernel_samsung_universal8895](https://github.com/exynos8895/android_kernel_samsung_universal8895) `lineage-18.1` tree, with the container/namespace support needed to run [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) enabled.

The stock kernel that ships with the LineageOS 18.1 unofficial builds for this device is missing several kernel config options that Droidspaces requires to start containers at all (`CONFIG_CGROUP_DEVICE` in particular is fatal without it) and to give containers working network access (NAT/masquerade needs `CONFIG_VETH` + `CONFIG_BRIDGE`, which weren't enabled). This repo fixes that so you don't have to build it yourself.

## What's different from stock

Namespaces / cgroups:
- `CONFIG_SYSVIPC`, `CONFIG_IPC_NS`, `CONFIG_POSIX_MQUEUE`
- `CONFIG_CGROUP_PIDS`, `CONFIG_CGROUP_DEVICE`, `CONFIG_CGROUP_NET_PRIO`
- `CONFIG_USER_NS`

Networking (needed for container NAT/internet access):
- `CONFIG_VETH`, `CONFIG_BRIDGE`
- `CONFIG_NF_TABLES`
- `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`
- `CONFIG_ANDROID_PARANOID_NETWORK` disabled (was blocking socket ops needed for container networking)

Filesystem:
- `CONFIG_OVERLAY_FS` (containers need this for their root filesystem layering)

Also fixed a build error unrelated to any of the above: `drivers/video/fbdev/exynos/dpu/decon_reg.c` had a clock ratio table declared as `double` with fractional values, which doesn't compile under the kernel's `-mgeneral-regs-only` restriction. Converted it to integer values (truncated, matching the original implicit float->int conversion behavior) — this matches how the equivalent table is already typed in the sibling `dual_dpu` and `decon_8890` driver variants in the same source tree, so it's not a new pattern.

See [`container-support.patch`](container-support.patch) for the exact diff if you want to build it yourself instead of using the prebuilt image.

## Flashing

Download the prebuilt image from the [Releases page](https://github.com/tingao/dream2lte-droidspaces-kernel/releases/latest).

This replaces the **BOOT partition only** — ramdisk, system, GApps, etc. are untouched. You need an existing working LineageOS 18.1 install on this device with root (Magisk or similar) already set up, since the flash is done via `dd` from a rooted shell:

```
adb push dream2lte-lineage18.1-droidspaces-boot.img /sdcard/boot.img
adb shell su -c "dd if=/sdcard/boot.img of=/dev/block/platform/11120000.ufs/by-name/BOOT"
adb reboot
```

Alternatively, unpack it and dd just the kernel (`Image`) if you'd rather keep your current ramdisk — the boot image here uses the stock ramdisk from an unmodified LineageOS 18.1 install, so if yours is customized you may prefer that route.

**Back up your current boot partition first**, in case anything about your setup differs from what this was built against:

```
adb shell su -c "dd if=/dev/block/platform/11120000.ufs/by-name/BOOT of=/sdcard/boot-backup.img"
adb pull /sdcard/boot-backup.img
```

## Tested on

- SM-G955F (dream2lte), LineageOS 18.1 unofficial build (`lineage-18.1-20250628-UNOFFICIAL-dream2lte`), MindTheGapps, Magisk v30.7 root, TWRP 3.7.0_9-0 for flashing the ROM itself.
- Boots normally, hardware (display, touch, sensors, wifi) unaffected.
- Droidspaces container creation and startup confirmed working after this kernel.

## Not included

- KernelSU integration (Magisk works fine for this, just needs "Daemon Mode" enabled in the Droidspaces app settings + a reboot, per Droidspaces' own docs).
