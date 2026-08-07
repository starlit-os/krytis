kind: stack

# Desktop-scoped gaming package set (docs/design/gaming-variant.md decision #1)
# — no handheld daemons (steamos-manager, powerstation, powerbuttond,
# valve-hw-audio, xonedo*), no second kernel (CachyOS already ships sched_ext
# + ntsync, see stacks/desktop.bst), no scx-scheds/scx-tools (pre-existing
# gap, not gaming-specific — scx_loader has no scheduler binaries to load
# either way and predates this work).
depends:
  - config/gamerslop.bst
  - gamerslop/steam.bst
  - gamerslop/gamescope.bst
  - gamerslop/gamescope-session.bst
  - gamerslop/gamescope-session-steam.bst
  - gamerslop/mangohud.bst
  - gamerslop/scopebuddy.bst
  - gamerslop/umu-launcher.bst
  - gamerslop/inputplumber.bst

  - sysext/gamerslop/lib32-filter.bst
