# Deferred: Items to port from dakota

Reference implementations live in `dakota/elements/bluefin/` unless noted — clone
dakota as a sibling of krytis's main checkout (see `docs/upstreams.yml`).
Zirconium-hawaii does NOT use any of these — they are dakota/Bluefin-specific choices.

## Memory-safe replacements — both ported, no longer deferred

| Element | krytis element | Notes |
|---------|----------------|-------|
| `sudo-rs` | `elements/core/sudo-rs.bst` | Rust sudo replacement, shipped. `elements/core/pangolin-cli.bst` documents the sudoers `Cmnd` / `Args::Prefix` matching rules sudo-rs actually supports. No PikaOS-style fallback wrapper was carried. |
| `uutils-coreutils` | `elements/core/uutils-coreutils.bst` | Rust coreutils, shipped with dakota's carve-out preserved: the element installs `uutils-<prog>` symlinks for everything but only takes over the bare `<prog>` name outside `cp`/`mv`/`rm`, which stay GNU over unresolved TOCTOU issues. |

## Build patterns to revisit from dakota

| Pattern | Notes |
|---------|-------|
| dracut bootc module unit placement | krytis works around a dracut bug (bootc module places `bootc-root-setup.service` wants symlink at initramfs root instead of under `usr/lib/systemd/system/`) by setting `systemdsystemunitdir` in dracut.conf — check if dakota handles this differently or avoids it entirely. See `elements/core/initramfs.bst`. |

## Other bluefin elements worth considering

| Element | Status in krytis | Notes |
|---------|------------------|-------|
| `uupd.bst` | **superseded** | bootc update daemon. krytis wrote its own instead: `elements/config/starlit-update.bst` (#173) updates bootc, system Flatpaks, firmware and mise tools on a daily timer, gated on AC power and an unmetered network. |
| `xdg-terminal-exec.bst` | **ported** | `elements/desktop/xdg-terminal-exec.bst`, in `stacks/desktop.bst`. |
| `efibootmgr.bst` | **ported** | `elements/core/efibootmgr.bst`. |
| `tealdeer` | **covered differently** | not a BST element — `elements/config/mise-aliases.bst` (#153) exposes it as a `[tool_alias]` so a user can `mise use tealdeer`. |
| `bootc-install-config.bst` | still deferred | Install-time configuration for `bootc install`. |
| `tailscale.bst` | still deferred | VPN. |
| `network.bst` | still deferred | Network config drop-ins. |
| `firstboot-date.bst` / `firstboot-services.bst` | **superseded** | krytis ships its own first-boot wizard instead — `files/systemd-firstboot/krytis-firstboot.service` (#487), see `docs/design/first-boot-setup.md`. |
| `fzf.bst` | still deferred | Fuzzy finder. |
| `motd.bst` / `umotd.bst` | still deferred | Message of the day. |
