#!/bin/bash
# Battery/AC-triggered power-profiles-daemon profile switch (#261).
#
# Invoked from noctalia's [hooks] battery_discharging / battery_charging
# (Settings -> Hooks -> "Battery Discharging" / "Battery Charging" fields).
# Opt-in: does nothing unless the user pastes it into those fields — no
# krytis-shipped config sets them by default.
#
#   battery_discharging = "/usr/libexec/krytis/battery-power-profile-hook.sh discharging"
#   battery_charging    = "/usr/libexec/krytis/battery-power-profile-hook.sh charging"
#
# noctalia's battery_charging hook fires on the Discharging->Charging UPower
# state edge (AC reconnected while below 100%). It does NOT fire again once
# already at full charge — that edge is battery_plugged instead (Charging/
# Discharging->FullyCharged/PendingCharge). Only battery_charging is wired
# here: on a laptop already at 100% when AC is reconnected, the state can
# jump straight to FullyCharged without a Charging edge, in which case this
# hook does not run for that reconnect. Accepted tradeoff — see
# docs/design/power-profile-auto-switch.md.
#
# Coexistence with falcond: skip every action while falcond holds a
# game-profile (`ACTIVE_PROFILE` non-empty in its documented third-party
# status contract) so this never fights a game's `performance` hold.
set -eu

readonly BUS_DEST='org.freedesktop.UPower.PowerProfiles'
readonly BUS_PATH='/org/freedesktop/UPower/PowerProfiles'
readonly BUS_IFACE='org.freedesktop.UPower.PowerProfiles'
readonly STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/krytis-battery-power-profile.state"
readonly FALCOND_STATUS_FILE="${KRYTIS_FALCOND_STATUS_FILE:-/tmp/falcond_status}"
readonly BATTERY_PROFILE='power-saver'
readonly FALLBACK_AC_PROFILE='balanced'

log() {
    printf 'battery-power-profile-hook: %s\n' "$1" >&2
}

# Fails closed: falcond is unconditionally installed and enabled in krytis
# (elements/stacks/desktop.bst), so an unreadable/missing status file means
# either a brief pre-first-write boot race or a stopped/crashed daemon --
# both treated as "holding" so this never guesses past a state falcond
# hasn't published yet. Self-corrects on the next battery event once
# falcond writes a real status. A malformed ACTIVE_PROFILE line with no
# value is "free" (falcond is up and reports no active hold).
falcond_holding() {
    [ -r "${FALCOND_STATUS_FILE}" ] || return 0
    line=$(grep '^ACTIVE_PROFILE:' "${FALCOND_STATUS_FILE}" 2>/dev/null || true)
    value=$(printf '%s' "${line}" | sed -e 's/^ACTIVE_PROFILE: *//' -e 's/[[:space:]]*$//')
    [ -n "${value}" ] && [ "${value}" != '(None)' ]
}

get_active_profile() {
    busctl get-property "${BUS_DEST}" "${BUS_PATH}" "${BUS_IFACE}" ActiveProfile 2>/dev/null \
        | sed -n 's/^s "\(.*\)"$/\1/p'
}

set_active_profile() {
    busctl set-property "${BUS_DEST}" "${BUS_PATH}" "${BUS_IFACE}" ActiveProfile s "$1"
}

on_discharging() {
    if falcond_holding; then
        log 'falcond holding a game profile, skipping switch to power-saver'
        return 0
    fi

    current=$(get_active_profile)
    if [ -z "${current}" ]; then
        log 'could not read current ActiveProfile, skipping'
        return 0
    fi
    if [ "${current}" = "${BATTERY_PROFILE}" ]; then
        # Already on the battery profile (e.g. rapid unplug/replug/unplug) -
        # nothing to record or switch, and recording now would overwrite a
        # genuine prior profile with our own auto-switch target.
        return 0
    fi

    printf '%s' "${current}" > "${STATE_FILE}"
    set_active_profile "${BATTERY_PROFILE}"
}

on_charging() {
    if falcond_holding; then
        log 'falcond holding a game profile, skipping AC-reconnect revert'
        return 0
    fi

    target="${FALLBACK_AC_PROFILE}"
    if [ -r "${STATE_FILE}" ]; then
        recorded=$(cat "${STATE_FILE}")
        [ -n "${recorded}" ] && target="${recorded}"
    fi
    set_active_profile "${target}"
}

case "${1:-}" in
    discharging)
        on_discharging
        ;;
    charging)
        on_charging
        ;;
    *)
        log "usage: $0 <discharging|charging>"
        exit 64
        ;;
esac
