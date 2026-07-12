# mise-aliases: curated [tool_alias] fragment at /etc/mise/conf.d/aliases.toml.
# System-wide config is mise's lowest-precedence, alphabetically-loaded
# conf.d layer (MISE_SYSTEM_CONFIG_DIR, default /etc/mise) — confirmed against
# https://mise.jdx.dev/configuration.html. Gives users short names for
# aqua/github/pipx-backed tools without needing the full backend path. Closes #153.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/mise/conf.d/aliases.toml" <<'EOF'
    [tool_alias]
    fish = "github:fish-shell/fish-shell"
    froggit = "github:thewizardshell/froggit"
    gith = "github:a3chron/gith"
    hyfetch = "pipx:hyfetch"
    micro = "github:micro-editor/micro"
    pangolin = "github:fosrl/cli"
    tealdeer = "aqua:tealdeer-rs/tealdeer"
    EOF
