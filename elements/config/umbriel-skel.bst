kind: manual

# Seeds /etc/skel/.config/umbriel/config.toml -- copied into new accounts'
# home dirs by useradd --create-home and by homectl firstboot's --skel default
# (both default to /etc/skel; confirmed SKEL=/etc/skel in the shipped
# /etc/default/useradd, from freedesktop-sdk.bst:vm/config/useradd-ostree.bst).
# Same source directory as config/umbriel-config.bst, which keeps shipping
# /etc/xdg/umbriel/ as the system-wide tier-2 config -- no content is
# duplicated, both elements read from files/umbriel/.
#
# The niri counterpart is config/niri-skel.bst, and this element exists for the
# same reason (krytis#982, the Umbriel case of #490). noctalia's Umbriel theme
# template -- /usr/share/noctalia/assets/templates/umbriel/, registered in
# builtin.toml as [templates.umbriel], active when theme.templates.builtin_ids
# contains "umbriel" -- renders the live palette to
# ~/.config/umbriel/noctalia.toml and then runs apply.sh, which branches on
# whether ~/.config/umbriel/config.toml already exists:
#
#   if [ ! -f "$config_file" ]; then
#       printf '[include.optional]\n%s\n' 'files = ["noctalia.toml"]' >"$config_file"
#       exit 0
#   fi
#
# Without a seed that stub becomes the account's tier-1 config. Umbriel's
# lookup is first-match and does NOT merge across tiers, so
# /etc/xdg/umbriel/config.toml is never consulted again -- every krytis default
# (general.autostart, the whole keybind port, window rules, input) is silently
# discarded, and so is upstream's own packaged /usr/share default, because the
# /etc/xdg overlay is what included it. The session falls back to compiled-in
# defaults plus noctalia colours.
#
# With the seed present, apply.sh takes its other branch: it preserves every
# user-owned entry in the required include.files and adds its own to
# include.optional.files, which umbriel applies AFTER the required list -- so
# the precedence comes out right with no coordination between the two projects
# -- system config first, live palette overriding it. Additive, not
# destructive. (noctalia <= v5.1.0 appended to the required list instead and
# relied on last-entry-wins; v5.2.0 moved to the optional section and migrates
# the old entry out. Both orders are correct for krytis.)
#
# The v5.2.0 fix that moved noctalia's scratchpad colours to a [[window_rule]]
# also REMOVED the accidental signal that this element is missing: under
# v5.1.0 an unseeded account produced a config `umbriel config validate`
# rejected, so the breakage was at least loud. It now validates cleanly while
# silently discarding every krytis default, which is why
# mise/tasks/umbriel-config-validate asserts this file's PRESENCE and does not
# merely validate whatever is there.
#
# NOTE this is a DIFFERENT file from the tier-2 config, unlike the niri pair
# which seeds identical content at both tiers. A copy of /etc/xdg's config.toml
# would work too, but it would freeze that copy in every existing home
# directory; an include keeps the account tracking the image.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -Dm644 skel-config.toml \
      "%{install-root}%{sysconfdir}/skel/.config/umbriel/config.toml"
  - '%{install-extra}'

sources:
- kind: local
  path: files/umbriel
