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
  C++20). *Not* GitHub. **Correction from the first pass of this plan**: the AUR
  `ananicy-cpp` page (maintainer Antoine Viallon, still pinned at `v1.1.1`) is not the
  live reference — the package **graduated from AUR into Arch's official `extra`
  repo** at `1.2.0-1` (built 2026-03-27, maintainer Peter Jung/`ptr1337`), confirmed
  via `archlinux.org/packages/extra/x86_64/ananicy-cpp/` and its packaging PKGBUILD at
  `gitlab.archlinux.org/archlinux/packaging/packages/ananicy-cpp`. Use *that* PKGBUILD
  as the authoritative upstream-packaging reference, not the orphaned AUR one. It
  confirms `v1.2.0` (`7117eaf278082bdbb8e25d94c4f7a141afeb1ae4`) and surfaces one build
  flag the AUR page's older `v1.1.1` recipe didn't have — see `ENABLE_REGEX_SUPPORT`
  below. krytis's `gitlab:` alias (`include/aliases.yml`) already covers this host for
  `kind: git_repo`.
- **Rules**: `https://github.com/CachyOS/ananicy-rules` (GPL-3.0-or-later). Bare-numeric
  tags (`1.1.49`, no `v` prefix), real GitHub releases — unlike
  `PikaOS-Linux/falcond-profiles` (no releases, forced a bespoke commit-SHA tracker),
  this one tracks cleanly with a plain `track: '*.*.*'` glob.
- **Build deps** (from `v1.2.0`'s `CMakeLists.txt` + the Arch `extra` PKGBUILD, both
  read this session): `nlohmann_json` 3.9+, `fmt` 8.0+, `spdlog` 1.9+, `pcre2` (new in
  1.2.0, see below), all fetchable via CPM (`cmake/CPM.cmake`, vendored in-tree — no
  network needed) *or* via `find_package()`/`pkg_check_modules()` when
  `USE_EXTERNAL_*=ON`/`ENABLE_REGEX_SUPPORT=ON` is passed. krytis must pass all
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
  - `pcre2` (libpcre2-8) → **new in `v1.2.0`**, gated behind `-DENABLE_REGEX_SUPPORT`
    (added for the changelog's "[Rules] Add regex rules matching" — CachyOS's own
    `ananicy-rules` changelog carries matching rule-syntax updates, so treat this as
    required for the shipped ruleset to fully apply, not optional polish). Read
    `v1.2.0`'s `CMakeLists.txt` directly: `find_package(PkgConfig REQUIRED)` +
    `pkg_check_modules(... REQUIRED IMPORTED_TARGET libpcre2-8)`. **Also absent from
    fdsdk** (confirmed: paged the full `elements/components/` tree, alphabetically
    absent between `pciutils.bst` and `pcsc-lite.bst`) — third krytis-vendored
    element, same pattern as `spdlog.bst`. The Arch `extra` package enables this flag;
    match it.
- **systemd**: `ENABLE_SYSTEMD=ON` links `libsystemd` and installs
  `ananicy-cpp.service` via `cmake --install` (no manual `install -Dm644` needed,
  unlike falcond's zig build which didn't install its unit). Use
  `freedesktop-sdk.bst:components/systemd.bst` exactly as `desktop/sdbus-cpp.bst`
  already does (`build-depends` + `depends`, `.pc` + `.so` both present).
- **Process-detection backend — decision: netlink, not BPF.** ananicy-cpp supports two
  mutually exclusive backends selected by `-DUSE_BPF_PROC_IMPL`:
  - **BPF** (what the official Arch `extra` `PKGBUILD` uses —
    `-DUSE_BPF_PROC_IMPL=ON -DBPF_BUILD_LIBBPF=OFF`, `makedepends=(bpf clang ...)`,
    `depends=(libbpf libelf ...)`): `libananicycpp_bpf/CMakeLists.txt` pulls `libbpf`
    via CPM (network fetch, even with `BPF_BUILD_LIBBPF=OFF` the surrounding
    `include(CPM)` / `FindBpfObject.cmake` machinery still needs auditing), compiles a
    BPF C skeleton with `clang -target bpf` against a per-arch vendored `vmlinux.h`,
    and optionally shells out to `bpftool`. Substantially heavier build graph than
    anything else in `desktop/`.
  - **netlink** (the default when `USE_BPF_PROC_IMPL` is simply omitted): a plain
    `libananicycpp_netlink/` static lib using the kernel's `NETLINK_CONNECTOR` proc
    socket. Zero extra build deps beyond what's already needed for the main binary.
    Functionally complete — every checklist item in upstream's README ("What works")
    is backend-agnostic.
  - Pick netlink anyway, diverging from the official Arch/CachyOS packaging choice:
    boring, no new libbpf/clang/CO-RE surface to maintain, no CPM network-fetch path
    to audit shut. Record this as the deliberate choice (not an oversight) in the
    element's header comment, same way `scx-scheds.bst` records its version pin
    rationale — and flag it explicitly for review, since it's the one place this plan
    knowingly diverges from the authoritative packaging reference rather than
    following it.
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

### `elements/desktop/pcre2.bst` (new)

```yaml
kind: cmake

# PCRE2 (8-bit build only): required by desktop/ananicy-cpp.bst's regex rule matching
# (-DENABLE_REGEX_SUPPORT=ON, new in ananicy-cpp v1.2.0). Not shipped by
# freedesktop-sdk (confirmed absent from the full elements/components/ tree,
# alphabetically between pciutils.bst and pcsc-lite.bst — same verification method as
# desktop/spdlog.bst). Vendored the same way.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  cmake-local: >-
    -DBUILD_SHARED_LIBS=ON
    -DPCRE2_BUILD_PCRE2_8=ON
    -DPCRE2_BUILD_PCRE2_16=OFF
    -DPCRE2_BUILD_PCRE2_32=OFF
    -DPCRE2_BUILD_PCRE2GREP=OFF
    -DPCRE2_BUILD_TESTS=OFF
    -DBUILD_STATIC_LIBS=OFF

sources:
- kind: git_repo
  url: github:PCRE2Project/pcre2.git
  track: pcre2-*
  ref: <resolved by `mise bst source track desktop/pcre2.bst`>
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
# Source: https://gitlab.com/ananicy-cpp/ananicy-cpp — not GitHub. The AUR
# `ananicy-cpp` package is stale/orphaned (pinned v1.1.1) now that the package
# graduated into Arch's official `extra` repo at 1.2.0-1 — krytis tracks v1.2.0+
# directly upstream, cross-checked against the `extra` PKGBUILD rather than AUR.
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
- desktop/pcre2.bst

variables:
  cmake-local: >-
    -DUSE_EXTERNAL_JSON=ON
    -DUSE_EXTERNAL_FMTLIB=ON
    -DUSE_EXTERNAL_SPDLOG=ON
    -DENABLE_SYSTEMD=ON
    -DENABLE_REGEX_SUPPORT=ON
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

- Every `ref:` placeholder above **must** be resolved with a real `mise bst source
  track desktop/ananicy-cpp.bst desktop/spdlog.bst desktop/pcre2.bst` run (four
  placeholders total: `ananicy-cpp.bst` carries two sources), not hand-typed — don't
  guess the `git describe` suffix format.
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
- **Vulnerability check (performed 2026-09-11, before any element existed — verified
  against NVD directly, not vuldb/search-engine noise):**
  - `pcre2`: four CVEs published *the same day* as this check — CVE-2026-89157
    (medium, 32-bit-only), CVE-2026-89158 (medium, 32-bit-only), CVE-2026-89160 (low,
    all platforms), CVE-2026-89161 (**high 7.4**, `pcre2_jit_match` incorrect-free,
    all platforms) — all fixed in `pcre2-10.48`, tagged the same day. krytis is
    x86_64-only so the two 32-bit-only ones don't apply regardless, but this means
    the `track: pcre2-*` glob landed on the fix by pure timing luck. **Before
    merging, confirm the `mise bst source track` output actually resolved to
    `pcre2-10.48` or newer** — don't trust a cached/stale `10.47` resolution from a
    tracker run that predates today.
  - `spdlog`: one real CVE, CVE-2025-6140 (low, local resource exhaustion via a
    crafted log-pattern string in `scoped_padder`), fixed in v1.15.2; latest tag is
    v1.17.0 so `track: v*` lands well past it. (Two other "spdlog CVEs" a web search
    surfaced — CVE-2023-39319 "XSS", CVE-2022-27664 "HTTP/2 DoS" — are false
    attributions confirmed via NVD to actually be Go stdlib `net/http`/`html/template`
    CVEs unrelated to `gabime/spdlog`; disregard if they resurface.)
  - `ananicy-cpp` and `CachyOS/ananicy-rules`: no GHSA/CVE or security advisories on
    file for either (GitLab's advisory UI and CachyOS's GitHub advisories page both
    checked empty).
  - `fmtlib.bst`: this plan is krytis's *first* consumer (grepped — no existing
    element depends on it), so it's a genuinely new `.so` in the image. Only
    advisories on file are CVE-2018-1000052 (fixed in 4.1.0, fdsdk ships far newer)
    and a Nov-2025 macOS-only command-injection GHSA — neither applies here.
  - Design-level, not a CVE: ananicy-cpp runs as root with no capability drop
    possible (cgroup placement has no dedicated capability) and this plan's
    `install-commands` don't add `CapabilityBoundingSet=`/`ProtectSystem=` hardening
    on top of upstream's unit. Same shape as the existing `desktop/falcond.bst` (also
    unhardened root daemon) — not a regression this plan introduces, but it is a
    second always-on root daemon of that class entering the image.
  - Once this lands and a real `mise run vuln-scan` exists against it, `pcre2` and
    `spdlog` will be purl-less native packages in the SBOM (same shape as
    `nlohmann-json`) — expect to run the `vuln-scan-triage` skill against them for
    `stock-matcher` cross-ecosystem false positives; don't pre-emptively add
    `.grype.yaml` entries now against a plan that hasn't been built.

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
falcond/falcond-profiles hit, so all three fit the **existing shared matrix job** (the
one whose `matrix.include` list already carries `nlohmann-json`, `kmscon`, `libtsm`,
etc. — read this session at lines ~836-1000) rather than needing bespoke jobs:

```yaml
          - group: ananicy-cpp
            element: desktop/ananicy-cpp.bst
            branch: auto/track-ananicy-cpp
            title: "chore(deps): update ananicy-cpp"
          - group: spdlog
            element: desktop/spdlog.bst
            branch: auto/track-spdlog
            title: "chore(deps): update spdlog"
          - group: pcre2
            element: desktop/pcre2.bst
            branch: auto/track-pcre2
            title: "chore(deps): update pcre2"
```

Also add `ananicy-cpp`, `spdlog`, and `pcre2` to the
`workflow_dispatch.inputs.group.options` list near the top of the file (satisfies
AGENTS.md's Update Path Gate option (a) — no new mise task needed).

## `docs/skills/desktop.md` (not `bst.md` — that's where falcond's own section
## actually lives)

Add a `## ananicy-cpp (process-class nice/ionice daemon)` section near the existing
`## falcond (PikaOS gaming performance daemon)` section, covering (per the
self-improvement-loop mandate — must land in the same commit as the element, not a
follow-up):

- The `fmtlib.bst` vs `fmt.bst` naming trap (component is literally named
  `fmtlib.bst` in fdsdk — easy to grep for the wrong name and conclude fmt isn't
  shipped).
- spdlog is absent from fdsdk entirely (verified: paginated the full
  `elements/components/` tree via the GitLab API). **pcre2 is not** — this plan's
  original claim was wrong. fdsdk ships it under `elements/bootstrap/pcre2.bst`
  (autotools, JIT-enabled, `pcre2-10.47` pinned with its own `exclude: ['*-RC*']`),
  a subtree this plan's research never checked. Discovered only by actually building
  the element: `desktop/pcre2.bst` collided with `bootstrap/pcre2.bst` at every
  installed path ("not permitted to overlap"), something `mise validate` alone never
  catches (it resolves the graph, it doesn't stage a sandbox). Implemented as a
  direct dependency on the existing bootstrap element instead — see
  `docs/skills/desktop.md`'s ananicy-cpp section for the full correction and
  `docs/skills/bst.md`'s new "Overriding install-commands on a buildsystem element"
  section for the related `%{install-extra}` trap this also surfaced.
- The AUR-vs-`extra` trap: a stale/orphaned AUR page can keep describing an older
  release long after a package graduates into Arch's official repos (ananicy-cpp:
  AUR pinned at v1.1.1, `extra` at 1.2.0-1) — check `archlinux.org/packages/` and the
  `gitlab.archlinux.org/archlinux/packaging/packages/<name>` PKGBUILD before trusting
  an AUR page's pinned version or build flags as current.
- The netlink-vs-BPF decision and why (link back to this plan once archived).
- The CONFDIR/CONF env-var override technique, generalized: any daemon with a single
  hardcoded `/etc/<x>` default and no XDG-style multi-dir search needs its systemd
  unit's `Environment=` patched post-install, not a `/etc` file shipped from the build
  tree — same shape as falcond's `/usr/share` + `/var/lib` split, but via env vars
  instead of compiled-in `-D` paths since ananicy-cpp doesn't expose that as a CMake
  option the way falcond exposes `-Duser-profiles-dir`.
- **Also wrong in this plan's original pass**: the claim that upstream ships
  ananicy-cpp's unit unhardened, same posture as falcond. It doesn't — v1.2.0's own
  unit carries a real `CapabilityBoundingSet=`, `ProtectSystem=full`, and more; see
  `docs/skills/desktop.md` for the verified detail. Sourced from a web search of
  third-party docs at plan-writing time, not the actual unit file — a lesson in
  itself: check the artifact, not a search result, before asserting a security
  posture.

## Verification (real output, 2026-09-11 implementation pass)

1. `mise validate` — passed, exit 0, full graph including the new elements resolves.
2. `mise bst source track desktop/spdlog.bst desktop/pcre2.bst desktop/ananicy-cpp.bst`
   — resolved `spdlog` to `v1.17.0-0-g79524ddd...`, `ananicy-cpp` to
   `v1.2.0-0-gcf5ac2eb...` + CachyOS rules `1.1.49-0-g03ef03fb...`. `desktop/pcre2.bst`
   was later deleted entirely (see correction above) — its first tracking attempt is
   itself a finding worth keeping: `track: pcre2-*` resolved to the pre-release
   `pcre2-10.48-RC1` over the final `pcre2-10.48`, requiring an `exclude:
   ['pcre2-10.48-RC1']` to fix (before the element was deleted as redundant) — the
   exact same RC-exclusion trap fdsdk's own `bootstrap/pcre2.bst` already carries.
3. `mise bst build desktop/spdlog.bst desktop/pcre2.bst` (before the pcre2 deletion)
   — both built successfully; confirmed `find_package(fmt CONFIG REQUIRED)` resolves
   against `fmtlib.bst`'s installed `FmtConfig.cmake`, the one link this plan flagged
   as unverified.
4. `mise bst build desktop/ananicy-cpp.bst` — failed three times before succeeding,
   each failure a real finding, not a flake: (a) `desktop/pcre2.bst` vs
   `bootstrap/pcre2.bst` overlap (fixed by deleting the vendored element); (b) v1.2.0
   missing `<cstring>`/`<cstdint>`/`<unistd.h>` includes under fdsdk's GCC 16.2.0
   (fixed by cherry-picking upstream's own fix commit `77866526` as
   `patches/ananicy-cpp/glibc-2.42-missing-headers.patch`); (c) `sed: command not
   found` then a `%{install-extra}` no-op that silently skipped the real
   `cmake --install` step (fixed: added `bootstrap/sed.bst` to `build-depends`, and
   replaced the `%{install-extra}` line with the actual `%{make-install}` variable,
   run before the `sed`-based `Environment=` patch that depends on its output).
   Final build: SUCCESS. `bst artifact checkout` confirmed the installed unit,
   preset, tmpfiles fragment, and CachyOS rules tree all match what this plan
   specified.
5. `mise bst build stacks/desktop.bst` — SUCCESS, confirms no overlap conflict with
   the existing `falcond`/`scx-loader`/`power-profiles-daemon` block or anything else
   in the full desktop dependency closure.
6. `mise run lint` and full `mise run build` (load-image + lint) — SUCCESS.
   `bootc container lint`: 14 checks passed, 1 skipped. Full OCI image assembled
   (`oci/krytis/image.bst`), composed 232115/236211 files across the runtime/
   filesystem splits with no overlap errors, tagged `localhost/krytis:latest`.
7. `mise boot-test` — **PASSED** (run by a human with sudo access on the built
   image; the privileged `bootc install to-disk --via-loopback` step needs
   `CAP_SYS_ADMIN` in the initial user namespace, unavailable to the implementing
   agent in an unattended session).

## Skill-improvement mandate compliance

The `docs/skills/desktop.md` update above landed in the same commit as
`elements/desktop/ananicy-cpp.bst`/`elements/desktop/spdlog.bst`, per AGENTS.md.
`docs/skills/bst.md` also gained a new section ("Overriding `install-commands` on a
buildsystem element replaces the real install step") and a corrected
`%{install-extra}` table entry, both from lessons this implementation pass
surfaced. This plan is archived to `docs/plans/done/` in the same PR that carries
the implementation, per its own instruction above.
