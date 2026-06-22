kind: manual

sources:
- kind: tar
  url: github_files:Tech-Tac/aosp-cursors/releases/download/1.3.0/aosp-cursors-linux-1.3.0.tar.xz
  ref: d6f083bbb53672bb161006683113d46756d11a60dc42f23766a9d5e1dcd8e40c

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  strip-commands:
  - ":"
  install-commands:
  - |
    install -d "%{install-root}%{datadir}/icons/"
    cp -r aosp-cursors "%{install-root}%{datadir}/icons/"
  - "%{install-extra}"
