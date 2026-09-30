kind: manual

# Prebuilt static binary release of mise (https://mise.jdx.dev/).
# Vendors the upstream prebuilt binary — no C/Rust build needed.
# Uses the musl variant so the binary is self-contained: install-commands
# below execute it inside the BST sandbox, and a static build has no
# linkage surface there. (Note: "glibc skew across upgrades" is NOT the
# reason — mise ships in the same atomic image as its glibc, so they can
# never diverge.) Cost: a static binary bypasses glibc NSS entirely and
# parses /etc/resolv.conf itself, so a missing/stale resolv.conf breaks
# mise while every other tool keeps working. See docs/skills/mise.md
# § The shipped `mise` is musl-static.
# Pin updates via .github/workflows/track-bst-sources.yml (manual-merge).
sources:
- kind: remote
  filename: mise
  (?):
  - arch == "x86_64":
      url: github_files:jdx/mise/releases/download/v2026.9.17/mise-v2026.9.17-linux-x64-musl
      ref: 68274f0265e25a9dd472468fbfddac15bc6d6cd51e8dff4e82405142e09a2a56
  - arch == "aarch64":
      url: github_files:jdx/mise/releases/download/v2026.9.17/mise-v2026.9.17-linux-arm64-musl
      ref: 1d7c8f78792635cd227edfebfe36868dfdc9b0a9190a4d3435fdf24f3fa052c4

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

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
    install -Dm644 /dev/null "%{install-root}%{sysconfdir}/profile.d/mise.sh"
    cat > "%{install-root}%{sysconfdir}/profile.d/mise.sh" <<'EOF'
    command -v mise >/dev/null 2>&1 || return 0
    eval "$(mise activate bash)"
    EOF
  - |
    install -Dm644 /dev/null "%{install-root}%{sysconfdir}/profile.d/mise.zsh"
    cat > "%{install-root}%{sysconfdir}/profile.d/mise.zsh" <<'EOF'
    command -v mise >/dev/null 2>&1 || return 0
    eval "$(mise activate zsh)"
    EOF
  - |
    install -Dm644 /dev/null "%{install-root}%{datadir}/fish/vendor_conf.d/01-mise.fish"
    cat > "%{install-root}%{datadir}/fish/vendor_conf.d/01-mise.fish" <<'EOF'
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
