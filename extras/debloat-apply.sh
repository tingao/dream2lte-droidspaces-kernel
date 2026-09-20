#!/system/bin/sh
# Reversible debloat applier for the two server handsets.
#
#   sh /data/local/tmp/debloat-apply.sh <list-file>
#
# Deliberately uses `pm disable-user --user 0` rather than uninstall:
#   * it is reversible with one command per package (`pm enable`);
#   * it leaves the APK on the system partition, so a mistake cannot leave the
#     device without a component it needs to boot;
#   * unlike `pm uninstall --user 0`, it survives a wipe of the user data.
# Every action is written to a rollback script, printed at the end, so the whole
# pass can be undone in one go.
set -u

LIST="${1:-/data/local/tmp/debloat-list.txt}"
SERIAL=$(getprop ro.serialno)
STAMP=$(date +%Y%m%d-%H%M%S)
ROLLBACK="/data/local/tmp/debloat-rollback-$SERIAL-$STAMP.sh"

[ -r "$LIST" ] || { echo "cannot read list: $LIST"; exit 1; }

echo "device      : $(getprop ro.product.model) / $(getprop ro.product.device)"
echo "list        : $LIST ($(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$LIST") candidates)"
echo "rollback to : $ROLLBACK"
echo

cat > "$ROLLBACK" <<EOF
#!/system/bin/sh
# Rollback for the debloat applied on $SERIAL at $STAMP.
# Run as root:  su -c 'sh $ROLLBACK'
EOF
chmod 0755 "$ROLLBACK"

disabled=0
skipped_absent=0
skipped_already=0
failed=0

for pkg in $(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$LIST"); do
  if ! pm path "$pkg" >/dev/null 2>&1; then
    skipped_absent=$((skipped_absent + 1))
    continue
  fi
  if pm list packages -d 2>/dev/null | grep -qx "package:$pkg"; then
    skipped_already=$((skipped_already + 1))
    continue
  fi
  if pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
    echo "pm enable --user 0 $pkg" >> "$ROLLBACK"
    disabled=$((disabled + 1))
    echo "  disabled: $pkg"
  else
    echo "  FAILED  : $pkg"
    failed=$((failed + 1))
  fi
done

echo
echo "=== summary ==="
echo "  disabled now        : $disabled"
echo "  already disabled    : $skipped_already"
echo "  not installed here  : $skipped_absent"
echo "  failed              : $failed"

# --- background network and wakeups for the services we keep -----------------
# GMS/GSF/Play are needed by the framework on stock One UI, so instead of
# disabling them we take away their ability to run in the background: that is
# what "phoning home" actually costs. android auto-start is left alone so the
# device still boots normally.
echo
echo "=== restricting background activity (reversible with 'allow') ==="
for pkg in com.google.android.gms com.google.android.gsf com.android.vending com.google.android.gms.location.history; do
  pm path "$pkg" >/dev/null 2>&1 || continue
  for op in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND; do
    before=$(cmd appops get "$pkg" "$op" 2>/dev/null | sed 's/.*: //')
    cmd appops set "$pkg" "$op" ignore >/dev/null 2>&1 \
      && echo "  $pkg $op: ${before:-?} -> $(cmd appops get "$pkg" "$op" 2>/dev/null | sed 's/.*: //')"
  done
  echo "cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow" >> "$ROLLBACK"
  echo "cmd appops set $pkg RUN_IN_BACKGROUND allow" >> "$ROLLBACK"
done

# --- drop doze-whitelist entries that no longer need to wake the device ------
echo
echo "=== doze whitelist cleanup ==="
for pkg in com.samsung.android.ipsgeofence com.sec.android.app.launcher; do
  if dumpsys deviceidle whitelist 2>/dev/null | grep -q "$pkg"; then
    case "$pkg" in
      *launcher) echo "  kept (launcher): $pkg" ;;
      *)
        cmd deviceidle whitelist -"$pkg" >/dev/null 2>&1 && {
          echo "  removed: $pkg"
          echo "cmd deviceidle whitelist +$pkg" >> "$ROLLBACK"
        }
        ;;
    esac
  fi
done

echo
echo "=== rollback script written ($(grep -c . "$ROLLBACK") lines) ==="
echo "  $ROLLBACK"
