kind: manual

# Zig 0.17.0, for ghostty (1.4.0 declares minimum_zig_version = "0.17.0").
# Bumped by hand when ghostty-update warns that ghostty needs a newer Zig.
# falcond and seance stay on desktop/zig-0.16.bst.

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: ziglang:download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
      ref: 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
  - arch == "aarch64":
      url: ziglang:download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz
      ref: 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ""

config:
  install-commands:
  - |
    install -Dm755 zig "%{install-root}%{bindir}/zig"
    mkdir -p "%{install-root}%{libdir}/zig"
    cp -a lib/* "%{install-root}%{libdir}/zig/"
