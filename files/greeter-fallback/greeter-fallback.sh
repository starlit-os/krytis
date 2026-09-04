#!/usr/bin/env bash
# krytis-greeter-fallback — reveal a console when the greeter is not coming back.
#
# Runs from greetd's OnFailure=. That fires on EVERY entry into `failed`, not
# only when greetd gives up, so switching VTs unconditionally is wrong: greetd
# is Restart=always with RestartSec=1, and a transient crash — the #712 class,
# which has happened here for real — recovers on its own within about two
# seconds. Switching for that yanks the foreground to VT6 mid-recovery and can
# drop the user on a login console mid-password, for a fault that self-heals.
# Observed on hardware during the #728 acceptance test: five SIGKILLs, five
# firings, five pointless VT switches. See #733.
#
# So: wait out greetd's restart window before taking the display.
#
# This matters because config/plymouth-theme.bst quits plymouth with
# --retain-splash. A wedged greeter therefore shows a frozen splash — no
# console, no cursor, no error — and this is the only thing that puts a usable
# console back. root is locked (root:!unprovisioned) and sshd ships disabled by
# preset, so VT6 is the sole way in.

set -u

readonly GREETD=greetd.service
readonly RESCUE_VT=6
# greetd's RestartSec is 1s, so a recovery lands well inside this. Long enough
# to ride out a flap, short enough that nobody stares at a stuck splash: the
# definite-give-up case below short-circuits it anyway.
readonly GRACE_TRIES=10
readonly GRACE_SLEEP=0.5

for _ in $(seq "${GRACE_TRIES}"); do
    # Came back on its own — leave the display exactly as it is.
    if systemctl is-active --quiet "${GREETD}"; then
        exit 0
    fi

    # StartLimitBurst exhausted: systemd will not schedule another restart, so
    # there is nothing left to wait for. Switch now rather than burning the
    # rest of the grace period in front of a frozen splash.
    if [ "$(systemctl show -P Result "${GREETD}" 2>/dev/null)" = start-limit-hit ]; then
        break
    fi

    sleep "${GRACE_SLEEP}"
done

# Down and staying down. The VT switch makes fbcon repaint over plymouth's
# retained frame and logind spawns the getty it keeps on the reserved VT.
echo "greeter did not recover; switching to VT${RESCUE_VT}" >&2
exec /usr/bin/chvt "${RESCUE_VT}"
