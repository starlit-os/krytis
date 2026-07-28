kind: stack

depends:
  - freedesktop-sdk.bst:vm/config/useradd-ostree.bst
  - freedesktop-sdk.bst:components/podman.bst
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/skopeo.bst
  - freedesktop-sdk.bst:components/systemd-ukify.bst
  - freedesktop-sdk.bst:components/sbsigntools-maybe.bst
  - freedesktop-sdk.bst:components/efitools.bst
  - core/bootc.bst
  - core/efibootmgr.bst
  - config/bootc.bst
