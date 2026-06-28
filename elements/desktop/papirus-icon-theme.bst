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
  ref: 20250501-0-g863243822aa6693d4eb3758fd6444690d365c695
