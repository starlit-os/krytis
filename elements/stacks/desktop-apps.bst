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
