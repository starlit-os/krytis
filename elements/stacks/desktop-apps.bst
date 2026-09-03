kind: stack

# Desktop applications stack.
# Pre-built binary apps installed alongside the core desktop session.
# Add new apps here rather than directly in stacks/desktop.bst.
depends:
  # ── Password manager ───────────────────────────────────────────────────────
  # Proton Pass: bundled Electron app, x86_64 only. Closes #206.
  - desktop/proton-pass.bst

  # ── Code editor ────────────────────────────────────────────────────────────
  # Zed: GPU-accelerated multiplayer editor, x86_64 + aarch64. Closes #237.
  - desktop/zed.bst

  # ── Web browser ────────────────────────────────────────────────────────────
  # Zen Browser: Firefox-based, privacy/customization-focused, x86_64 + aarch64. Closes #314.
  - desktop/zen-browser.bst

  # ── Terminal ───────────────────────────────────────────────────────────────
  # Warp: agentic terminal, prebuilt .deb, x86_64 + aarch64. Closes #315.
  - desktop/warp.bst

  # ── Chat ───────────────────────────────────────────────────────────────────
  # Equibop: Discord client (Vesktop/Equicord fork), portable tarball,
  # x86_64 + aarch64. Native rather than flatpak so RPC sockets land in the
  # real $XDG_RUNTIME_DIR and game detection sees host PIDs (#591, #595).
  # Closes #609.
  - desktop/equibop.bst

  # ── Disk management ────────────────────────────────────────────────────────
  # GNOME Disks: partition editor / LUKS / SMART / disk-image tooling over the
  # udisks2 daemon already in the image. Local mirror of
  # gnome-build-meta.bst:core/gnome-disk-utility.bst with the
  # gnome-settings-daemon notification plug-in disabled — see the element
  # header for the measurement and the removal condition.
  - desktop/gnome-disk-utility.bst
