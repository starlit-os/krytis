# Pins logind's lid-switch policy at the values krytis relies on, rather than
# inheriting them from whatever systemd compiles in. Pinned by #558; the on-AC
# case changed from suspend to lock in #1774.
#
#   HandleLidSwitch=suspend              on battery: lock, then suspend
#   HandleLidSwitchExternalPower=lock    on AC, undocked: lock and keep running
#   HandleLidSwitchDocked=ignore         dock or external display: keep running
#
# HandleLidSwitch and HandleLidSwitchDocked are systemd's literal defaults.
# HandleLidSwitchExternalPower is not: unset, it reads back EMPTY over busctl
# and, since systemd 256, means "follow HandleLidSwitch". Setting it is what
# makes the on-AC case differ. Docked wins over external power, so a docked
# laptop on AC still ignores the lid. While the lid stays shut logind
# re-evaluates (button_recheck()), and `suspend` acts on that recheck but `lock`
# does not: unplugging AC with the lid shut suspends, while undocking on AC with
# the lid shut leaves the session as it was. See docs/skills/desktop.md § Lid
# policy per power source.
#
# The point of pinning is that lid behaviour is a property of this image, so
# an upstream default flip must not be able to change it silently. Krytis sets
# nothing else here: /etc/systemd/logind.conf ships fully commented, and
# config/kmscon.bst's 10-krytis-vts.conf sets only NAutoVTs. A local drop-in in
# /etc/systemd/logind.conf.d/ still overrides this file.
#
# On AC, `lock` makes logind send Session.Lock to every session; noctalia
# subscribes to it (LogindService::ensureSessionLockMonitor()) and locks. No
# sleep happens, so no inhibit is involved.
#
# On battery, the suspend path is, end to end:
#
#   lid close
#     -> logind HandleLidSwitch=suspend
#          -> PrepareForSleep(true)
#               -> noctalia locks, holding a `delay` sleep inhibit
#                    -> inhibit released once the session is locked and every lock
#                       surface has acknowledged a frame with no pre-lock desktop capture
#                         -> suspend
#
# The lock half is entirely noctalia's: LogindService::acquireSleepDelayInhibit()
# takes Inhibit("sleep", "noctalia", "Lock before sleep", "delay"), and the
# PrepareForSleep handler calls LockScreen::prepareForSleep(), whose ready-for-sleep
# hook releases it (noctalia v5.3.0, upstream c83fb9b9c).
# Releasing on the bare `locked` event is not enough: the panel keeps its last frame
# through sleep, and the first lock frames of an animated lock are a screenshot of
# the unlocked desktop. Krytis ships no swayidle/hypridle/swaylock and needs none.
# See docs/skills/desktop.md § Lid close locks, and suspends on battery.
#
# Two neighbouring knobs are deliberately left at their defaults:
#
#   InhibitDelayMaxSec (5s)         the ceiling on noctalia's lock window — if the
#                                   lock surface is not up in time logind suspends
#                                   anyway. No evidence noctalia's lock is that
#                                   slow; raising it would trade a real 5s suspend
#                                   delay for a hypothetical race.
#   LidSwitchIgnoreInhibited (yes)  block-type handle-lid-switch inhibitors are
#                                   ignored, so only delay inhibits (noctalia's)
#                                   are honoured. An app cannot hold the lid open.

kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/logind.conf.d/20-krytis-lid.conf"
    cat > "%{install-root}%{indep-libdir}/systemd/logind.conf.d/20-krytis-lid.conf" <<'EOF'
    # krytis: lid-switch policy, pinned rather than inherited. On battery the
    # lid locks then suspends; on AC it only locks; docked it is ignored. See
    # the element comment in elements/config/logind-lid.bst for the lid ->
    # logind -> noctalia lock chain and the knobs left at their defaults.
    [Login]
    HandleLidSwitch=suspend
    HandleLidSwitchExternalPower=lock
    HandleLidSwitchDocked=ignore
    EOF
