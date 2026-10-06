# Audit systemd's build type after the element switch

**Issue:** #1108 · **Branch:** `1108-audit-systemd-build-type` (this plan) · **Status: ready, not started.**

`e629ce7` moved the systemd build from a krytis-owned mirror to gnome-build-meta's
`core-deps/systemd-base.bst`. The element body did not change — only the `project.conf` that
owns it, and with it `meson-global`. One consequence is already measured: `EFI_DEBUG` went
off, the EFI binaries lost their serial banners, and `mise run enroll-test` failed every
publish from 2026-10-02 until #1106 rewrote the gate. The expensive one is not measured:
whether `--buildtype=plain` leaves the shipped systemd without `-O2`/`-g` and with `NDEBUG`
undefined.

Step 1 settles that with measurements. Step 2 is a Design Gate — the answer decides whether
steps 3–5 happen at all, and in which direction. #1108 carries the evidence gathered so far.

## Baseline (measured 2026-10-06, `main` @ `5ac840c`)

| | |
|---|---|
| krytis `project.conf`, `elements: meson: variables: meson-global` | `--buildtype=debugoptimized -Db_ndebug=true -Dwerror=false` |
| gnome-build-meta `project.conf`, same key | `--buildtype=plain --auto-features=enabled --wrap-mode=nodownload` |
| junctions | fdsdk `freedesktop-sdk-26.08.2-0-g32c5fea7`, gnome-build-meta `51.0-6-g5ec987b6` |
| systemd | 261.3 (was 261.2 + our `update-utmp` patch before `e629ce7`) |
| `.text` delta across the switch | `systemd` +8.0%, `systemd-journald` +13.5%, `systemd-bootx64.efi` +13.5% |

Meson maps the build type onto the flags (`mesonbuild/coredata.py`
`_set_others_from_buildtype`, read at meson 1.7.0): `debugoptimized` → `optimization=2,
debug=true`; `plain` → `optimization=plain` (no `-O` of its own), `debug=false`. Dropping
`-Db_ndebug=true` additionally leaves `NDEBUG` undefined, so systemd's own `assert()` is
compiled in rather than out. None of those three is visible in the element's diff.

## Step 1 — Measure the current build's flags

No decision in this step. The output is a table with a source for every value.

- [ ] 1.1 Confirm the BuildStream cache drive is mounted (`findmnt -T ~/.cache/buildstream`);
      ask before proceeding if it is not. The artifact is not in the local cache *or* in bow
      under the current graph key (`gnome/core-deps-systemd-base/86bc8fb7…` reports "not
      cached"), so this step needs one build.
- [ ] 1.2 `mise run warm-cache gnome-build-meta.bst:core-deps/systemd-base.bst`. Record the
      wall time — it is the per-iteration cost of every option in step 2.
- [ ] 1.3 `./mise/tasks/bst artifact log gnome-build-meta.bst:core-deps/systemd-base.bst`:
      the `meson setup` summary (`User defined options`, build type) and the compiler
      invocations, if the log keeps them. If it does not, 1.4 decides.
- [ ] 1.4 Diff the freshly built `systemd` against the one shipped in the image. They should
      be byte-identical, which also proves the shipped image is what this element produces —
      nothing checks that today. Then point the override at a scratch mirror element
      carrying krytis's `meson-global`, rebuild, and diff `.text` plus a couple of functions.
      **That diff is the measurement**; meson's documentation is not.
- [ ] 1.5 Find what supplies `-O2`/`-g`, if anything: grep fdsdk at the pinned ref for
      `CFLAGS`/`-O2` (`project.conf`, `include/_private/*.yml`,
      `elements/public-stacks/buildsystem-*.bst`, `components/gcc.bst`). Krytis's own
      `project.conf` asserts that fdsdk sets those and krytis does not — that assertion is
      itself unverified, and if it is wrong the comment is rot too.
- [ ] 1.6 Put the result in #1108's body as a table: setting · value · where it came from.
      No adjectives.

**Acceptance:** `optimization`, `debug` and `b_ndebug` each have a value, and each value has
the command or file:line that produced it.

## Step 2 — Design Gate: pick the target

Stop and ask. The options and what each costs:

| | what | cost |
|---|---|---|
| A | Accept gnome-build-meta's flags; record the decision in the skill file, close #1108 | none — ships whatever `plain` means |
| B | Own the element again: an inlined mirror of `core-deps/systemd-base.bst` carrying krytis's `meson-global`, plus a drift-check mise task and an update path | the shape #483 removed, back; a mirror body to resync on every upstream change |
| C | B, but only where it matters: keep gnome-build-meta's body and add `-Doptimization=2 -Ddebug=true` (or `--buildtype=debugoptimized`) while leaving `b_ndebug` at upstream's default | the same mirror cost as B, with a smaller and more explainable divergence |

Constraint, from `docs/skills/bst.md` § Mirroring a junction element to patch its source: an
element used as a junction override target **cannot** use a cross-junction `(@):` include, so
there is no thin wrapper to write — B and C both mean an inlined body.

Decide `b_ndebug` explicitly, in either direction: krytis asked for `true` (asserts compiled
out), gnome-build-meta leaves `false` (asserts live). That is a safety-versus-size question,
not build hygiene, and it is the same knob that made `-Dwerror=false` necessary.

## Step 3 — Implement

Only for B/C.

- [ ] 3.1 Add the mirror element and point `elements/freedesktop-sdk.bst`'s `overrides:` at
      it in place of `gnome-build-meta.bst:core-deps/systemd-base.bst`.
- [ ] 3.2 Restore the drift check (`mise run systemd-base-check`, deleted in `e629ce7` —
      recover it from `e629ce7^`) and its `track-mise` CI job, or add the element to the
      `track` matrix, so the update path exists per AGENTS.md § Update path gate.
- [ ] 3.3 Keep the source ref following gnome-build-meta's pin instead of pinning a version
      of krytis's own: the old mirror's mistake was `ref: v261.2-0-g4925d9f07` standing still
      while the junction moved to v261.3.

## Step 4 — Verify

- [ ] 4.1 `./mise/tasks/bst show --format '%{vars}' <element>` shows krytis's `meson-global`
      on the element that actually builds systemd.
- [ ] 4.2 `mise run warm-cache gnome-build-meta.bst:core-deps/systemd-base.bst` rebuilds, and
      the `.text` delta against the `plain` build is recorded in #1108 — the number that
      justifies the mirror or does not.
- [ ] 4.3 `mise run build`, then `mise run enroll-test --image localhost/krytis:sealed`: the
      gate #1106 rewrote must pass either way, because it no longer depends on `EFI_DEBUG`.
- [ ] 4.4 `mise run docs-links`.

## Step 5 — Docs

- [ ] 5.1 `docs/skills/secure-boot.md` § The `systemd-boot@` serial banner is a debug
      artefact — replace "the flags come from the project that owns the element" with what
      that actually costs, once it is measured.
- [ ] 5.2 `docs/skills/bst.md` — the element-ownership lesson gains a worked example with
      numbers.
- [ ] 5.3 Update #1108's body, and archive this plan to `docs/plans/done/` in the PR that
      closes it.

## Non-goals

- **Getting the `systemd-boot@` banner back.** #1106 removed its last consumer; re-enabling
  `EFI_DEBUG` ships a debug EFI binary with live `assert_se` and a boot-time SHA256
  self-test. This plan is about optimisation and assertions, not about the gate.
- **Re-pinning the systemd version.** It must keep following gnome-build-meta's pin.
- **Anything upstream.** gnome-build-meta's `--buildtype=plain` is their project-wide choice
  and fdsdk's is theirs; proposing a change there is an Upstream Gate decision, not a step
  here.
- **The seal path.** `seal-uki`, the `.auth` files and the UKI are untouched by any option
  above.
