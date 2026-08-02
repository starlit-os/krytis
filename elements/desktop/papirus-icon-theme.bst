kind: make

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  strip-commands:
  - ":"
  build-commands: []
  install-commands:
  - 'make install DESTDIR="%{install-root}" PREFIX="%{prefix}"'
  - "%{install-extra}"

sources:
- kind: git_repo
  url: github:PapirusDevelopmentTeam/papirus-icon-theme.git
  track: refs/tags/*
  ref: 20260801-0-g5f8b701d7521e27b4859d7e4f9b0da4c423c036c
