# systemd-oomd — userspace OOM killer, armed on users' app.slice only (#219, #1216, #1752).
#
# oomd acts on nothing by default: it only watches cgroups whose unit sets
# ManagedOOMSwap=kill or ManagedOOMMemoryPressure=kill. Until #1216 nothing did,
# and the old oomd.conf.d drop-in used a section ([OOMPolicy]) oomd.conf does not
# have, so the service ran but never acted.
#
# What this arms: a memory-pressure kill and a swap kill on the user manager's
# app.slice.
# app.slice holds what users launch (niri's and umbriel's app-*.scope units,
# noctalia's launcher services, flatpak scopes). session.slice holds niri.service,
# umbriel.service, dbus, the portals and pipewire, and is never a candidate.
# oomd kills a whole candidate cgroup and picks it by reclaim activity, not by
# oom_score_adj, so what it is allowed to see is the only protection the session
# gets from it.
#
# The swap kill (#1752). On 2026-11-21 melog ran out of swap with app.slice's
# pressure never near 50 %, and the kernel killed three apps (kswapd, through
# MGLRU's min_ttl). ManagedOOMSwap=kill fires only when memory used AND swap used
# both pass oomd.conf's SwapUsedLimit= (default 90 %; oomd-manager.c, systemd
# 262.2), then kills the app.slice leaf with the most swap, among those holding
# more than 5 % of it. Requiring RAM to be gone too is what keeps it off a desktop
# that still has RAM free, the case that made Ubuntu drop its -.slice swap kill
# (LP: #1972159). In mise run oomd-test --scenario swap it killed about 10 s
# sooner than the kernel when swap filled slowly (the #1752 matrix).
#
# Deliberately NOT armed (see docs/skills/desktop.md § systemd-oomd):
#   - user@.service pressure kill (Fedora's systemd-oomd-defaults, Ubuntu until
#     26.10): it puts the compositor and the session bus in the candidate set.
#     Ubuntu 26.10 turned it off after 7/10 sessions died under a deterministic
#     oomd trigger (ubuntu-settings 26.10.1, LP: #2089800).
#   - -.slice swap kill: it would make system services and session.slice
#     candidates. The app.slice one above covers what users launch.
#
# The user manager registers app.slice with oomd over varlink, and oomd accepts
# it because the cgroup's owner is the sending uid (src/oom/oomd-manager.c). The
# limit and duration live on the unit, so there is no oomd.conf.d drop-in.
# 50 %/20 s are the values Fedora and Ubuntu used on user@.service.
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
      "%{install-root}%{indep-libdir}/systemd/user/app.slice.d/10-krytis-oomd.conf"
    cat > "%{install-root}%{indep-libdir}/systemd/user/app.slice.d/10-krytis-oomd.conf" <<'EOF'
    [Slice]
    ManagedOOMMemoryPressure=kill
    ManagedOOMMemoryPressureLimit=50%
    ManagedOOMMemoryPressureDurationSec=20s
    ManagedOOMSwap=kill
    EOF

  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/70-krytis-oomd.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/70-krytis-oomd.preset" <<'EOF'
    enable systemd-oomd.service
    EOF
