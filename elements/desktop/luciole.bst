# Luciole -- native Wayland file manager from noctalia-dev (C++23, direct
# Wayland + OpenGL ES, a static in-tree copy of Noctalia's UI library, no
# Qt/GTK). Shipped next to Nautilus for evaluation (#1649); Nautilus stays
# the default file manager.
#
# Update-path gate: upstream noctalia-dev/luciole has no tags or releases
# (checked 2026-11-17). kind: git_repo, track: refs/heads/main, same as
# desktop/umbriel.bst. Move to `track: v*` once upstream tags a release.
#
# egl/glesv2: lib/meson.build looks for `egl`, then `wayland-egl`, then
# `epoxy`, and for `glesv2`, then `epoxy`. That chain only satisfies
# pkg-config. The sources include <EGL/egl.h> / <GLES2/gl2.h> and call
# egl*/gl* directly, which libepoxy (headers under <epoxy/>, `epoxy_*`
# symbols) can't stand in for. freedesktop-sdk's libglvnd deletes
# egl.pc/glesv2.pc, so without components/mesa-headers.bst meson would
# quietly pick wayland-egl + epoxy and the compile/link would fail. With it,
# Luciole links libEGL.so.1/libGLESv2.so.2 from components/libglvnd.bst
# directly, the same result as desktop/noctalia-greeter.bst. Luciole doesn't
# use gbm or libdrm, so the prepend-mesa-env pattern isn't needed here.
#
# Codec pack: lib/meson.build only builds the UI library's codec pack
# (libjxl, libwebp, wuffs) when the consumer sets noctalia_ui_build_codecs,
# and Luciole doesn't. Image decoding goes through gdk-pixbuf's built-in
# Glycin loader (gnome-build-meta sdk/gdk-pixbuf.bst,
# -Dbuiltin_loaders='glycin') and the glycin loaders on the image. So
# libjxl/libwebp aren't dependencies here.
#
# DNS-SD discovery (optional upstream, since a8282120) needs GVfs's dnssd
# backend and a running Avahi; neither is required for WS-Discovery or SMB
# access, and krytis doesn't add them for Luciole.
#
# Runtime helpers aren't declared here because they already ship via
# stacks/desktop.bst and stacks/codecs.bst: GVfs (gvfsd-trash/-sftp/-smb/
# -dav), glib-networking, ffmpeg/ffprobe, poppler's pdftoppm/pdfinfo,
# xdg-terminal-exec. Not shipped (#1649 question 4): 7z (encrypted 7z only)
# and ffmpegthumbnailer (video filmstrips). Neither freedesktop-sdk nor
# gnome-build-meta packages them.
#
# Session integration (as of b40c963):
# - FileChooser: Luciole installs luciole.portal, and upstream
#   xdg-desktop-portal-umbriel's umbriel-portals.conf prefers it
#   (FileChooser=luciole;gtk). krytis's /etc/xdg umbriel-portals.conf
#   (config/xdg-desktop-portal-routing.bst) sets default=umbriel;gnome;gtk
#   with no FileChooser key, which shadows that, so Open/Save stays on
#   xdp-gnome. mise run portal-routing-check asserts it. Changing it is a
#   Design/Breakage Gate decision (#1649 question 3).
# - org.freedesktop.FileManager1: Nautilus keeps it. Luciole's
#   dev.noctalia.luciole.FileManager1.service claimed the same bus name as
#   Nautilus's org.freedesktop.FileManager1.service, and with two activation
#   files for one name the bus picked Luciole, so "open folder" / "show in
#   folder" opened Luciole windows. install-commands below deletes Luciole's
#   file. A Luciole window started by hand still queues for the name
#   (src/app/file_manager_service.cpp, G_BUS_NAME_OWNER_FLAGS_NONE) and holds
#   it while it runs if Nautilus isn't already the owner.
#   docs/skills/desktop.md § Two activation files for one D-Bus name.
# - inode/directory: installing Luciole doesn't change the MIME default.
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/mesa-headers.bst
# Header-only, so compile-time only (same as desktop/noctalia.bst).
# desktop/stb.bst installs stb/stb_image_resize2.h, which lib/meson.build
# checks for with has_header().
- desktop/stb.bst
- desktop/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/libglvnd.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:components/freetype.bst
- freedesktop-sdk.bst:components/fontconfig.bst
- freedesktop-sdk.bst:components/harfbuzz.bst
- freedesktop-sdk.bst:components/cairo.bst
- freedesktop-sdk.bst:components/pango.bst
- freedesktop-sdk.bst:components/glib.bst
- freedesktop-sdk.bst:components/gdk-pixbuf.bst
- gnome-build-meta.bst:sdk/libglycin.bst
- freedesktop-sdk.bst:components/librsvg.bst
- freedesktop-sdk.bst:components/libpng.bst
- freedesktop-sdk.bst:components/libarchive.bst
- freedesktop-sdk.bst:components/xz.bst
- freedesktop-sdk.bst:bootstrap/acl.bst
# libsoup-3.0 (>=3.0) and libxml-2.0 (>=2.9): hard dependency() calls since
# upstream a8282120 ("discover SMB servers without external helpers"), the
# native WS-Discovery client in src/fs/ws_discovery*.cpp. Added ahead of the
# ref bump (#1655) so the tracker's build goes green without a hand commit
# on auto/track-luciole. components/libsoup.bst resolves to gnome-build-meta's
# sdk/libsoup.bst through the junction override in elements/freedesktop-sdk.bst.
- freedesktop-sdk.bst:components/libsoup.bst
- freedesktop-sdk.bst:components/libxml2.bst
# Shared library (libtomlplusplus.so.3), so `depends` (desktop/noctalia.bst).
- freedesktop-sdk.bst:components/tomlplusplus.bst

config:
  install-commands:
    (>):
    - rm "%{install-root}%{datadir}/dbus-1/services/dev.noctalia.luciole.FileManager1.service"

variables:
  meson-local: >-
    -Dtests=disabled
    -Dnative_optimizations=false
    -Dbenchmarks=false

sources:
- kind: git_repo
  url: github:noctalia-dev/luciole.git
  track: refs/heads/main
  ref: 0b37f2cc760c241ce2cf78dbdc4744f18a5b66b7
