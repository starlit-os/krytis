# Package ananicy-cpp (#222)

Parent: #101 (Explore userspace performance services — closed/completed).

## Goal

Add `ananicy-cpp` — the C++ rewrite of Ananicy, an auto nice/ionice/sched-class daemon
that reprioritizes known process classes (browsers, compilers, background daemons) —
plus the CachyOS community rule set, as new BST elements, wired into
`elements/stacks/desktop.bst`. Complementary to `desktop/falcond.bst` (falcond handles
active *game* sessions; ananicy-cpp handles everyday process classes system-wide, and
has no daemon-level overlap — falcond does not touch nice/ionice for non-game
processes).

## Upstream facts (verified this session)

- **Binary**: `https://gitlab.com/ananicy-cpp/ananicy-cpp` (GPL-3.0-or-later, CMake,
  C++20). *Not* GitHub — the AUR `ananicy-cpp` package (maintainer Antoine Viallon)
  points here. Latest tag `v1.2.0` (2026-03-26,
  `7117eaf278082bdbb8e25d94c4f7a141afeb1ae4`) — AUR is stale on `v1.1.1`; use `v1.2.0`.
  krytis's `gitlab:` alias (`include/aliases.yml`) already covers this host for
  `kind: git_repo`.
- **Rules**: `https://github.com/CachyOS/ananicy-rules` (GPL-3.0-or-later). Bare-numeric
  tags (`1.1.49`, no `v` prefix), real GitHub releases — unlike
  `PikaOS-Linux/falcond-profiles` (no releases, forced a bespoke commit-SHA tracker),
  this one tracks cleanly with a plain `track: '*.*.*'` glob.
- **Build deps** (from `CMakeLists.txt` + AUR `PKGBUILD`, both read this session):
  `nlohmann_json` 3.9+, `fmt` 8.0+, `spdlog` 1.9+, all fetchable via CPM
  (`cmake/CPM.cmake`, vendored in-tree — no network needed) *or* via
  `find_package()` when `USE_EXTERNAL_*=ON` is passed. krytis must pass all three
  `USE_EXTERNAL_*=ON` — the sandbox has no network at build time.
  - `nlohmann_json` → already vendored as `desktop/nlohmann-json.bst` (fdsdk dropped it
    in 26.08). Reuse as-is, `build-depends` only (header-only, same classification as
    its noctalia usage).
  - `fmt` → fdsdk ships this as `freedesktop-sdk.bst:components/fmtlib.bst` (added
    25.08.0; **note the component is named `fmtlib.bst`, not `fmt.bst`**), builds
    `libfmt.so` — real runtime `.so`, so `depends`, not `build-depends` (same trap
    documented in `docs/skills/bst.md` for `tomlplusplus`).
  - `spdlog` → **not shipped by fdsdk at all** (confirmed: paged the full
    `elements/components/` tree via the GitLab API, alphabetically absent between
    `swig.bst` and `systemd-hwdb-maybe.bst`). Needs a new krytis-vendored element,
    same pattern as `nlohmann-json.bst`/`stb.bst`.
- **systemd**: `ENABLE_SYSTEMD=ON` links `libsystemd` and installs
  `ananicy-cpp.service` via `cmake --install` (no manual `install -Dm644` needed,
  unlike falcond's zig build which didn't install its unit). Use
  `freedesktop-sdk.bst:components/systemd.bst` exactly as `desktop/sdbus-cpp.bst`
  already does (`build-depends` + `depends`, `.pc` + `.so` both present).
- **Process-detection backend — decision: netlink, not BPF.** ananicy-cpp supports two
  mutually exclusive backends selected by `-DUSE_BPF_PROC_IMPL`:
  - **BPF** (what the AUR `PKGBUILD` uses): `libananicycpp_bpf/CMakeLists.txt` pulls
    `libbpf` via CPM (network fetch, even with `BPF_BUILD_LIBBPF=OFF` the surrounding
    `include(CPM)` / `FindBpfObject.cmake` machinery still needs auditing), compiles a
    BPF C skeleton with `clang -target bpf` against a per-arch vendored `vmlinux.h`,
    and optionally shells out to `bpftool`. Substantially heavier build graph than
    anything else in `desktop/`.
  - **netlink** (the default when `USE_BPF_PROC_IMPL` is simply omitted): a plain
    `libananicycpp_netlink/` static lib using the kernel's `NETLINK_CONNECTOR` proc
    socket. Zero extra build deps beyond what's already needed for the main binary.
    Functionally complete — every checklist item in upstream's README ("What works")
    is backend-agnostic.
  - Pick netlink: boring, no new libbpf/clang/CO-RE surface to maintain, no CPM
    network-fetch path to audit shut. Record this as the deliberate choice (not an
    oversight) in the element's header comment, same way `scx-scheds.bst` records its
    version pin rationale.
- **Config paths are hardcoded, not discoverable at runtime**: `src/main.cpp` defaults
  to `/etc/ananicy.d` (`ANANICY_CPP_CONFDIR` env var override) and
  `/etc/ananicy.d/ananicy.conf` (`ANANICY_CPP_CONF` override). `src/config.cpp`
  **writes** a generated default `ananicy.conf` to `ANANICY_CPP_CONF` if it doesn't
  exist yet — that path must be runtime-writable. `src/rules.cpp` only **reads** from
  `ANANICY_CPP_CONFDIR` (confirmed via grep — no write calls) — that path can be
  read-only `/usr/share`. This is exactly the falcond split (`/usr/share/falcond`
  read-only system content vs `/var/lib/falcond` writable state), not the "ship into
  `/etc`" pattern — override both env vars in the installed unit:
  - `ANANICY_CPP_CONFDIR=/usr/share/ananicy.d` (baked-in CachyOS rules, read-only)
  - `ANANICY_CPP_CONF=/var/lib/ananicy-cpp/ananicy.conf` (auto-generated on first
    boot, `tmpfiles.d` creates the state dir)
  - Do **not** vendor CachyOS's own `ananicy.conf` (global settings tuning, distinct
    from the process rules) — let the binary generate krytis's own default on first
    boot rather than silently adopting CachyOS-specific global tuning decisions.

## New files

### `elements/desktop/spdlog.bst` (new)

```yaml
kind: cmake

# spdlog: fast C++ logging library, required by desktop/ananicy-cpp.bst. Not shipped
# by freedesktop-sdk (confirmed absent from the full elements/components/ tree, both
# 25.08.0 and master, via the GitLab API — alphabetically it isn't there between
# swig.bst and systemd-hwdb-maybe.bst). Vendored here with the same
# find_package-friendly shared-lib config nlohmann-json.bst and stb.bst use for other
# fdsdk gaps. Built against fdsdk's fmtlib.bst (SPDLOG_FMT_EXTERNAL=ON) rather than
# spdlog's own bundled fmt fork, so there is exactly one fmt runtime in the image.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/fmtlib.bst

variables:
  cmake-local: >-
    -DSPDLOG_BUILD_SHARED=ON
    -DSPDLOG_FMT_EXTERNAL=ON
    -DSPDLOG_INSTALL=ON
    -DSPDLOG_BUILD_EXAMPLE=OFF
    -DSPDLOG_BUILD_TESTS=OFF

sources:
- kind: git_repo
  url: github:gabime/spdlog.git
  track: v*
  ref: <resolved by `mise bst source track desktop/spdlog.bst`>
```

### `elements/desktop/ananicy-cpp.bst` (new)

```yaml
kind: cmake

# ananicy-cpp: C++ rewrite of Ananicy — automatic nice/ionice/sched-class/oom_score_adj
# rules for known process classes (browsers, compilers, background daemons).
# Complementary to desktop/falcond.bst: falcond only acts during an active game session
# (org.scx.Loader scheduler swap, 3D VCache, DMEM GPU protection); ananicy-cpp is
# always-on, general process classification and has no daemon-level overlap. Closes #222.
#
# Process-detection backend is netlink, not BPF (USE_BPF_PROC_IMPL left unset —
# undefined CMake cache vars are falsy, this is upstream's own non-BPF default path).
# The BPF backend (libananicycpp_bpf/) needs its own libbpf CPM fetch, a per-arch
# vendored vmlinux.h, and clang -target bpf skeleton compilation — heavier than
# anything else in desktop/ for a feature-parity-only change (upstream's own "What
# works" checklist doesn't distinguish by backend). Netlink needs no extra deps beyond
# what the main binary already pulls in.
#
# Source: https://gitlab.com/ananicy-cpp/ananicy-cpp — not GitHub; the AUR ananicy-cpp
# package (maintainer: Antoine Viallon) points here. AUR is stale on v1.1.1 as of this
# writing; krytis tracks v1.2.0+ directly upstream.
#
# Rules: https://github.com/CachyOS/ananicy-rules — CachyOS's community rule set,
# vendored the same way desktop/falcond.bst vendors PikaOS-Linux/falcond-profiles, but
# tracked with a plain tag glob (real GitHub releases, unlike falcond-profiles) so no
# bespoke mise task is needed for it.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- desktop/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/fmtlib.bst
- desktop/spdlog.bst

variables:
  cmake-local: >-
    -DUSE_EXTERNAL_JSON=ON
    -DUSE_EXTERNAL_FMTLIB=ON
    -DUSE_EXTERNAL_SPDLOG=ON
    -DENABLE_SYSTEMD=ON
    -DSTATIC=OFF

sources:
- kind: git_repo
  url: gitlab:ananicy-cpp/ananicy-cpp.git
  track: v*
  ref: <resolved by `mise bst source track desktop/ananicy-cpp.bst`, expect v1.2.0-0-g7117eaf278082bdbb8e25d94c4f7a141afeb1ae4>

# CachyOS's community rules. No GitHub Releases quirk here (unlike falcond-profiles) —
# real tags, so this element's own `bst source track` call keeps both sources current
# in one PR; no second mise task.
- kind: git_repo
  url: github:CachyOS/ananicy-rules.git
  track: '*.*.*'
  ref: <resolved by `mise bst source track desktop/ananicy-cpp.bst`, expect 1.1.49-0-g03ef03fbf7e834385377432ccecaedd32e3414bb>
  directory: ananicy-rules-src

config:
  install-commands:
  - |
    # Default confdir must be read-only /usr/share content (bootc), not /etc — override
    # the compiled-in /etc/ananicy.d default via the shipped unit's Environment=, same
    # split as desktop/falcond.bst's /usr/share (read-only) + /var/lib (writable) split.
    sed -i '/^\[Service\]/a Environment=ANANICY_CPP_CONFDIR=%{datadir}/ananicy.d\nEnvironment=ANANICY_CPP_CONF=/var/lib/ananicy-cpp/ananicy.conf' \
      "%{install-root}%{indep-libdir}/systemd/system/ananicy-cpp.service"

  - |
    # CachyOS rule set — rules.cpp only ever reads from CONFDIR (verified: no write
    # calls in src/rules.cpp), safe to bake in as read-only image content.
    install -d "%{install-root}%{datadir}/ananicy.d"
    install -Dm644 ananicy-rules-src/00-cgroups.cgroups ananicy-rules-src/00-types.types \
      "%{install-root}%{datadir}/ananicy.d/"
    cp -r ananicy-rules-src/00-default "%{install-root}%{datadir}/ananicy.d/"

  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-ananicy-cpp.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-ananicy-cpp.preset" <<'EOF'
    enable ananicy-cpp.service
    EOF

  - |
    # Writable state dir: config.cpp writes a generated default ananicy.conf here on
    # first boot if ANANICY_CPP_CONF doesn't exist yet.
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/tmpfiles.d/ananicy-cpp.conf"
    cat > "%{install-root}%{indep-libdir}/tmpfiles.d/ananicy-cpp.conf" <<'EOF'
    d /var/lib/ananicy-cpp 0755 root root -
    EOF
  - '%{install-extra}'
```

Notes for whoever implements this:

- The two `ref:` placeholders **must** be resolved with a real `mise bst source track
  desktop/ananicy-cpp.bst` run (and `desktop/spdlog.bst` for its own), not hand-typed —
  don't guess the `git describe` suffix format.
- `cmake-global`'s BuildStream-plugin default already carries `-DCMAKE_BUILD_TYPE`
  (sibling `kind: cmake` elements `fmtlib.bst`, `sdbus-cpp.bst`, `nlohmann-json.bst`
  don't override it either) — this is *not* the meson `debugoptimized` gap documented
  in `docs/skills/bst.md`; no project.conf `elements: cmake:` block exists or is
  needed. Confirm with `bst show --format '%{environment}'` if in doubt before adding
  one.
- Double-check `find_package(fmt CONFIG REQUIRED)` (from spdlog's own CMakeLists)
  actually resolves against `fmtlib.bst`'s installed `FmtConfig.cmake` inside the BST
  sandbox before assuming it Just Works — this is the one link in the chain not
  directly verified this session (read the recipe, not a live build).

## `elements/stacks/desktop.bst`

Add next to the `falcond`/`scx-loader` block, cross-referencing the "complementary,
not overlapping" relationship documented in the element header:

```yaml
  # ananicy-cpp: always-on process-class nice/ionice/sched rules (browsers, compilers,
  # background daemons). Complementary to falcond (falcond only acts during an active
  # game session) — no daemon-level overlap. Ships the CachyOS community rule set.
  # Closes #222.
  - desktop/ananicy-cpp.bst
```

## `.github/workflows/track-bst-sources.yml`

Both new elements are plain `git_repo`+`track:` — no Cloudflare/no-releases quirks like
falcond/falcond-profiles hit, so both fit the **existing shared matrix job** (the one
whose `matrix.include` list already carries `nlohmann-json`, `kmscon`, `libtsm`, etc. —
read this session at lines ~836-1000) rather than needing bespoke jobs:

```yaml
          - group: ananicy-cpp
            element: desktop/ananicy-cpp.bst
            branch: auto/track-ananicy-cpp
            title: "chore(deps): update ananicy-cpp"
          - group: spdlog
            element: desktop/spdlog.bst
            branch: auto/track-spdlog
            title: "chore(deps): update spdlog"
```

Also add `ananicy-cpp` and `spdlog` to the `workflow_dispatch.inputs.group.options`
list near the top of the file (satisfies AGENTS.md's Update Path Gate option (a) — no
new mise task needed).

## `docs/skills/bst.md`

Add a `## ananicy-cpp (process-class nice/ionice daemon)` section near the existing
`## falcond (PikaOS gaming performance daemon)` section, covering (per the
self-improvement-loop mandate — must land in the same commit as the element, not a
follow-up):

- The `fmtlib.bst` vs `fmt.bst` naming trap (component is literally named
  `fmtlib.bst` in fdsdk — easy to grep for the wrong name and conclude fmt isn't
  shipped).
- spdlog absent from fdsdk entirely — where this was verified (paginated the full
  `elements/components/` tree via the GitLab API rather than trusting web search,
  which came up empty/unreliable for this specific file).
- The netlink-vs-BPF decision and why (link back to this plan once archived).
- The CONFDIR/CONF env-var override technique, generalized: any daemon with a single
  hardcoded `/etc/<x>` default and no XDG-style multi-dir search needs its systemd
  unit's `Environment=` patched post-install, not a `/etc` file shipped from the build
  tree — same shape as falcond's `/usr/share` + `/var/lib` split, but via env vars
  instead of compiled-in `-D` paths since ananicy-cpp doesn't expose that as a CMake
  option the way falcond exposes `-Duser-profiles-dir`.

## Verification (no live build available in this planning pass)

1. `mise validate` — full element graph resolves (catches typos/missing deps before
   any network fetch).
2. `mise bst source track desktop/spdlog.bst desktop/ananicy-cpp.bst` — resolves both
   placeholder `ref:` fields for real; commit whatever it produces verbatim.
3. `mise bst build desktop/spdlog.bst` then `mise bst build desktop/ananicy-cpp.bst` —
   first real signal on the `find_package(fmt)`/`find_package(spdlog)` chain.
4. `mise bst build elements/stacks/desktop.bst` (or full `mise build`) — confirms no
   conflict with the existing `falcond`/`scx-loader`/`power-profiles-daemon` block.
5. `mise boot-test` — boot the image, `systemctl status ananicy-cpp.service` (expect
   `active (running)`, unit preset-enabled), confirm it picked up
   `/usr/share/ananicy.d`'s CachyOS rules (`journalctl -u ananicy-cpp -b` should show
   rule/type file load counts, mirroring the falcond `LOADED_PROFILES` lesson — verify
   the daemon actually loaded rules, don't stop at "service is running").
6. Confirm `/var/lib/ananicy-cpp/ananicy.conf` gets auto-generated on first start (proves
   the writable-state-dir override took effect, not the compiled-in `/etc` default).

## Skill-improvement mandate compliance

The `docs/skills/bst.md` update above must land in the **same commit** as
`elements/desktop/ananicy-cpp.bst` / `elements/desktop/spdlog.bst`, per AGENTS.md — do
not defer it to a follow-up. Archive this plan to `docs/plans/done/` in the same PR that
merges the implementation, with the verification section filled in with real command
output (not left as this pass's "no live build available" placeholder).
