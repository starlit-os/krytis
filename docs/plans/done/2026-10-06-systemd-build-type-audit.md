# Audit systemd's build type after the element switch

**Issue:** #1108 · **Branch:** `1108-audit-systemd-build-type` (this plan) · **Status: done 2026-10-06 — option A.**

## Outcome

- **Step 1 confirmed the reading, from a build log.** Artifact
  `gnome/core-deps-systemd-base/86bc8fb7…` was in bow all along (the "not cached" in #1108 came
  from `bst artifact log`, which reads the local cache only); `bst --pull artifact pull --deps
  none` fetched it, so 1.3 (build) was skipped. Its `ninja -v` log: the last `-O` is `-O2` on
  1868 of 1869 compile lines (the exception is systemd's own `-O1` on
  `test-coredump-stacktrace.c`), `-g` on all, `-DNDEBUG` and `-DEFI_DEBUG` on none; meson's
  summary prints `build mode : developer`, `buildtype : plain`. 1.1's format key is `%{env}`,
  not `%{environment}` (that one dies with `KeyError`); it shows `CFLAGS: '-O2 -pipe -g …'`.
- **The meson ordering table was re-measured** (meson 1.7.0 via `uvx`, `CFLAGS="-O2 -pipe -g"`):
  identical to the one below. fdsdk's `include/flags.yml` already exported the same `CFLAGS` at
  the pin `#605` was written against (`c4f8b723`), and krytis has included `runtime.yml` since
  `767ec87`, its first commit — so #604's `-O0` half was never real.
- **Step 2: option A** (human decision). systemd keeps gnome-build-meta's build: live asserts.
  Step 3 not done.
- **Step 4** landed in the closing PR: `project.conf`'s comment, `bst.md` (the `_private`
  section, a third drop lesson, and `artifact log` reading only the local cache),
  `secure-boot.md`, two fdsdk paths in `docs/.links-ignore`. Cache keys unchanged
  (`desktop/cage.bst`, `core-deps/systemd-base.bst` compared with and without the diff at one
  HEAD). 4.5: no open issue repeated the stale claims (searched `buildtype`, `NDEBUG`,
  `debugoptimized`, `CFLAGS`, `-O0`, `unoptimised`, `1752`, `meson-conf`, `meson-global`,
  `b_ndebug`, and the literal `systemd-boot@`/`systemd-stub@` in bodies and comments).

`e629ce7` moved the systemd build from a krytis-owned mirror to gnome-build-meta's
`core-deps/systemd-base.bst`. The element body did not change. What changed is the
`project.conf` that owns it, and with it `meson-global`. Reading the sources at the pinned
refs (below) settles most of what this plan originally set out to measure: the switch did
**not** cost `-O2` or `-g`. It changed exactly two things, `NDEBUG` and `EFI_DEBUG`. The
second is already accepted (#1106). The first is the only open decision.

Step 1 confirms the source reading against a real build log, cheaply. Step 2 is the Design
Gate on `b_ndebug`. Step 3 exists only if the gate picks the mirror. Step 4 fixes the
documentation that the reading proved wrong, and runs whichever way the gate goes.

## What the sources say

Read at fdsdk `freedesktop-sdk-26.08.2-0-g32c5fea7`, gnome-build-meta `51.0-9-g0b400781`
(the pin on `main` since `fc455d9`, 2026-10-05), systemd `v261.3`, meson 1.7.0.

**Where `-O2 -g` come from.** fdsdk `include/flags.yml` sets `common_flags: "-O2 -pipe"`
(l.7) and `debug_flags: "-g"` (l.13), composes both into `target_flags` (l.79–83), and
exports `environment: CFLAGS/CXXFLAGS: "%{target_flags}"` (l.170–172). fdsdk
`include/runtime.yml` includes `flags.yml`. **Both** owning projects include `runtime.yml`
at the top of their `project.conf`: gnome-build-meta l.33, krytis l.10.
`core-deps/systemd-base.bst` does not override `local_flags` or `debug_flags`.

**Meson puts `CFLAGS` after its own build-type flags.** Measured with meson 1.7.0 and
`CFLAGS="-O2 -pipe -g"` on a one-file project (`compile_commands.json`):

| `--buildtype` | compile line (flags only) |
|---|---|
| `debug` | `-O0 -g -O2 -pipe -g` |
| `plain` | `-O2 -pipe -g` |
| `debugoptimized` | `-O2 -g -O2 -pipe -g` |

gcc takes the last `-O`, so all three compile at `-O2 -g` once `CFLAGS` is set.

**The resulting table:**

| setting | before (krytis owns) | after (gnome-build-meta owns) | source |
|---|---|---|---|
| `-O` | `-O2` | `-O2` | fdsdk `CFLAGS`, plus the ordering above |
| `-g` | on | on | fdsdk `CFLAGS` |
| `NDEBUG` | defined (`-Db_ndebug=true`) | undefined | krytis `project.conf` `meson-global`; meson default `b_ndebug=false` |
| `EFI_DEBUG` | on | off | systemd `src/boot/meson.build:190`: `mode == 'developer' and get_option('debug')`; `mode` defaults to `developer` |

**What `NDEBUG` means in systemd.** It does not remove asserts. systemd overrides
`assert()` (`src/fundamental/assert-util.h:69–73`): with `NDEBUG` a failed check becomes
`__builtin_unreachable()`, so the compiler is allowed to assume it holds, and a violated
invariant is undefined behaviour. Without `NDEBUG` it logs and aborts. `assert_se()` is live
either way. Most distributions build systemd with meson's `plain` build type and no
`NDEBUG` (inferred, not checked against each one's packaging).

The `.text` growth across the switch (`systemd` +8.0%, `systemd-journald` +13.5%) fits live
asserts plus 261.2 → 261.3. A drop to `-O0` would be far larger. That is an inference too,
and step 1 is what confirms it.

## Step 1 — Confirm against a real build

No decision in this step. Every value in the table above gets a command behind it.

- [x] 1.1 `./mise/tasks/bst show --deps none --format '%{environment}'
      gnome-build-meta.bst:core-deps/systemd-base.bst` shows `CFLAGS` containing `-O2` and
      `-g`. This needs no build.
- [x] 1.2 Recompute the element's cache key against the current junction pin
      (`51.0-9-g0b400781`). The "not cached" result recorded in #1108 (`86bc8fb7…`) was taken
      at `51.0-6-g5ec987b6` and may be stale. If the artifact exists locally or in bow, skip
      to 1.4.
- [ ] 1.3 Otherwise confirm the cache drive is mounted (`findmnt -T ~/.cache/buildstream`),
      ask before proceeding if it is not, and run
      `mise run warm-cache gnome-build-meta.bst:core-deps/systemd-base.bst`. Stop at the
      **Toolchain Gate** if it starts compiling `bootstrap/*`, `components/llvm.bst` or
      `components/rust.bst`.
- [x] 1.4 gnome-build-meta runs `ninja -v` (`project.conf:145`), so the log keeps every
      compile line:
      `./mise/tasks/bst artifact log gnome-build-meta.bst:core-deps/systemd-base.bst | grep -m1 -E ' (cc|gcc) .*src/core/'`.
      Record the last `-O`, whether `-g` is present, and whether `-DNDEBUG` is present.
- [x] 1.5 Put the confirmed table in #1108's body, each value with the command that produced
      it.

**Acceptance:** the four rows above each have a value from a build log or `bst show`, not
from reading.

No byte-for-byte comparison with the shipped image: if the current key is cached nowhere,
`krytis:latest` was built from a different key and cannot match.

## Step 2 — Design Gate: `b_ndebug`

Stop and ask. `-O` and `-g` are not in question, so the choice is only this:

| | what | cost |
|---|---|---|
| **A** (recommended) | Keep gnome-build-meta's element. systemd ships with live asserts, the configuration upstream tests and most distributions ship. Record the decision in the skill files and close #1108. | none |
| **B** | Own the element again as an inlined mirror of `core-deps/systemd-base.bst`, keeping `NDEBUG` defined. Its `meson-local` must add `-Ddebug=false`, because krytis's `meson-global` (`debugoptimized`) sets `debug=true` and that turns `EFI_DEBUG` back on. Prefer that over `-Dmode=release`, which also adds `-ftrivial-auto-var-init=zero`, drops `-fno-omit-frame-pointer` and changes assert-failure logging (`meson.build:496–511`). | the mirror shape #483 removed, a drift check, an update path, and a failed invariant in PID 1 becomes undefined behaviour instead of a logged abort |

Option B's earlier variant (adding `-Doptimization=2 -Ddebug=true`) is gone: the
optimisation already matches, and `debug=true` brings back the debug EFI build the non-goals
rule out.

If the gate leans to B, put a number on it first: build the scratch mirror with
`-Db_ndebug=true -Ddebug=false` and record the `.text` delta of `systemd` and
`systemd-journald` against the 1.4 build.

Constraint, from `docs/skills/bst.md` § Mirroring a junction element to patch its source: an
element used as a junction override target **cannot** use a cross-junction `(@):` include, so
there is no thin wrapper. B means an inlined body.

## Step 3 — Implement (B only)

- [ ] 3.1 Add the mirror element with the `meson-local` additions from step 2, and point
      `elements/freedesktop-sdk.bst`'s `overrides:` at it in place of
      `gnome-build-meta.bst:core-deps/systemd-base.bst`.
- [ ] 3.2 Restore the drift check (`mise run systemd-base-check`, deleted in `e629ce7`;
      recover it from `e629ce7^`) and its `track-mise` CI job, per AGENTS.md § Update path
      gate. A mirror's ref cannot follow gnome-build-meta's pin by itself; the drift check is
      what keeps it from standing still at an old version the way `v261.2-0-g4925d9f07` did.
- [ ] 3.3 `./mise/tasks/bst show --deps none --format '%{vars}' <mirror>` shows `-Ddebug=false`
      after krytis's `meson-global`, and the 1.4 grep on the new build shows `-DNDEBUG`.
- [ ] 3.4 `mise run build`, then `mise run enroll-test --image localhost/krytis:sealed`. The
      gate #1106 rewrote must still pass; it no longer depends on `EFI_DEBUG`.

## Step 4 — Docs (both options)

The reading above contradicts four places. Edit the old text; do not append a corrected
paragraph beside it.

- [x] 4.1 krytis `project.conf`, the `meson-global` comment (l.132–156). "CFLAGS/CXXFLAGS,
      which fdsdk sets and krytis does not" is false today: krytis gets them through its l.10
      include. "Meson's default `debug` buildtype, i.e. -O0" is also false while `CFLAGS`
      carries `-O2` (ordering table above). Keep the `b_ndebug` and `werror` reasoning, which
      still holds.
- [x] 4.2 `docs/skills/bst.md` § freedesktop-sdk's `include/_private/` config is not inherited
      (l.97–157). The same "krytis does not" claim is at l.113. The "1752 `-O0` lines" table
      (l.144) counts lines containing `-O0`, which a later `-O2` from `CFLAGS` overrides.
      First find out whether the `runtime.yml` include predates #604 (this checkout's history
      is too shallow to say). If it does, the "unoptimised for a year" account is wrong and
      only the `NDEBUG` half of #604 stands. Also correct "`assert()` expands to nothing"
      (l.128): true of glibc's `assert()`, not of systemd's.
- [x] 4.3 `docs/skills/secure-boot.md` § The `systemd-boot@` serial banner is a debug
      artefact (l.638). Drop `-O` and `-g` from the list of things that move with the
      element's owner (they come from `CFLAGS` in all three projects), and cite
      `src/boot/meson.build:190` as the exact `EFI_DEBUG` trigger.
- [x] 4.4 `docs/skills/bst.md`, the element-ownership lesson: add this case as the worked
      example. Diff `meson-global` **and** the `environment:` both `project.conf`s include;
      `plain` only means "no optimisation" when nothing sets `CFLAGS`.
- [x] 4.5 Grep open krytis issues for the stale claims
      (`gh issue list --state open --search 'buildtype in:body'`) and correct any body that
      repeats them.
- [x] 4.6 `mise run docs-links`. Update #1108's body with the outcome, and archive this plan
      to `docs/plans/done/` in the PR that closes it.

## Non-goals

- **Getting the `systemd-boot@` banner back.** #1106 removed its last consumer.
  Re-enabling `EFI_DEBUG` ships a debug EFI binary with live `assert_se` and a boot-time
  SHA256 self-test.
- **Re-pinning the systemd version.** It keeps following gnome-build-meta's pin, or under
  B, the drift check's.
- **Anything upstream.** gnome-build-meta's `--buildtype=plain` and fdsdk's are their
  project-wide choices; proposing a change there is an Upstream Gate decision.
- **The seal path.** `seal-uki`, the `.auth` files and the UKI are untouched by either
  option.
