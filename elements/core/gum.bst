kind: manual

# Prebuilt gum binary (https://github.com/charmbracelet/gum).
# Used by system-wide enrollment scripts (fido2-tasks.bst) for interactive
# confirmations. BST strips the single top-level dir by default, so gum and
# completions/ land at staging root — install by direct path.
# Pin updates via mise run gum-update / track-gum CI job.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:charmbracelet/gum/releases/download/v2.0.0/gum_2.0.0_Linux_x86_64.tar.gz
      ref: c99b0005bb5b514770eea404b24c7987e08eba35bb0b2d7bc6545bb676c36861
  - arch == "aarch64":
      url: github_files:charmbracelet/gum/releases/download/v2.0.0/gum_2.0.0_Linux_arm64.tar.gz
      ref: ed51e91457a48f5681f67dd925bd40eb1794d41d1f48cf1d7e19e2517b7fac76

config:
  strip-commands:
  - ':'

  install-commands:
  - install -Dm755 gum "%{install-root}%{bindir}/gum"
  - install -Dm644 completions/gum.bash "%{install-root}%{sysconfdir}/bash_completion.d/gum"
  - install -Dm644 completions/gum.fish "%{install-root}%{datadir}/fish/vendor_completions.d/gum.fish"
  - install -Dm644 completions/gum.zsh  "%{install-root}%{datadir}/zsh/vendor-completions/_gum"
  - "%{install-extra}"
