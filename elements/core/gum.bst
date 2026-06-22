kind: manual

# Prebuilt gum binary (https://github.com/charmbracelet/gum).
# Used by system-wide enrollment scripts (fido2-tasks.bst) for interactive
# confirmations. Tarball structure: gum_<ver>_Linux_<arch>/gum — use find
# so the install command is arch-neutral.
# Pin updates via mise run gum-update / track-gum CI job.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_Linux_x86_64.tar.gz
      ref: 69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb
  - arch == "aarch64":
      url: github_files:charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_Linux_arm64.tar.gz
      ref: b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c

config:
  strip-commands:
  - ':'

  install-commands:
  - find . -maxdepth 2 -name gum -type f -exec install -Dm755 '{}' "%{install-root}%{bindir}/gum" \;
  - find . -maxdepth 3 -name gum.bash -exec install -Dm644 '{}' "%{install-root}%{sysconfdir}/bash_completion.d/gum" \;
  - find . -maxdepth 3 -name gum.fish -exec install -Dm644 '{}' "%{install-root}%{datadir}/fish/vendor_completions.d/gum.fish" \;
  - find . -maxdepth 3 -name gum.zsh  -exec install -Dm644 '{}' "%{install-root}%{datadir}/zsh/vendor-completions/_gum" \;
  - "%{install-extra}"
