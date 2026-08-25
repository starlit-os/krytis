kind: stack

depends:
  - freedesktop-sdk.bst:vm/config/useradd-ostree.bst
  - freedesktop-sdk.bst:components/podman.bst
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/skopeo.bst
  - freedesktop-sdk.bst:components/systemd-ukify.bst
  - freedesktop-sdk.bst:components/sbsigntools-maybe.bst
  # efitools' sign-efi-sig-list, for the Containerfile's SEAL_SECURE_BOOT
  # stage. Vendored: fdsdk deleted its EFI element family in 26.08. See
  # elements/core/efitools.bst.
  - core/efitools.bst
  - core/bootc.bst
  - core/efibootmgr.bst
  - config/bootc.bst
  - config/secureboot-loader-conf.bst
