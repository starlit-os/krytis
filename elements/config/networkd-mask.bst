kind: manual

# krytis depends on freedesktop-sdk.bst:vm/config/networkd.bst (see
# stacks/base-system.bst) intending systemd-networkd to be the network
# manager, but NetworkManager is also present — pulled in transitively via
# stacks/desktop.bst -> gnome-build-meta.bst:core/nautilus.bst ->
# core-deps/localsearch.bst -> core-deps/NetworkManager.bst (see
# docs/skills/bst.md § NetworkManager Is Present and Running). NetworkManager
# wins ownership of every physical interface before systemd-networkd's own
# `.network` file matching ever runs — confirmed live: `networkctl status
# <iface>` reports `Network File: n/a` / `(unmanaged)` even after adding an
# explicit `Unmanaged=yes` override and a full `systemd-networkd` restart, so
# this is NetworkManager claiming the device ahead of networkd's
# matching phase, not a missing `.network` file.
#
# With zero interfaces actually managed, systemd-networkd can never consider
# any of them "online" for its own bookkeeping, so its aggregate online state
# (/run/systemd/netif/state's ONLINE_STATE=) is permanently `offline` no
# matter how healthy the real (NetworkManager-managed) connection is. Two
# confirmed real-world consequences of that permanently-wrong signal:
#
# 1. systemd-timesyncd never attempts a sync, ever — not on any network, not
#    across a manual restart, not with DNS bypassed via a literal server IP,
#    not after a forced NetworkManager reconnect. Every debug-level trace
#    shows it registering NTP servers and then doing nothing: no resolve, no
#    connect, no send. The retained journal showed zero successful syncs
#    across a month of boots on real hardware.
# 2. network-online.target hard-`Requires=` systemd-networkd-wait-online.
#    service, which can never succeed for the identical reason and always
#    runs out its ~2 minute internal timeout before failing
#    (systemd-analyze critical-chain confirms NetworkManager-wait-online.
#    service itself succeeds in ~5s, but network-online.target isn't reached
#    until 2min+ later). That target gates starlit-update.service,
#    podman-restart.service, flatpak-preinstall.service, fwupd-refresh.
#    service, and systemd-sysupdate.service on every single boot.
#
# Fix: mask both units. `disable` via a preset is not enough — a masked-only
# check would still leave systemd-networkd-wait-online.service resolvable and
# pulled in by network-online.target's static Requires=; only a real mask
# (symlink to /dev/null, same pattern as live/src/configure-live-krytis.sh's
# systemd-firstboot.service mask) makes systemd's dependency resolution treat
# it as absent rather than failed. `vm/config/networkd.bst` itself stays a
# dependency (still provides the default `.link` files' MAC/naming policy,
# which is udev-driven and independent of the daemon actually running) --
# only the two units that do nothing but produce a misleading "offline"
# signal are masked.
#
# Removal condition: if krytis ever drops NetworkManager (i.e. stops
# depending on anything that pulls it in transitively) and switches to
# systemd-networkd actually managing physical interfaces via a real
# (non-`.example`) `.network` file, delete this element and let networkd
# resume normal operation.
depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -d "%{install-root}%{sysconfdir}/systemd/system"
    ln -sf /dev/null "%{install-root}%{sysconfdir}/systemd/system/systemd-networkd.service"
    ln -sf /dev/null "%{install-root}%{sysconfdir}/systemd/system/systemd-networkd-wait-online.service"
  - "%{install-extra}"
