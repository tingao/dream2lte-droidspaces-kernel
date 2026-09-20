#!/system/bin/sh
# Apply airplane mode and bring Wi-Fi straight back, for handsets with no SIM.
#
#   sh airplane-wifi.sh on|off|status
#
# Self-healing by design: the script runs ON the device, so it does not depend on
# the SSH/tunnel session that asked for it. After enabling airplane mode it waits
# for the Wi-Fi interface to come back, and if it does not, it reverts to the
# previous state on its own. That matters on a headless phone: nobody is holding it.
set -u

ACTION="${1:-status}"
STATE=/data/local/tmp/airplane-wifi.previous

wifi_iface() { ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}'; }
have_wifi()  { [ -n "$(wifi_iface)" ] && ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; }

save_state() { printf 'airplane=%s\nwifi=%s\nradios=%s\n' \
  "$(settings get global airplane_mode_on)" "$(settings get global wifi_on)" \
  "$(settings get global airplane_mode_radios)" > "$STATE"; }

restore_state() {
  [ -r "$STATE" ] || return 0
  . "$STATE" 2>/dev/null || true
  [ -n "${radios:-}" ] && settings put global airplane_mode_radios "$radios"
  settings put global airplane_mode_on "${airplane:-0}"
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state "$([ "${airplane:-0}" = 1 ] && echo true || echo false)" >/dev/null 2>&1
  [ "${wifi:-1}" = 1 ] && svc wifi enable
  echo "  reverted to airplane=${airplane:-0} wifi=${wifi:-1} radios=${radios:-unchanged}"
}

case "$ACTION" in
  status)
    echo "airplane_mode_on : $(settings get global airplane_mode_on)"
    echo "wifi_on          : $(settings get global wifi_on)"
    echo "wlan0            : $(wifi_iface)"
    echo "SIM state        : $(getprop gsm.sim.state)"
    echo "radios cut by airplane mode: $(settings get global airplane_mode_radios)"
    echo "reachable        : $(have_wifi && echo yes || echo no)"
    ;;

  on)
    save_state
    echo "before: airplane=$(settings get global airplane_mode_on) wifi=$(settings get global wifi_on)"
    echo "        airplane_mode_radios=$(settings get global airplane_mode_radios)"

    # Airplane mode normally switches Wi-Fi off as well, because "wifi" is part of
    # airplane_mode_radios. That is fatal on a headless server: after a REBOOT the
    # framework applies airplane mode before anything can re-enable Wi-Fi, and the
    # handset comes up with no network at all (observed on the S8+, which stayed
    # offline until Wi-Fi was toggled by hand). Drop wifi from the radio set so
    # airplane mode cuts only the modem, and Wi-Fi survives reboots.
    orig_radios=$(settings get global airplane_mode_radios)
    new_radios=$(printf '%s' "$orig_radios" | sed 's/,wifi//g; s/wifi,//g')
    if [ -n "$new_radios" ] && [ "$new_radios" != "$orig_radios" ]; then
      settings put global airplane_mode_radios "$new_radios"
      echo "  radios: $orig_radios -> $new_radios  (Wi-Fi no longer cut by airplane mode)"
    fi

    echo "enabling airplane mode (kills the idle modem), then re-enabling Wi-Fi..."
    settings put global airplane_mode_on 1
    am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
    sleep 2
    svc wifi enable
    settings put global wifi_on 1
    # Both of the above are needed, and on LineageOS 18.1 (dream2lte) this last
    # one is what makes Wi-Fi survive a *reboot* while airplane mode is on. Without
    # it the handset boots with "Wifi is disabled", the supplicant stays
    # UNINITIALIZED, and neither `svc wifi enable` nor `cmd wifi set-wifi-enabled`
    # can revive it - the device was offline until airplane mode was turned off and
    # it was rebooted again. Always confirm with a reboot before trusting this on a
    # headless phone.
    cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || true
    # Give Wi-Fi association + DHCP a fair chance before judging it.
    i=0
    while [ "$i" -lt 30 ]; do
      have_wifi && break
      sleep 2
      i=$((i + 1))
    done
    if have_wifi; then
      echo "  OK: airplane mode on, Wi-Fi up at $(wifi_iface), internet reachable"
      echo "  (Wi-Fi is unaffected by airplane mode once explicitly re-enabled.)"
    else
      echo "  Wi-Fi did NOT come back within 60 s - reverting so the handset stays reachable"
      restore_state
      have_wifi && echo "  recovered after revert" || echo "  STILL unreachable - needs a hand on the device"
      exit 1
    fi
    ;;

  off)
    echo "disabling airplane mode..."
    settings put global airplane_mode_on 0
    am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
    svc wifi enable
    echo "  airplane=0 wifi=$(settings get global wifi_on)"
    ;;

  *)
    echo "usage: $0 on|off|status"; exit 2 ;;
esac
