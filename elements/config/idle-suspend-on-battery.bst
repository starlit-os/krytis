kind: manual

# Ships /usr/libexec/krytis/idle-suspend-on-battery.sh, the helper behind the
# 15-minute idle suspend that files/noctalia-skel/settings.toml seeds for new
# accounts (#1774). noctalia 5.6.0's idle rules have no power-source
# condition, so the rule is `action = "command"` and this script reads UPower's
# OnBattery itself: on battery it runs `noctalia msg session lock-and-suspend`,
# on AC or on any query failure it exits without suspending.
#
# A separate element rather than an install line in config/noctalia-skel.bst:
# existing accounts never get the skel, and the documented opt-in for them
# points at this path, so the helper must be present on every image whether or
# not the account was seeded. See docs/skills/desktop.md § Idle suspends on
# battery only.
#
# Runtime needs, all already in the image: busctl (systemd), UPower on the
# system bus (pulled in transitively, see config/starlit-update.bst),
# noctalia, and logger (util-linux) for the journal lines.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 idle-suspend-on-battery.sh \
      "%{install-root}/usr/libexec/krytis/idle-suspend-on-battery.sh"

sources:
- kind: local
  path: files/idle-suspend-on-battery
