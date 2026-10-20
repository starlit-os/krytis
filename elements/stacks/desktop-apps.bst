kind: stack

# Desktop applications stack.
# Pre-built binary apps installed alongside the core desktop session.
# Add new apps here rather than directly in stacks/desktop.bst.
depends:
  # ── Password manager ───────────────────────────────────────────────────────
  # Proton Pass: bundled Electron app, x86_64 only. Closes #206.
  - desktop/proton-pass.bst

  # ── Web browser ────────────────────────────────────────────────────────────
  # Zen Browser: Firefox-based, privacy/customization-focused, x86_64 + aarch64. Closes #314.
  - desktop/zen-browser.bst

  # ── Discord presence ───────────────────────────────────────────────────────
  # presence-bridge: host-side game detection reported to sandboxed (flatpak)
  # Discord clients, which cannot see host PIDs (#595). Built from source,
  # installed disabled; `mise presence-bridge:enable` opts in.
  # docs/design/presence-bridge.md.
  - desktop/presence-bridge.bst

  # ── Disk management ────────────────────────────────────────────────────────
  # GNOME Disks: partition editor / LUKS / SMART / disk-image tooling over the
  # udisks2 daemon already in the image. Local mirror of
  # gnome-build-meta.bst:core/gnome-disk-utility.bst with the
  # gnome-settings-daemon notification plug-in disabled — see the element
  # header for the measurement and the removal condition.
  - desktop/gnome-disk-utility.bst
