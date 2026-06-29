kind: manual

# Zig 0.16.0 — used by falcond which requires minimum_zig_version = "0.16.0".
# Kept separate from zig.bst (0.15.2) to avoid breaking ghostty until it supports 0.16.

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: ziglang:download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
      ref: 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
  - arch == "aarch64":
      url: ziglang:download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz
      ref: ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  install-commands:
  - |
    install -Dm755 zig "%{install-root}%{bindir}/zig"
    mkdir -p "%{install-root}%{libdir}/zig"
    cp -a lib/* "%{install-root}%{libdir}/zig/"
