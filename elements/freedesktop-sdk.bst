kind: junction

sources:
- kind: git_repo
  url: gitlab:freedesktop-sdk/freedesktop-sdk.git
  track: freedesktop-sdk-26.08*
  ref: freedesktop-sdk-26.08.2-0-g32c5fea70e827885fc805d38a9dc5716c39ed173

config:
  options:
    target_arch: '%{arch}'
    (?):
    - x86_64_v3:
        x86_64_v3: true
    - arch == 'x86_64':
        bootstrap_build_arch: 'x86_64'
    - arch == 'aarch64':
        bootstrap_build_arch: 'aarch64'

  overrides:
    components/at-spi2-core.bst: gnome-build-meta.bst:sdk/at-spi2-core.bst
    components/cairo.bst: gnome-build-meta.bst:sdk/cairo.bst
    components/fcitx5-gtk.bst: gnome-build-meta.bst:sdk/fcitx5-gtk.bst
    components/gcab.bst: gnome-build-meta.bst:sdk/gcab.bst
    components/gdk-pixbuf.bst: gnome-build-meta.bst:sdk/gdk-pixbuf.bst
    components/glib-networking.bst: gnome-build-meta.bst:sdk/glib-networking.bst
    components/glib.bst: gnome-build-meta.bst:sdk/glib.bst
    components/gobject-introspection.bst: gnome-build-meta.bst:sdk/gobject-introspection.bst
    components/python3-gi-docgen.bst: gnome-build-meta.bst:sdk/gi-docgen.bst
    components/graphene.bst: gnome-build-meta.bst:sdk/graphene.bst
    components/gsettings-desktop-schemas.bst: gnome-build-meta.bst:sdk/gsettings-desktop-schemas.bst
    components/gtk3.bst: gnome-build-meta.bst:sdk/gtk+-3.bst
    components/libibus.bst: gnome-build-meta.bst:sdk/libibus.bst
    components/json-glib.bst: gnome-build-meta.bst:sdk/json-glib.bst
    components/libnotify.bst: gnome-build-meta.bst:sdk/libnotify.bst
    components/librsvg.bst: gnome-build-meta.bst:sdk/librsvg.bst
    components/libsoup.bst: gnome-build-meta.bst:sdk/libsoup.bst
    components/pango.bst: gnome-build-meta.bst:sdk/pango.bst
    components/pygobject.bst: gnome-build-meta.bst:sdk/pygobject.bst
    components/vala.bst: gnome-build-meta.bst:sdk/vala.bst
    components/libsecret.bst: gnome-build-meta.bst:sdk/libsecret.bst
    components/zenity.bst: gnome-build-meta.bst:void/zenity.bst
    components/linux-module-cert.bst: gnome-build-meta.bst:gnomeos/linux-module-cert.bst
    # Load-bearing, not a leftover: gnome-build-meta's systemd/systemd-libs
    # filters read freedesktop-sdk.bst:components/_private/systemd-base.bst, and
    # without this line that is fdsdk's own build (v261.2 at 26.08.2, which
    # still fails systemd-update-utmp.service on every boot, #417).
    # gnome-build-meta pins v261.3, the first release carrying the fix.
    components/_private/systemd-base.bst: gnome-build-meta.bst:core-deps/systemd-base.bst
    components/systemd.bst: gnome-build-meta.bst:core-deps/systemd.bst
    components/systemd-ukify.bst: gnome-build-meta.bst:core-deps/systemd-ukify.bst
    components/systemd-libs.bst: gnome-build-meta.bst:core-deps/systemd-libs.bst
    components/frei0r.bst: overrides/frei0r.bst
    components/vim.bst: overrides/vim.bst
    components/sudo.bst: core/sudo-rs.bst
    components/rust-bindgen.bst: overrides/rust-bindgen.bst
    # GTK3-free libdecor (#1075, #641 step 5a): drops components/gtk3.bst and the
    # libdecor-gtk.so plugin; libdecor-cairo.so stays as the fallback. Drift and exit
    # condition: `mise run gtk3-mirror-check`.
    components/libdecor.bst: overrides/libdecor.bst
    # Held at 0.3.0: niri's vendored libdisplay-info-sys caps at < 0.4.0 and
    # has no v0_4 bindings. Only niri and wlroots consume it.
    components/libdisplay-info.bst: overrides/libdisplay-info.bst
    components/openssh.bst: core/openssh.bst
    extensions/mesa/mesa.bst: desktop/mesa-all-codecs.bst
