# wlr-randr 0.5.0 — xrandr clone for wlroots compositors.
# Used by noctalia-greeter-session for multi-monitor output management.
# wlr-randr links only wayland-client and talks to the compositor via the
# wlr-output-management Wayland protocol; it does NOT link libwlroots.
# Upstream moved from sr.ht/~emersion to gitlab.freedesktop.org/emersion.
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
# scdoc is intentionally omitted — wlr-randr has no -Dman-pages option;
# man pages are only built if scdoc is on PATH. Omitting it skips the
# man build without changing the meson invocation.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst

variables: {}

sources:
- kind: tar
  url: freedesktop_files:emersion/wlr-randr/-/archive/v0.5.0/wlr-randr-v0.5.0.tar.gz
  ref: c566d94fddb84f801c733f1415a4ad5b75870305346363074cbdf468d4ac263a
