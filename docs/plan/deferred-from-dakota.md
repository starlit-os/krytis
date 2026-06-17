# Deferred: Items to port from dakota

Reference implementations live in `dakota/elements/bluefin/` unless noted.
Zirconium-hawaii does NOT use any of these — they are dakota/Bluefin-specific choices.

## Priority: memory-safe replacements

| Element | dakota ref | Notes |
|---------|-----------|-------|
| `sudo-rs` | `bluefin/sudo-rs.bst` | Rust sudo replacement. Note `starlit/greetd.bst` has a PAM workaround that references this pattern — check when porting. |
| `uutils-coreutils` | `bluefin/uutils-coreutils.bst` | Rust coreutils. dakota intentionally keeps GNU `cp`/`mv`/`rm` due to unresolved TOCTOU issues in uutils — preserve that carve-out. |

## Build patterns to revisit from dakota

| Pattern | Notes |
|---------|-------|
| dracut bootc module unit placement | krytis works around a dracut bug (bootc module places `bootc-root-setup.service` wants symlink at initramfs root instead of under `usr/lib/systemd/system/`) by setting `systemdsystemunitdir` in dracut.conf — check if dakota handles this differently or avoids it entirely. See `elements/core/initramfs.bst`. |

## Other bluefin elements worth considering

| Element | Notes |
|---------|-------|
| `uupd.bst` | bootc update daemon. Already noted as deferred in `stacks/bootc.bst`. |
| `bootc-install-config.bst` | Install-time configuration for `bootc install`. |
| `tailscale.bst` | VPN. |
| `xdg-terminal-exec.bst` | XDG terminal execution spec — needed for "open terminal" actions in desktop environments. |
| `network.bst` | Network config drop-ins. |
| `firstboot-date.bst` / `firstboot-services.bst` | First-boot service setup. |
| `efibootmgr.bst` | EFI boot manager CLI. |
| `fzf.bst` | Fuzzy finder. |
| `tealdeer.bst` | tldr pages. |
| `motd.bst` / `umotd.bst` | Message of the day. |
