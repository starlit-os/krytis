kind: stack

# Self-build tooling — BST and its runtime requirements.
# Wired into the image so Krytis can build itself from within a running system.
depends:
  # ── Task runner ────────────────────────────────────────────────────────
  - core/mise.bst

  # ── BST sandbox & fetch requirements ───────────────────────────────────
  - freedesktop-sdk.bst:components/bubblewrap.bst
  - freedesktop-sdk.bst:components/fuse-overlayfs.bst
  - freedesktop-sdk.bst:components/lzip.bst
  - freedesktop-sdk.bst:components/patch.bst
  # ostree-minimal omitted: core/bootc.bst already brings in the full
  # freedesktop-sdk.bst:components/ostree.bst, which is a superset; adding
  # ostree-minimal causes non-whitelisted overlaps at oci/krytis/runtime.bst.
