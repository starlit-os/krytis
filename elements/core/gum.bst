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
      url: github_files:charmbracelet/gum/releases/download/v2.0.1/gum_2.0.1_Linux_x86_64.tar.gz
      ref: 4dfe4547f960813864c803b3617aa64427fa32ca566707fde949e08975297c48
  - arch == "aarch64":
      url: github_files:charmbracelet/gum/releases/download/v2.0.1/gum_2.0.1_Linux_arm64.tar.gz
      ref: 6998202a8fea27bb2007f69e44ec5dcb4cff5268c62d995de857eee0e2cd52cb

config:
  strip-commands:
  - ':'

  install-commands:
  - install -Dm755 gum "%{install-root}%{bindir}/gum"
  - install -Dm644 completions/gum.bash "%{install-root}%{sysconfdir}/bash_completion.d/gum"
  - install -Dm644 completions/gum.fish "%{install-root}%{datadir}/fish/vendor_completions.d/gum.fish"
  - install -Dm644 completions/gum.zsh  "%{install-root}%{datadir}/zsh/vendor-completions/_gum"
  - "%{install-extra}"
