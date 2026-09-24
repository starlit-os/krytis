kind: manual

# Prebuilt gum binary (https://github.com/charmbracelet/gum).
# Used by system-wide enrollment scripts (fido2-tasks.bst) for interactive
# confirmations. BST strips the single top-level dir by default, so gum and
# completions/ land at staging root — install by direct path.
# Pin updates via mise run gum-update / track-gum CI job.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:charmbracelet/gum/releases/download/v2.0.2/gum_2.0.2_Linux_x86_64.tar.gz
      ref: d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2
  - arch == "aarch64":
      url: github_files:charmbracelet/gum/releases/download/v2.0.2/gum_2.0.2_Linux_arm64.tar.gz
      ref: 8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5

config:
  strip-commands:
  - ':'

  install-commands:
  - install -Dm755 gum "%{install-root}%{bindir}/gum"
  - install -Dm644 completions/gum.bash "%{install-root}%{sysconfdir}/bash_completion.d/gum"
  - install -Dm644 completions/gum.fish "%{install-root}%{datadir}/fish/vendor_completions.d/gum.fish"
  - install -Dm644 completions/gum.zsh  "%{install-root}%{datadir}/zsh/vendor-completions/_gum"
  - "%{install-extra}"
