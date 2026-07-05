#!/bin/sh
# ExecCondition= gate for starlit-update units: skip the run if the active
# power profile is power-saver, or the active network connection is metered.
# AC-power gating is handled natively via ConditionACPower= in the unit
# files, not here.
set -eu

profile=$(busctl --system get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null \
  | sed -E 's/^s +"(.*)"$/\1/') || exit 1
[ "$profile" = "power-saver" ] && exit 1

metered=$(busctl --system get-property org.freedesktop.NetworkManager \
  /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Metered 2>/dev/null \
  | awk '{print $2}') || exit 1
case "$metered" in
  1|3) exit 1 ;;  # NM_METERED_YES, NM_METERED_GUESS_YES
esac

exit 0
