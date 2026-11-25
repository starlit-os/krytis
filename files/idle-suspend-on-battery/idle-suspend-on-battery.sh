#!/bin/bash
# Idle suspend that only fires on battery (#1774).
#
# Invoked by noctalia's `[idle.behavior.suspend-on-battery]` rule, seeded for
# new accounts by files/noctalia-skel/settings.toml:
#
#   [idle.behavior.suspend-on-battery]
#   action = "command"
#   command = "/usr/libexec/krytis/idle-suspend-on-battery.sh"
#
# noctalia 5.6.0's idle rules have no power-source condition, so the check
# happens here, at the moment the rule fires: unplugging or plugging in before
# the timeout is honoured, because nothing is cached.
#
# Fails toward staying awake. Only an explicit `b true` from UPower's
# OnBattery suspends. A timeout, a missing UPower or any other reply exits 0
# without suspending; an awake laptop on battery is the safer failure than a
# desktop on AC that sleeps mid-job.
#
# The suspend itself goes through noctalia's own lock-and-suspend, so the
# session is locked (and every lock surface has drawn a safe frame) before
# logind suspends, the same path a manual "Lock and suspend" takes.
set -u

readonly TAG='krytis-idle-suspend'
# busctl's own default is 25 s. noctalia does not wait on this process, but a
# hung query should still give up long before the next idle cycle.
readonly QUERY_TIMEOUT="${KRYTIS_IDLE_SUSPEND_TIMEOUT:-3}"

log() {
    logger -t "${TAG}" -- "$1" 2>/dev/null || printf '%s: %s\n' "${TAG}" "$1" >&2
}

if ! reply=$(busctl --system --timeout="${QUERY_TIMEOUT}" get-property \
        org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower \
        OnBattery 2>&1); then
    log "UPower OnBattery query failed, staying awake: ${reply}"
    exit 0
fi

case "${reply}" in
    'b true')
        log 'on battery, locking and suspending'
        exec noctalia msg session lock-and-suspend
        ;;
    'b false')
        log 'on AC, staying awake'
        ;;
    *)
        log "unexpected UPower OnBattery reply, staying awake: ${reply}"
        ;;
esac
exit 0
