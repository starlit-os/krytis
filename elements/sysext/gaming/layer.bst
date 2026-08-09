# Builds the gaming systemd-sysext delta image: two full sysroots (the
# base krytis /usr and the base+gaming /usr) are assembled, then
# files/sysext/make-layer.py diffs them and keeps only what gaming adds —
# the resulting erofs .raw is small and drops onto an already-installed
# krytis system without a reinstall. See docs/design/gaming-variant.md.
kind: manual

build-depends:
  - freedesktop-sdk.bst:components/fakecap.bst
  - freedesktop-sdk.bst:components/squashfs-tools.bst
  - freedesktop-sdk.bst:components/python3.bst
  - freedesktop-sdk.bst:components/erofs-utils.bst
  - freedesktop-sdk.bst:vm/prepare-image.bst
  - oci/krytis/init-scripts.bst
  - sysext/gaming/init-scripts.bst
  - filename: oci/krytis/filesystem.bst
    config:
      location: /sysroot
  - filename: sysext/gaming/filesystem.bst
    config:
      location: /sysroot-gaming

sources:
- kind: local
  path: files/sysext/make-layer.py

variables:
  sysroot-seed: 0c1be37a-04d0-4c81-9b20-25256ce4b25e
  strip-binaries: ''

environment:
  EROFS_OPTIONS: -z zstd --all-time -T %{filesystem-time} -E fragments,fragdedupe=inode
  EROFS_WORKERS: --workers=%{max-jobs}
  LD_PRELOAD: /usr/libexec/fakecap/fakecap.so
  FAKECAP_DB: '%{build-root}/fakecap'

environment-nocache:
- EROFS_WORKERS

config:
  build-commands:
    - mkdir fakecap
    - cp -a /sysroot sysroot
    - cp -a /sysroot-gaming sysroot-gaming
    - |
      prepare-image.sh \
        --sysroot sysroot \
        --initscripts /initial_scripts \
        --seed "%{sysroot-seed}" \
        --noroot --noboot --nodepmod >/dev/null
    - |
      prepare-image.sh \
        --sysroot sysroot-gaming \
        --initscripts /initial_scripts-gaming \
        --seed "%{sysroot-seed}" \
        --noroot --noboot --nodepmod >/dev/null

    - |
      mkdir -p sysroot-gaming/usr/lib/extension-release.d

      cat <<EOF >sysroot-gaming/usr/lib/extension-release.d/extension-release.gaming
      ID=krytis
      VERSION_ID="%{image-version}"
      EOF

    - |
      mkdir -p output
      python ./make-layer.py sysroot/usr sysroot-gaming/usr output/usr

    - |
      mkdir -p tmp

    - |
      TMPDIR='%{build-root}/tmp' \
      mkfs.erofs ${EROFS_OPTIONS} ${EROFS_WORKERS} gaming-%{systemd-arch}.raw output

  install-commands:
    - |
      mv gaming-%{systemd-arch}.raw %{install-root}
