# dream2lte kernel with Droidspaces support

A patched kernel for the Galaxy S8+ (dream2lte, SM-G955F) on LineageOS 18.1 (Android 11). Built from the exynos8895/android_kernel_samsung_universal8895 tree, branch `lineage-18.1`, with the namespace and cgroup options [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) needs turned on.

Why this exists: the stock kernel in the LineageOS 18.1 unofficial builds for this phone is missing several config options, and containers won't even start without them. `CONFIG_CGROUP_DEVICE` on its own is fatal. Networking was broken for containers too, since NAT/masquerade needs `CONFIG_VETH` and `CONFIG_BRIDGE`, and neither was enabled.

So the kernel is here, prebuilt. Or take the patch and build it yourself.

## What's different from stock

Namespaces and cgroups:
- `CONFIG_SYSVIPC`, `CONFIG_IPC_NS`, `CONFIG_POSIX_MQUEUE`
- `CONFIG_CGROUP_PIDS`, `CONFIG_CGROUP_DEVICE`, `CONFIG_CGROUP_NET_PRIO`
- `CONFIG_USER_NS`

Networking (containers need this to reach the internet):
- `CONFIG_VETH`, `CONFIG_BRIDGE`
- `CONFIG_NF_TABLES`
- `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`
- `CONFIG_ANDROID_PARANOID_NETWORK` disabled. It was blocking the socket operations container networking depends on.

Filesystem:
- `CONFIG_OVERLAY_FS`, for layering a container's root filesystem

I also had to fix a build error that has nothing to do with any of the above. `drivers/video/fbdev/exynos/dpu/decon_reg.c` declared its clock ratio table as `double` with fractional values, which won't compile under the kernel's `-mgeneral-regs-only` restriction. I converted it to integers, truncating the same way the original implicit float-to-int conversion did. The sibling `dual_dpu` and `decon_8890` driver variants in the same source tree already type that table this way, so it's not a new pattern.

The exact diff is in [`container-support.patch`](container-support.patch) if you'd rather build it yourself than use the prebuilt image.

## Flashing

Grab the prebuilt image from the [Releases page](https://github.com/tingao/dream2lte-droidspaces-kernel/releases/latest).

This replaces the BOOT partition and nothing else. Your ramdisk, system, and GApps stay as they are. You need a working LineageOS 18.1 install on the device with root already set up (Magisk or similar), because the flash goes through `dd` from a rooted shell:

```
adb push dream2lte-lineage18.1-droidspaces-boot.img /sdcard/boot.img
adb shell su -c "dd if=/sdcard/boot.img of=/dev/block/platform/11120000.ufs/by-name/BOOT"
adb reboot
```

If your ramdisk isn't stock, unpack the image and dd just the kernel (`Image`) instead. The boot image I'm shipping uses the stock ramdisk from an unmodified LineageOS 18.1 install, so a customized one won't survive the straight flash.

Back up the current boot partition before you touch anything:

```
adb shell su -c "dd if=/dev/block/platform/11120000.ufs/by-name/BOOT of=/sdcard/boot-backup.img"
adb pull /sdcard/boot-backup.img
```

I'd do this even if your setup looks identical to mine. Mine is the only combination this was built and tested against.

## Tested on

- SM-G955F (dream2lte), LineageOS 18.1 unofficial build `lineage-18.1-20250628-UNOFFICIAL-dream2lte`, MindTheGapps, Magisk v30.7 root, TWRP 3.7.0_9-0 for flashing the ROM itself.
- It boots normally. Display, touch, sensors, and wifi are all unaffected.
- Droidspaces creates and starts containers after this kernel is flashed. Confirmed.

## Not included

- KernelSU integration. Magisk is fine here, you just need Daemon Mode enabled in the Droidspaces app settings and a reboot, as their docs say.
