kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/polkit.bst
- freedesktop-sdk.bst:components/wireplumber.bst
- desktop/libqalculate.bst
- desktop/sdbus-cpp.bst

# Pinned to a specific commit on upstream `main` — no release tags exist on
# this repo. GitHub's archive/refs/heads/main.tar.gz regenerates on every push
# (sha256 changes with each commit), so we must pin to a full commit SHA.
# Update the commit and ref together when bumping.
# Note: repo was renamed from noctalia-shell to noctalia as of 2026.
#
# TEMPORARY FORK PIN — kitten-lily/noctalia branch
# fix/wifi-persist-polkit-async, rebased onto upstream/main and rooted there.
# Carries a fix for wifi connections never persisting to disk: NM requires
# interactive polkit authorization for new wifi connections, and the prompt
# can take well over a minute to resolve; addAndActivateAccessPoint's
# AddAndActivateConnection2 call was synchronous, so it froze the whole UI
# for the wait and its own D-Bus timeout could fire before the prompt
# resolved, meaning NM's newly-activated memory-only connection was never
# handed off to persistConnectionToDisk() and silently vanished on next NM
# restart/reboot. Fixed by dispatching the call async (matching every
# sibling activation path in that file) with a 120s reply timeout.
#
# main added a wireplumber-0.5 pkg-config requirement since this repo's
# previous pin; freedesktop-sdk.bst:components/wireplumber.bst above (also
# used by stacks/desktop.bst) already satisfies it.
#
# File upstream once confirmed fixed on real hardware, then revert this pin
# to noctalia-dev/noctalia once merged there.
sources:
- kind: tar
  url: github_files:kitten-lily/noctalia/archive/68672d6082a59527cabe1a2868a308dd5ee87a46.tar.gz
  ref: 422360ef43c692df14382d778bc139efcb98b8f08816d16e1595cdc03836928e

variables:
  meson-local: >-
    -Djemalloc=disabled
