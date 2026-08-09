kind: stack

# Desktop-scoped gaming package set (docs/design/gaming-variant.md decision #1)
# — no handheld daemons (steamos-manager, powerstation, powerbuttond,
# valve-hw-audio, xonedo*), no second kernel (CachyOS already ships sched_ext
# + ntsync, see stacks/desktop.bst), no scx-scheds/scx-tools (pre-existing
# gap, not gaming-specific — scx_loader has no scheduler binaries to load
# either way and predates this work).
depends:
  - config/gaming.bst
  - gaming/steam.bst
  - gaming/gamescope.bst
  - gaming/gamescope-session.bst
  - gaming/gamescope-session-steam.bst
  - gaming/mangohud.bst
  - gaming/scopebuddy.bst
  - gaming/umu-launcher.bst
  - gaming/inputplumber.bst

  - sysext/gaming/lib32-filter.bst
