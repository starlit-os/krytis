kind: pyproject

# Solaar, for the noctalia MX Control plugin (gamaraan/mx-control, #1220).
# The plugin's backend runs `python3 mxctl.py serve` with the system
# interpreter and imports Solaar's logitech_receiver and solaar packages.
# What ships here is the library, the `solaar` CLI (`solaar show`,
# `solaar config`; it imports Gtk 3 but opens no window) and the udev rule
# that tags Logitech hidraw nodes `uaccess`, so the seat user can open them
# without sudo.
#
# depends: is what that import path actually loads, not install_requires:
# python-xlib and dbus-python are imported lazily, Notify inside a `try`.
#
# gtk+-3: logitech_receiver/diversion.py calls gi.require_version("Gdk",
# "3.0") at import time, and settings_templates imports diversion. Declared
# GTK3 consumer, `floor` row in mise/tasks/gtk3-audit (Design Gate on
# #1220). A carried patch making that import optional was rejected: it saves
# no bytes while the floor apps keep GTK3 in the image. The patch, sized, and
# what it would not cover are in docs/plans/2026-09-30-gtk3-realistic-floor.md
# § Solaar: a floor consumer through GObject introspection.
build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst

depends:
- freedesktop-sdk.bst:components/python3.bst
- freedesktop-sdk.bst:components/python3-psutil.bst
- freedesktop-sdk.bst:components/python3-pyyaml.bst
- freedesktop-sdk.bst:components/python3-typing-extensions.bst
- gnome-build-meta.bst:sdk/pygobject.bst
- gnome-build-meta.bst:sdk/gtk+-3.bst
- deps/python3-evdev.bst
- deps/python3-pyudev.bst

config:
  # The GUI needs a tray backend krytis does not ship, and the plugin
  # replaces it, so drop its launcher and AppStream entry.
  install-commands:
    (>):
    - |
      rm "%{install-root}%{datadir}/applications/solaar.desktop"
      rm "%{install-root}%{datadir}/metainfo/io.github.pwr_solaar.solaar.metainfo.xml"
      rmdir "%{install-root}%{datadir}/applications" "%{install-root}%{datadir}/metainfo"

sources:
- kind: git_repo
  url: github:pwr-Solaar/Solaar.git
  track: '[0-9]*'
  exclude:
  - '*rc*'
  ref: 1.1.20-0-gb2afd88129533997eb3112fe9b8e75e6d9e2b1b4
