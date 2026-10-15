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
# The patch makes the backend's device-name filter accept Logitech's PRO-series
# mice ("PRO X Wireless"). Without it the panel never lists them, and DPI never
# shows. See patches/noctalia-plugin-mx-control/accept-pro-device-names.patch.
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
  ref: bd834815ee5da2ed744a9cbf1425342a4eecba6f
- kind: patch
  path: patches/noctalia-plugin-mx-control/accept-pro-device-names.patch
