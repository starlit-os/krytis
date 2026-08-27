kind: meson

# freedesktop-sdk's components/libdisplay-info.bst, held one release back at
# 0.3.0 — used to override components/libdisplay-info.bst in the
# freedesktop-sdk junction (see elements/freedesktop-sdk.bst overrides).
#
# Byte-identical to upstream's element apart from `ref:`. fdsdk 26.08 moved to
# 0.4.0 (released 2026-07-23); this pins the 0.3.0 that fdsdk 25.08.16 shipped
# and that `main` still builds against today.
#
# Why: niri vendors `libdisplay-info-sys 0.3.0`, whose system-deps metadata
# declares `version = ">= 0.1.0, < 0.4.0"`. pkg-config rejects 0.4.0 outright
# and desktop/niri.bst fails to build (#305).
#
# There is no update path out of this. niri v26.04 is upstream's newest
# release, and libdisplay-info-sys tops out at 0.3.0 on crates.io — the Rust
# side is behind the C library, not krytis.
#
# The version bound is NOT pre-1.0 caution, so do not "just relax it". The
# crate ships hand-written per-version binding modules (src/v0_1, src/v0_2,
# src/v0_3) and runs no bindgen; build.rs probes the installed version and
# picks a module. There is no v0_4 module, so widening the bound to < 0.5.0
# would select the v0_3 bindings against a 0.4 library — and 0.4.0 removed
# `established_timings_iii[]` and `established_timings_iii_len` from
# `struct di_edid_*` in include/edid.h. Wrong struct offsets inside the
# compositor's EDID parsing, with no build error to warn anyone. Verified
# against the 0.3.0 -> 0.4.0 header diff, not assumed.
#
# Blast radius is two elements, both krytis's own: desktop/niri.bst and
# desktop/wlroots.bst are the only consumers in the whole 892-element graph,
# and both build against 0.3.0 on main right now. This restores a known-good
# combination rather than inventing one.
#
# Update path: deliberately NOT in the track-bst-sources.yml matrix. The
# `track: '*.*.*'` glob below is kept only for fidelity with upstream's
# element — running `bst source track` on it would fetch 0.4.0 and reintroduce
# the exact breakage this exists to avoid. Checked by
# `mise run libdisplay-info-check`, which watches for the exit condition
# rather than for drift.
#
# Delete this element and the overrides entry once libdisplay-info-rs ships a
# v0_4 binding module and niri picks it up. The check task fails when that
# lands, so nobody has to remember.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/hwdata.bst

public:
  bst:
    split-rules:
      devel:
        (>):
        - '%{bindir}/di-edid-decode'
        - '%{libdir}/libdisplay-info.so'

sources:
- kind: git_repo
  track: '*.*.*'
  url: freedesktop:emersion/libdisplay-info.git
  ref: 0.3.0-0-g47a5590e9c4eb35d67651b8c05a55f1a48259329
