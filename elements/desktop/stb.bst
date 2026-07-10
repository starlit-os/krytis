kind: manual

# stb (github.com/nothings/stb): single-file public-domain header libraries.
# Required by noctalia since v5.0.0-beta2 (stb_image_resize2.h /
# stb_image_write.h as system headers under <stb/>); not shipped by the
# freedesktop-sdk or gnome-build-meta junctions. Upstream has no release
# tags — track the master branch head.
#
# Build-time only: headers install to /usr/include/stb/, consumed via
# build-depends by whoever needs them. Nothing ships at runtime.

# Headers only — nothing to strip, and runtime-minimal has no
# freedesktop-sdk-stripper (same pattern as desktop/falcond.bst).
variables:
  strip-binaries: ""

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
- kind: git_repo
  url: github:nothings/stb.git
  track: refs/heads/master
  ref: 31c1ad37456438565541f4919958214b6e762fb4

config:
  install-commands:
  - install -d "%{install-root}%{includedir}/stb"
  - install -m644 ./*.h "%{install-root}%{includedir}/stb/"
