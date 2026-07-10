kind: manual

# Prebuilt static binary release of mise (https://mise.jdx.dev/).
# Vendors the upstream prebuilt binary — no C/Rust build needed.
# Uses the musl variant to avoid glibc version mismatches across
# distro upgrades (bootc images must run on a stable userspace).
# Pin updates via .github/workflows/track-bst-sources.yml (manual-merge).
sources:
- kind: remote
  filename: mise
  (?):
  - arch == "x86_64":
      url: github_files:jdx/mise/releases/download/v2026.7.5/mise-v2026.7.5-linux-x64-musl
      ref: cddf6d610f40a6e3c3e5a59e860b9e72e46b159ad254b9bda95e007ba32fbb28
  - arch == "aarch64":
      url: github_files:jdx/mise/releases/download/v2026.7.5/mise-v2026.7.5-linux-arm64-musl
      ref: 506468cdff7cb5b6698b0f765ed6a817fca7340fa1c595457977e733fcb314a4

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  install-commands:
  - install -Dm755 -t "%{install-root}%{bindir}" mise
  - |
    # Shell activation snippets. /etc/profile.d/<tool>.sh is sourced by
    # bash on login (and by zsh via /etc/zsh/zprofile by default).
    # /usr/share/fish/vendor_conf.d/<tool>.fish is auto-loaded by fish
    # for all users without touching $XDG_CONFIG_HOME.
    # The command -v guard ensures a missing or broken mise binary does
    # not break interactive shells.
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/profile.d/mise.sh" <<'EOF'
    command -v mise >/dev/null 2>&1 || return 0
    eval "$(mise activate bash)"
    EOF
  - |
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/profile.d/mise.zsh" <<'EOF'
    command -v mise >/dev/null 2>&1 || return 0
    eval "$(mise activate zsh)"
    EOF
  - |
    install -Dm644 /dev/stdin "%{install-root}%{datadir}/fish/vendor_conf.d/01-mise.fish" <<'EOF'
    if status is-interactive
      command -v mise >/dev/null 2>&1 && mise activate fish | source
    else
      command -v mise >/dev/null 2>&1 && mise activate fish --shims | source
    end
    EOF
  - |
    # Fish completions. mise is a musl static binary so it runs in the BST
    # sandbox during install. vendor_completions.d is auto-loaded by fish for
    # all users without touching $XDG_CONFIG_HOME.
    chmod +x mise
    mkdir -p "%{install-root}%{datadir}/fish/vendor_completions.d"
    ./mise completions fish > "%{install-root}%{datadir}/fish/vendor_completions.d/mise.fish"
  - "%{install-extra}"
