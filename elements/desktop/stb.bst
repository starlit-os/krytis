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
  ref: 003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5
- kind: git_repo
  url: github:nothings/stb_image_resize.git
  track: refs/heads/main
  ref: 2768987dbd7119eb840104b7a3f96ff09d21a7b4
  directory: stb_image_resize

config:
  install-commands:
  - install -d "%{install-root}%{includedir}/stb"
  - install -m644 ./*.h "%{install-root}%{includedir}/stb/"
  - install -m644 stb_image_resize/stb_image_resize2.h "%{install-root}%{includedir}/stb/"
