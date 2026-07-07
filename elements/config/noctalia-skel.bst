kind: manual

# Seeds /etc/skel/.local/state/noctalia/ — copied into new users' home dirs
# by useradd at account-creation time. noctalia has no /etc-level config
# fallback (unlike niri's live /etc/niri/config.kdl — see niri-config.bst),
# so this is a one-shot copy, not a synced default: it only reaches
# newly-created accounts, and once copied it no longer tracks image updates.
#
# .setup-complete is an empty marker file — its presence skips noctalia's
# first-run setup wizard. settings.toml is a partial override; noctalia
# merges missing keys against its own built-in defaults.
#
# community-palettes/*.json ships the referenced community palette locally
# so theme resolution doesn't depend on network on first login. noctalia
# names these files by percent-encoding the palette name (spaces -> %20) —
# match that exactly or the lookup misses.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -Dm644 .setup-complete "%{install-root}%{sysconfdir}/skel/.local/state/noctalia/.setup-complete"
    install -Dm644 settings.toml "%{install-root}%{sysconfdir}/skel/.local/state/noctalia/settings.toml"
    for f in community-palettes/*.json; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/skel/.local/state/noctalia/$f"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/noctalia-skel
