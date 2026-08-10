# Pins logind's lid-switch policy at the values krytis relies on, rather than
# inheriting them from whatever systemd compiles in. Closes #558.
#
# Effective behaviour is unchanged today, but "these are just the defaults
# written down" would be wrong. Read back off the running image with busctl
# (systemd 260): HandleLidSwitch="suspend" and HandleLidSwitchDocked="ignore"
# are literal defaults; HandleLidSwitchExternalPower reads back EMPTY. Since
# systemd 256 an unset value there means "follow HandleLidSwitch" rather than
# holding a default of its own, so pinning it to suspend matches the current
# behaviour only because HandleLidSwitch=suspend. It decouples the two: change
# HandleLidSwitch below and the on-AC case will no longer follow it, so edit
# both. See docs/skills/desktop.md § Two of the three pinned keys.
#
# The point of pinning is that lock-on-lid-close is a property of this image, so
# an upstream default flip must not be able to change it silently. Krytis sets
# nothing else here: /etc/systemd/logind.conf ships fully commented, and
# config/kmscon.bst's 10-krytis-vts.conf sets only NAutoVTs.
#
# The lid path this protects, end to end:
#
#   lid close
#     -> logind HandleLidSwitch=suspend
#          -> PrepareForSleep(true)
#               -> noctalia locks, holding a `delay` sleep inhibit
#                    -> inhibit released once the lock surface engages
#                         -> suspend
#
# The lock half is entirely noctalia's: LogindService::acquireSleepDelayInhibit()
# takes Inhibit("sleep", "noctalia", "Lock before sleep", "delay") and only lets
# go once the session is locked. Krytis ships no swayidle/hypridle/swaylock and
# needs none. See docs/skills/desktop.md § Lid close locks then suspends.
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
#
# HandleLidSwitchDocked=ignore is what makes an external-monitor/dock setup keep
# running with the lid shut; it covers a docked or multi-display session, so it
# belongs here alongside the other two rather than being left implicit.

kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/logind.conf.d/20-krytis-lid.conf" <<'EOF'
    # krytis: lid-switch policy, pinned rather than inherited. See the element
    # comment in elements/config/logind-lid.bst for the full lid -> logind ->
    # noctalia lock chain and the knobs left at their defaults on purpose.
    [Login]
    HandleLidSwitch=suspend
    HandleLidSwitchExternalPower=suspend
    HandleLidSwitchDocked=ignore
    EOF
