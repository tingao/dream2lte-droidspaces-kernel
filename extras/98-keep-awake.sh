#!/system/bin/sh
# 98-keep-awake.sh - stop this handset suspending, so containers and their tunnels stay up.
#
# WHY
#   This device suspends constantly and its Broadcom Wi-Fi driver cannot enter
#   suspend cleanly. dmesg shows, on every attempt:
#
#       dhd_set_suspend: force extra Suspend setting
#       dhd_set_suspend lpas failed -23
#       dhd_set_suspend bcn_to_dly failed -23
#
#   The radio stops passing traffic. A container on the device is frozen with it,
#   so a Cloudflare connector loses all four QUIC connections and every published
#   hostname answers 1033 ("Argo Tunnel error") until somebody wakes the screen.
#   See docs/KEEP-AWAKE.md.
#
# INSTALL
#   su -c 'cp /sdcard/98-keep-awake.sh /data/adb/service.d/ && chmod 755 /data/adb/service.d/98-keep-awake.sh'
#   then reboot. Magisk and KernelSU-Next both execute /data/adb/service.d/* as root at boot.
#
# REVERT
#   rm /data/adb/service.d/98-keep-awake.sh
#   su -c 'echo dsh-keepawake > /sys/power/wake_unlock'    # immediate, until next boot
#
# COST
#   Standby drain goes from ~0 to about 1-3 %/h: the SoC no longer idles in
#   suspend. Fine on a charger.

LOCK=dsh-keepawake
WAKELOCK=/sys/power/wake_lock

# Wait briefly for /sys to be ready - a boot script can run very early.
i=0
while [ ! -w "$WAKELOCK" ] && [ "$i" -lt 30 ]; do
  sleep 1
  i=$((i + 1))
done

if [ ! -w "$WAKELOCK" ]; then
  echo "keep-awake: no writable $WAKELOCK - kernel lacks the userspace wakeup-source interface"
  exit 1
fi

# The lock is not tied to this process: it stays active after this script exits,
# and only 'echo <name> > /sys/power/wake_unlock' releases it.
echo "$LOCK" > "$WAKELOCK" 2>/dev/null

case "$(cat "$WAKELOCK" 2>/dev/null)" in
  *"$LOCK"*) echo "keep-awake: held (the handset will not suspend until reboot or unlock)" ;;
  *)         echo "keep-awake: FAILED to take the lock"; exit 1 ;;
esac

# Optional: leave a note in the log so the hold is explainable months later.
log -t keep-awake "wakeup source '$LOCK' held by /data/adb/service.d/98-keep-awake.sh" 2>/dev/null
exit 0
