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
      url: github_files:jdx/mise/releases/download/v2026.8.3/mise-v2026.8.3-linux-x64-musl
      ref: ea4b0ba4371a0d46099cdcfea48e5e0e251701d9bbdb3192210fb8fab5de438b
  - arch == "aarch64":
      url: github_files:jdx/mise/releases/download/v2026.8.3/mise-v2026.8.3-linux-arm64-musl
      ref: c3b6229e8499003795ed850e85bad65f656da5a849d3cc1e589a7aa3410c45bc

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
