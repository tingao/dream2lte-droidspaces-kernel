# dream2lte kernel with Droidspaces support

A patched kernel for the Galaxy S8+ (dream2lte, SM-G955F) on LineageOS 18.1 (Android 11). Built from the exynos8895/android_kernel_samsung_universal8895 tree, branch `lineage-18.1`, with the namespace and cgroup options [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) needs turned on, **plus the cgroup file-prefix patch that nested containers require**.

Why this exists: the stock kernel in the LineageOS 18.1 unofficial builds for this phone is missing several config options, and containers won't even start without them. `CONFIG_CGROUP_DEVICE` on its own is fatal. Networking was broken for containers too, since NAT/masquerade needs `CONFIG_VETH` and `CONFIG_BRIDGE`, and neither was enabled.

So the kernel is here, prebuilt. Or take the two patches and build it yourself.

---

## Which release you want

| Release | What it can do |
|---|---|
| **v1.1.0** (current) | Droidspaces containers **and** Docker/Podman/containerd *inside* them |
| v1.0.0 | Droidspaces containers only. `docker run` fails - see below. |

**If you are running v1.0.0, `docker run` cannot work.** The container starts, networking works, `docker pull` and `docker info` work, and then every attempt to actually create a container dies with:

```
OCI runtime create failed: unable to apply cgroup configuration:
open /sys/fs/cgroup/cpuset/docker/cpuset.cpus: no such file or directory
```

That cost a lot of time to track down, so it is written up in full below.

---

## The two patches

### 1. `container-support.patch` - the config

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

It also fixes a build error that has nothing to do with any of the above. `drivers/video/fbdev/exynos/dpu/decon_reg.c` declared its clock ratio table as `double` with fractional values, which won't compile under the kernel's `-mgeneral-regs-only` restriction. It is converted to integers, truncating the same way the original implicit float-to-int conversion did. The sibling `dual_dpu` and `decon_8890` driver variants in the same source tree already type that table this way, so it's not a new pattern.

### 2. `cgroup-prefix-fix.patch` - the one that makes Docker work

**Samsung mounts the cgroup v1 hierarchies with the `noprefix` option**, which drops the subsystem prefix from the controller file names. On a normal kernel you get `cpuset.cpus`; on this device you get `cpus`:

```
/sys/fs/cgroup/cpuset/   ->   cpus, effective_cpus, mem_exclusive, ...   (no cpuset.cpus)
```

runc (and therefore Docker, Podman, containerd) opens the **prefixed** name, does not find it, and refuses to create the container. Nothing is missing from the kernel config - the file simply has a different name than the runtime expects.

The fix, in `cgroup_add_file()`: when a hierarchy is mounted with `CGRP_ROOT_NOPREFIX`, also expose the prefixed name as a symlink to the same file.

```c
if (cft->ss && (cgrp->root->flags & CGRP_ROOT_NOPREFIX) && !(cft->flags & CFTYPE_NO_PREFIX)) {
    snprintf(pname, CGROUP_FILE_NAME_MAX, "%s.%s",
             cgroup_on_dfl(cgrp) ? cft->ss->name : cft->ss->legacy_name,
             cft->name);
    kernfs_create_link(cgrp->kn, pname, kn);   /* cpuset.cpus alongside cpus */
}
```

This is [Droidspaces' non-GKI patch 02](https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md), retargeted for this 4.4 tree. Two things had to change:

* upstream ships it against `kernel/cgroup/cgroup.c`, the layout used from 4.9 onwards. **This tree is 4.4, where the cgroup code is in `kernel/cgroup.c`.**
* 4.4's `cgroup_file_name()` builds the cgroup v1 prefix from **`legacy_name`**, not `name`. Using the upstream expression verbatim would create symlinks under the wrong filename, so the hunk uses the same expression `cgroup_file_name()` does.

The same patch also carries Droidspaces' non-GKI patch 01 (`xt_qtaguid`), which stops `iface_stat_fmt_proc_show()` calling `dev_get_stats()` on an inactive interface - a kernel panic, and the NAT path exercises it. Its edit has to be scoped to the function, because the declaration line it changes occurs three times in that file.

Exact-anchor edits are safer than `patch -p1` here, for exactly those two reasons.

---

## Building it yourself

```
defconfig   arch/arm64/configs/exynos8895-dream2lte_defconfig
toolchain   in-tree toolchain/gcc-cfp/gcc-cfp-jopp-only/aarch64-linux-android-4.9
```

A modern host GCC needs two flags, or the build fails before it reaches your code:

```sh
make -j"$(nproc)" HOSTCFLAGS="-O2 -fcommon" KCFLAGS="-Wno-error"
```

* **`HOSTCFLAGS=-fcommon`** - otherwise `scripts/dtc` fails to link with `multiple definition of 'yylloc'`. GCC 10+ defaults to `-fno-common` and 4.x kernels rely on the old behaviour.
* **`KCFLAGS=-Wno-error`** - this tree sets `-Werror` in `KBUILD_CFLAGS`, and modern GCC flags old vendor code (e.g. `-Wenum-compare` in `drivers/misc/modem_v1/`). Samsung's own builds produced those as warnings.

Then pack the boot image. The BOOT partition is exactly **41,943,040 bytes (40 MiB)**, and the stock ramdisk is reused - only the kernel changes:

```sh
abootimg --create new_boot.img -f bootimg.cfg \
  -k arch/arm64/boot/Image -r initrd.img
```

with `kerneladdr 0x10008000`, `ramdiskaddr 0x11000000`, `bootsize 0x2800000`.

To confirm the fix actually landed, the built `vmlinux` should show the call inside `cgroup_add_file`:

```sh
aarch64-linux-gnu-objdump -d vmlinux | awk '/<cgroup_add_file>:/{f=1} f{print} f&&/^$/{exit}' | grep kernfs_create_link
```

Use an **aarch64** objdump. The host one prints nothing at all for an arm64 `vmlinux`, which looks exactly like a missing patch.

---

## Flashing

Grab the prebuilt image from the [Releases page](https://github.com/tingao/dream2lte-droidspaces-kernel/releases/latest).

This replaces the BOOT partition and nothing else. Your ramdisk, system, and GApps stay as they are. You need a working LineageOS 18.1 install on the device with root already set up (Magisk or similar), because the flash goes through `dd` from a rooted shell.

**Back up the current boot partition first, and verify the write:**

```
adb shell su -c "dd if=/dev/block/platform/11120000.ufs/by-name/BOOT of=/sdcard/boot-backup.img"
adb pull /sdcard/boot-backup.img

adb push new_boot.img /sdcard/boot.img
adb shell su -c "md5sum /sdcard/boot.img"          # compare against the release md5
adb shell su -c "dd if=/sdcard/boot.img of=/dev/block/platform/11120000.ufs/by-name/BOOT bs=4096 conv=fsync"
adb shell su -c "dd if=/dev/block/platform/11120000.ufs/by-name/BOOT bs=4096 | md5sum"   # must match
adb reboot
```

If the read-back does not match, restore the backup before rebooting:

```
adb shell su -c "dd if=/sdcard/boot-backup.img of=/dev/block/platform/11120000.ufs/by-name/BOOT bs=4096 conv=fsync"
```

If your ramdisk isn't stock, unpack the image and dd just the kernel (`Image`) instead. The boot image shipped here uses the stock ramdisk from an unmodified LineageOS 18.1 install, so a customized one won't survive a straight flash.

I'd take the backup even if your setup looks identical to mine. Mine is the only combination this was built and tested against.

In download mode, Odin can flash the same image from an AP tar containing it as `boot.img`.

---

## Tested on

- SM-G955F (dream2lte), LineageOS 18.1 unofficial `lineage-18.1-20250628-UNOFFICIAL-dream2lte`, MindTheGapps, Magisk v30.7, TWRP 3.7.0_9-0.
- Display, touch, sensors and wifi unaffected. It boots normally.
- **v1.1.0 verified end to end:** with the cgroup patch in place `cpuset.cpus`, `cpuset.mems`, `memory.limit_in_bytes` and `cpu.shares` all exist; `docker run --rm hello-world` succeeds, detached containers start, `docker exec` and `docker rm` work, and Portainer and Dockge run inside the container.

## Not included

- KernelSU integration. Magisk works here, and this is tested with it. Enable Daemon Mode in the Droidspaces app settings as their docs say.
- No performance changes. On this SoC the useful levers are all userspace - `cpuhotplug/enabled`, the cpufreq ceiling, the Mali GPU ceiling - so a kernel "performance" change here would be cosmetic, and shipping one while claiming a gain would be dishonest. Kernel thermal trip points are deliberately left exactly stock.

---

## Running a container server on it? Two things that are not kernel problems

A phone that serves something is woken by nobody, so two userspace behaviours matter more than they would
on a desktop. Both are covered in `extras/`, and neither needs a kernel change.

**It suspends, and the tunnel dies with it.** This handset sleeps constantly, and the Broadcom Wi-Fi
driver cannot enter suspend cleanly (`dhd_set_suspend lpas failed -23`), so the radio stops passing
traffic and a Cloudflare connector loses all four QUIC connections until somebody touches the screen.
Hold a kernel wakeup source and the problem disappears: `extras/98-keep-awake.sh` into
`/data/adb/service.d/`, reboot. Full reasoning, verification and costs in
[docs/KEEP-AWAKE.md](docs/KEEP-AWAKE.md).

**Stock software keeps phoning home.** On a headless device every store, updater and sync adapter is pure
cost. `extras/debloat-apply.sh` applies a package list with `pm disable-user`, which is reversible from a
rollback script it writes first — see `extras/debloat-list.txt` for exactly what is disabled and, just as
importantly, the list of things deliberately kept.

