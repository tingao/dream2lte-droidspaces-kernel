# Keeping the phone awake, so the container and its tunnel survive

**Symptom.** The tunnel and anything served from this handset disappear "after a while" and come back
the moment somebody touches the screen. Nothing has crashed: the container is still running, and
`docker ps` is still healthy once you get back in.

**Cause.** This handset suspends constantly, and its Broadcom Wi-Fi driver cannot enter suspend cleanly.
`dmesg` shows the sequence on every sleep attempt:

```
dhd_set_suspend: force extra Suspend setting
dhd_set_suspend lpas failed -23
dhd_set_suspend bcn_to_dly failed -23
```

The radio stops passing traffic. While suspended the container is frozen too, so a Cloudflare connector
cannot keep its QUIC heartbeats alive: all four connections expire, and every published hostname answers
Cloudflare **`1033`** ("Argo Tunnel error") until the screen is touched. A Droidspaces container does not
cause this and cannot fix it from inside — the suspend decision is the kernel's.

**Fix.** Hold a kernel wakeup source, so the kernel never suspends:

```sh
echo dsh-keepawake > /sys/power/wake_lock      # hold
echo dsh-keepawake > /sys/power/wake_unlock    # release
```

`extras/98-keep-awake.sh` does that at boot. Drop it into `/data/adb/service.d/` (Magisk or KernelSU-Next
both run that directory as root at boot), reboot, and the hold is in place before the container starts.

> The lock is **not** tied to the process that wrote it: `98-keep-awake.sh` exits immediately and the
> wakeup source stays active until the name is written to `wake_unlock`. That is what makes a one-shot
> boot script sufficient.

## Verify it is actually holding

```sh
su -c 'cat /sys/power/wake_lock'        # expect: dsh-keepawake
```

To prove it stops the *suspends* rather than just being present, sample the wall clock and the suspend
counter for a while and look for gaps — a suspended kernel cannot run your sampler:

```sh
su -c 'dmesg | grep -c "PM: suspend entry"'    # before: grows over time
```

A gap in the samples, or a rising `PM: suspend entry` count, means the handset still slept.

## Costs and caveats

* Standby drain rises from roughly zero (suspended) to about **1–3 %/h**. On the cable that is free;
  unplugged it turns "days" into "hours". These server handsets live on a charger, which is why the
  script holds the lock unconditionally.
* If you need a handset that may run unattended on battery, add a floor instead of holding blindly: hold
  the lock while the battery is above some percentage and release it below that. A handset flat enough to
  die is a server that is down anyway.
* Expect temperatures to sit a few degrees higher, since the SoC no longer idles in suspend.
* Revert with `rm /data/adb/service.d/98-keep-awake.sh`, reboot, or for an immediate effect:
  `su -c 'echo dsh-keepawake > /sys/power/wake_unlock'`.

## Do not confuse this with two other things

* **The battery percentage is not evidence.** These handsets run ACC (Advanced Charging Controller)
  holding the pack in a fixed band, so the percentage sits still whether the phone is asleep or awake.
  Judge by the log gap, not the gauge.
* **`usb/online=0` with `status=Discharging` is also normal** on a phone whose charging is managed by
  ACC. It does not mean the cable is data-only.
