kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
# dconf binary needed at image assembly time for `dconf update` in
# oci/krytis/stack.bst integration-commands.
- gnome-build-meta.bst:core-deps/dconf.bst

config:
  strip-commands:
  - ":"
  install-commands:
  # dconf system database — sets defaults for GTK4 and any GSettings-aware app.
  # Per-user `gsettings set` overrides these (user-db takes priority over system-db).
  - |
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/dconf/profile/user" <<'CONF'
    user-db:user
    system-db:local
    CONF
  - |
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/dconf/db/local.d/00-defaults" <<'CONF'
    [org/gnome/desktop/interface]
    icon-theme='Papirus'
    color-scheme='prefer-dark'
    gtk-theme='adw-gtk3-dark'
    CONF
  # GTK3 settings — GTK3 has no color-scheme key; dark mode requires
  # gtk-application-prefer-dark-theme. GTK3 also reads icon-theme/gtk-theme
  # from dconf but settings.ini provides a fallback without dconf infrastructure.
  - |
    install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/gtk-3.0/settings.ini" <<'CONF'
    [Settings]
    gtk-icon-theme-name=Papirus
    gtk-theme-name=adw-gtk3-dark
    gtk-application-prefer-dark-theme=true
    CONF
  - "%{install-extra}"
