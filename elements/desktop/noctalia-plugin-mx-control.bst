kind: manual

# The noctalia MX Control plugin (gamaraan/mx-control, #1220), shipped in the
# image so krytis can carry a patch on it. noctalia normally fetches plugins at
# runtime from the `community` git source, where a patch has nowhere to go.
#
# Installs to /usr/share/noctalia/plugins/mx-control. noctalia reads it there
# through the `krytis` path source in files/noctalia-skel/settings.toml. Path
# sources are loaded in place and never written to, so a read-only /usr is
# fine. That source is listed after `community`, and a later source wins for a
# duplicate plugin id, so this copy replaces the community one. The plugin is
# still not enabled by default: it only does anything with Logitech HID++
# hardware attached.
#
# Five patches, all under patches/noctalia-plugin-mx-control/, applied in order:
# - accept-pro-device-names: the backend's device-name filter accepts
#   Logitech's PRO-series mice ("PRO X Wireless"). Without it the panel never
#   lists them, and DPI never shows.
# - tooltip-all-devices: the bar tooltip lists every device's battery, not
#   only the first online one.
# - retry-empty-settings: backport of zachwilke/omarchy-mxcontrol#16. A
#   device that links after serve's replug re-read no longer stays at
#   `settings: []` (#1292).
# - lightspeed-asleep-is-offline: on top of that backport. An asleep
#   Lightspeed device counts as offline instead of being re-read every 2 s.
# - stop-serve-by-interpreter-path: disabling the plugin actually stops its
#   serve helper (#1313).
#
# community-plugins has no tags, so this tracks main. Every commit to any
# plugin there, including the bot's "update plugin catalog" commits, moves the
# ref, so expect frequent track PRs that change nothing in mx-control/.
#
# Runtime: the backend runs `python3 mxctl.py serve` and imports Solaar.
depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/python3.bst
- desktop/solaar.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -d "%{install-root}%{datadir}/noctalia/plugins"
    cp -r mx-control "%{install-root}%{datadir}/noctalia/plugins/"

sources:
- kind: git_repo
  url: github:noctalia-dev/community-plugins.git
  track: refs/heads/main
  ref: 03414083ae64b268dbef123c7296cf5d690fa223
- kind: patch
  path: patches/noctalia-plugin-mx-control/accept-pro-device-names.patch
- kind: patch
  path: patches/noctalia-plugin-mx-control/tooltip-all-devices.patch
- kind: patch
  path: patches/noctalia-plugin-mx-control/retry-empty-settings.patch
- kind: patch
  path: patches/noctalia-plugin-mx-control/lightspeed-asleep-is-offline.patch
- kind: patch
  path: patches/noctalia-plugin-mx-control/stop-serve-by-interpreter-path.patch
