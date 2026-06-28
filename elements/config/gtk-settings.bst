kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

config:
  strip-commands:
  - ":"
  install-commands:
  - |
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/gtk-3.0/settings.ini" <<'CONF'
    [Settings]
    gtk-icon-theme-name=Papirus
    CONF
  - |
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/gtk-4.0/settings.ini" <<'CONF'
    [Settings]
    gtk-icon-theme-name=Papirus
    CONF
  - "%{install-extra}"
