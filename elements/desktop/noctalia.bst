kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
# stb and nlohmann-json are genuinely header-only (verified: no .so in
# either artifact) — compile-time only. tomlplusplus is NOT: fdsdk builds
# it as a shared library (libtomlplusplus.so.3, TOML_SHARED_LIB=1 in
# noctalia's own meson flags), so it belongs in `depends` below, not here.
- desktop/stb.bst
- desktop/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/polkit.bst
- freedesktop-sdk.bst:components/wireplumber.bst
- freedesktop-sdk.bst:components/tomlplusplus.bst
# libical: shared (libical.so), required by upstream meson.build:98 as of
# v5.0.0-beta.7 — same reasoning as tomlplusplus, so `depends`, not
# `build-depends`. Added after #401's ref bump landed without it and broke
# `mise build` on main (#412).
- freedesktop-sdk.bst:components/libical.bst
- freedesktop-sdk.bst:components/libsecret.bst
- desktop/libsodium.bst
- desktop/libqalculate.bst
- desktop/md4c.bst
- desktop/sdbus-cpp.bst
# gcr-4 (libgcr-4.so): shared, so `depends`. Required by the fork's
# src/dbus/secrets/secret_prompter.cpp, which links GcrSecretExchange for the
# "sx-aes-1" handshake that keeps prompted secrets off the bus in plaintext.
# NOTE: this is gcr-4 (gnome-build-meta.bst:sdk/gcr.bst), NOT the legacy
# sdk/gcr-3.bst. Verified gcr-4 does not pull in GTK, and krytis ships GTK4
# unconditionally anyway (niri.bst, ghostty.bst, nautilus) -- see PR #568.
#
# This prompter is load-bearing, not a nicety. Since #594 swapped
# gnome-keyring for oo7 (stacks/desktop.bst), gcr-3 -- and with it the legacy
# gcr-prompter binary -- is out of the image entirely, so nothing else on the
# session bus can answer org.gnome.keyring.SystemPrompter. Without noctalia
# every libsecret caller that needs an unlock hangs rather than failing, and
# oo7 has no other way to ask for a password. See docs/skills/pam.md and
# docs/design/secrets-service.md.
- gnome-build-meta.bst:sdk/gcr.bst

# Upstream is noctalia-dev/noctalia, releases tagged v*. krytis does not track
# those tags today -- see the fork pin below.
#
# History: repo was renamed from noctalia-shell to noctalia as of 2026.
# We previously pinned a kitten-lily fork commit for
# fix/wifi-persist-polkit-async (async-dispatch AddAndActivateConnection2
# so a slow polkit prompt doesn't freeze the UI and drop the memory-only
# connection before persistConnectionToDisk()). Upstream commit 18e36ede3
# ("separate VPN from physical link state, async NM calls, safe proxy
# rebinds") independently made this same call async, so that fork pin was
# dropped. Upstream's async dispatch falls back to sdbus-c++'s default
# timeout; manually verified this is not an issue in practice.
#
# FORK PIN: kitten-lily/noctalia branch feat/system-prompter. The change is not
# upstreamed (no PR opened against noctalia-dev/noctalia -- that needs an
# explicit instruction per AGENTS.md's Upstream Gate). It carries one: the
# native org.gnome.keyring.SystemPrompter provider that oo7 depends on for every
# unlock prompt, per the note above (two commits: the feature and its
# BUILDING.md dependency entry).
#
# Two carries went with the 2026-10-20 rebase onto v5.3.0, because v5.3.0
# ships upstream's own version of each:
#   - fix(lockscreen) 1047f8fd8 (resume showed the unlocked desktop). Upstream
#     c83fb9b9c (noctalia#4829) gates both lock-before-suspend and
#     lock-and-suspend on a frame callback for the first commit with no
#     desktop capture, as ours did. Unlike ours it plays the entry transition
#     first (1500 ms default, inside logind's 5 s InhibitDelayMaxSec). See
#     docs/skills/desktop.md § The last frame before sleep is what resume shows.
#   - fix(auth) 07c8bc7f9, the cherry-pick of upstream fbf410e2 (#999), which
#     v5.3.0 contains.
#
# Rebase history of the carried commit. 2026-08-17: onto upstream main
# 87b203c68 (v5.0.0-beta.8-135) -- the 1722-line feature commit applied across
# 98 upstream commits with no source conflict; the only conflict was
# documentation, upstream having moved the dependency lists out of README.md
# into BUILDING.md, so the gcr-4 package names were ported there instead.
# 2026-09-25: onto the v5.1.0 tag (54 commits), again with no source conflict;
# the BUILDING.md commit was already upstream-equivalent and `git rebase`
# dropped it as redundant. v5.0.1 -> v5.1.0 changed no `dependency()` call in
# noctalia's meson.build (39 entries either side, verified by diffing the two
# tags), so this element's build-depends/depends lists are unchanged.
# 2026-09-28: onto the v5.2.0 tag (121 commits); the fork branch moved, but no
# krytis pin ever named it. ONE conflict, in src/app/application_services.cpp:
# v5.2.0 added `installSecretServiceCollectionWatch()` immediately after
# `installSecretServiceNameWatch()`, where the fork commit had added
# `syncSecretPrompter()` plus its config-reload callback. Purely additive --
# both calls kept, upstream's watch first. v5.1.0 -> v5.2.0 changed no
# `dependency()` call (39 unique names either side, verified 2026-10-11 by
# diffing the sorted `dependency('...')` sets at the two tags).
# 2026-10-08: onto the v5.2.1 tag (69 commits). Two one-line conflicts, both
# adjacent additions beside upstream's new secret_collection_probe (meson.build
# source list, application_services.cpp include); all 17 carried files have
# byte-identical hunks (docs/skills/workflow.md § Rebasing a carried fork
# branch). v5.2.0 -> v5.2.1 adds one `dependency()`, wayland-server, inside
# meson.build's `if build_tests` block, so -Dtests=disabled below keeps the
# dependency lists unchanged. The lockscreen fix then went on top as its own
# commit, and on 2026-10-11 the fbf410e2 backport on top of that (`git
# cherry-pick -x`, clean, upstream author kept).
# 2026-10-20: the two prompter commits alone onto the v5.3.0 tag (156 commits),
# with no conflict; all 17 carried files have byte-identical hunks. The
# lockscreen fix and the fbf410e2 backport were left off (see above), and the
# v5.3.0 tag was pushed to the fork. v5.2.1 -> v5.3.0 changes no
# `dependency()` call (sorted sets at the two tags are identical).
#
# Rebase the branch onto the new tag and re-track when upstream cuts a
# release: `track: <branch>` cannot see tags, so no auto-track PR will ever
# offer the release. See docs/skills/desktop.md.
#
# Revert to
#   url: github:noctalia-dev/noctalia.git
#   track: v*
# once the prompter lands upstream (or is dropped). Tracking a branch instead
# of the v* tag glob means `bst source track` follows the branch head, not
# releases -- expect more frequent auto-track PRs than usual until then, and
# note that an unrelated commit on that branch changes what krytis ships.
sources:
- kind: git_repo
  url: github:kitten-lily/noctalia.git
  track: feat/system-prompter
  ref: v5.3.0-2-g1aab2f2f829f7ffae1658a51f87b00c981c959d5
# launch_apps_as_systemd_services defaults to true (upstream: false). With
# false, every app started from the launcher, dock or taskbar is a child of
# noctalia and lives in its cgroup. config/noctalia-service.bst runs noctalia
# in session.slice, so those apps would leave systemd-oomd's reach
# (config/oomd.bst arms app.slice only) and die whenever noctalia restarts.
# A struct default, not a settings.toml seed: /etc/skel only reaches new
# accounts, and the schema loader keeps the struct default for a missing key.
# An explicit `false` in a user's settings.toml still wins (#1253).
- kind: patch
  path: patches/noctalia/launch-apps-as-systemd-services-by-default.patch

variables:
  # tests=disabled: noctalia's meson.build enables `tests: auto` unit test
  # binaries for debug buildtypes (freedesktop-sdk's default). One of them,
  # input_password_mode_test, fails to link against v5.0.0-beta.3 — its
  # meson.build sources list is missing theme/fixed_palette.cpp,
  # theme/contrast.cpp and render/core/color.cpp (undefined reference to
  # expandFixedPalettes/applyTerminalPalette/relativeLuminance). We don't
  # ship or run these test binaries, so disable the option rather than
  # patch upstream's meson.build.
  meson-local: >-
    -Djemalloc=disabled -Dtests=disabled
