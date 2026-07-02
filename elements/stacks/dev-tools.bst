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

  # ── ISO build (mise run build-iso → dakota-iso iso-sd-boot) ─────────────
  # Host-side tools for squashfs assembly and the systemd-boot ESP image.
  # podman + skopeo are already pulled by stacks/bootc.bst — listing them
  # here would trip the `overlaps` fatal-warning. buildah and xorriso have
  # no freedesktop-sdk component; those steps run through a podman build-
  # tools container instead (see docs/skills/mise.md § ISO build task).
  - freedesktop-sdk.bst:components/squashfs-tools.bst
  - freedesktop-sdk.bst:components/mtools.bst
  - freedesktop-sdk.bst:components/dosfstools.bst
  - freedesktop-sdk.bst:components/rsync.bst
