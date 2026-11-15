kind: manual

# stb (github.com/nothings/stb): single-file public-domain header libraries.
# Required by noctalia since v5.0.0-beta2 (stb_image_resize2.h /
# stb_image_write.h as system headers under <stb/>); not shipped by the
# freedesktop-sdk or gnome-build-meta junctions. Upstream has no release
# tags — track the branch heads.
#
# stb_image_resize2.h moved out of nothings/stb into its own repo,
# nothings/stb_image_resize, on 2026-10-19; as of stb a7d4c21 the stale 2.18b
# copy sits under deprecated/. The second source installs the maintained one
# to the same <stb/stb_image_resize2.h> path, so consumers are unchanged. The
# ./*.h glob below does not descend into deprecated/ — do not widen it, or the
# stale copy can overwrite the maintained one.
#
# Build-time only: headers install to /usr/include/stb/, consumed via
# build-depends by whoever needs them. Nothing ships at runtime.

# Headers only — nothing to strip, and runtime-minimal has no
# freedesktop-sdk-stripper (same pattern as desktop/falcond.bst).
variables:
  strip-binaries: ""

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

sources:
- kind: git_repo
  url: github:nothings/stb.git
  track: refs/heads/master
  ref: 9600522de53973336fa033a289858a4354cbb04c
- kind: git_repo
  url: github:nothings/stb_image_resize.git
  track: refs/heads/main
  ref: 703100c5f8a0b75b4861e401db567f1d82d545b8
  directory: stb_image_resize

config:
  install-commands:
  - install -d "%{install-root}%{includedir}/stb"
  - install -m644 ./*.h "%{install-root}%{includedir}/stb/"
  - install -m644 stb_image_resize/stb_image_resize2.h "%{install-root}%{includedir}/stb/"
