kind: manual

# Ships /usr/libexec/krytis/battery-power-profile-hook.sh: a battery/AC
# power-profiles-daemon switch script, invoked from noctalia's [hooks]
# battery_discharging / battery_charging config (Settings -> Hooks). Opt-in
# by design (#261) -- this element only makes the script available; nothing
# in krytis sets the hook commands by default, so behavior is unchanged
# until a user pastes the two commands into their noctalia Hooks settings.
# See docs/design/power-profile-auto-switch.md for the full design and the
# exact commands to paste.
#
# No noctalia source patch needed: noctalia already ships a generic
# HookKind::BatteryDischarging/BatteryCharging/BatteryPlugged hook system
# (src/hooks/, wired to Settings -> Hooks text fields) -- this script is the
# only krytis-side artifact required.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 battery-power-profile-hook.sh \
      "%{install-root}/usr/libexec/krytis/battery-power-profile-hook.sh"

sources:
- kind: local
  path: files/battery-power-profile-hook
