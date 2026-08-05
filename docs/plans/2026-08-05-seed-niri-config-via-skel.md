# Seed niri config via skel — Implementation Plan

**Issue:** #490

**Goal:** Every newly-created account gets a real `~/.config/niri/config.kdl` (not an absent one), so noctalia's `theme.templates` niri integration can only *append* to it, never silently replace krytis's entire niri config with a one-line stub.

**Architecture:** Add a new BST element, `config/niri-skel.bst`, that installs the exact same source files `config/niri-config.bst` already ships (`files/niri/`) to `/etc/skel/.config/niri/` instead of `/etc/niri/`. `config/niri-config.bst` is untouched — `/etc/niri/` stays as the system-wide fallback for any account-creation path that doesn't copy skel. Single source of truth (`files/niri/*.kdl`), two install targets, zero duplication.

**Decision (not left open):** keep `/etc/niri/` alongside the new skel seed, rather than retiring it. It costs nothing (same source files, no extra content to maintain) and is a safety net for any account that somehow bypasses skel copy. Retiring `/etc/niri/` entirely is a legitimate follow-up once skel-seeding has run in the field for a while — out of scope here; don't do it as part of this plan.

**Tech Stack:** BuildStream `kind: manual` element (same shape as `config/noctalia-skel.bst`), `niri validate` for config-syntax verification.

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only (`AGENTS.md`).
- All maintenance tasks must be `mise` tasks; this plan adds no new task (no new maintenance surface, just static files) — the Update path gate does not apply (no new upstream source to track, `files/niri` is already `kind: local`).
- `mise lint` must pass and the image must be shown to boot before opening a PR for review (`AGENTS.md` § Verification). If the executing session cannot run BST-build-dependent gates (see `docs/design/first-boot-setup.md`'s verification section for precedent — `mise build`/`lint`/`boot-test` is a documented ~420-minute job excluded from `checks.yml`'s PR gates), say so explicitly in the PR and write out what still needs running elsewhere; do not claim untested things as verified.
- Skill file updates land in the **same commit** as the change that produced the learning (`AGENTS.md` Self-Improvement Loop) — Task 3 below is not a follow-up.
- Cross-repo note: `kitten-lily/dakota-iso` is believed to need **no code change** (Task 4 is verification-only — see the investigation already recorded in issue #490). If that verification finds it actually does need a change, that change and this plan's skill-doc update satisfy `AGENTS.md`'s Cross-repo exception (paired PRs, cross-referenced commits) — don't skip writing the dakota-iso-side skill entry if code changes there.
- Worktree already created: `krytis.worktrees/fix/gh490-seed-niri-config-via-skel`, branch `490-seed-niri-config-via-skel` (top-level issue, no `parent:`, per `AGENTS.md`'s worktree convention).

---

### Task 1: Create `config/niri-skel.bst`

**Files:**
- Create: `elements/config/niri-skel.bst`
- Reuses (no changes): `files/niri/{config.kdl,input.kdl,layout.kdl,noctalia.kdl,rules.kdl,startup.kdl,binds.kdl,binds/*.kdl}` — the exact same source tree `config/niri-config.bst` already declares as its `sources:`.

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `/etc/skel/.config/niri/{config.kdl,input.kdl,layout.kdl,noctalia.kdl,rules.kdl,startup.kdl,binds.kdl,binds/*.kdl}` in the built image — Task 2 depends on this element existing; Task 3's verification reads these exact paths.

- [ ] **Step 1: Read the current `config/niri-config.bst` for the install-commands pattern to mirror**

```bash
cat elements/config/niri-config.bst
```

Confirm the loop shape (`for f in config.kdl input.kdl layout.kdl noctalia.kdl rules.kdl startup.kdl binds.kdl; do install -Dm644 "$f" ...; done` then a second loop over `binds/*.kdl`) hasn't changed since this plan was written. If it has, adapt Step 2 to match the current loop, not the one quoted here.

- [ ] **Step 2: Write `elements/config/niri-skel.bst`**

```yaml
kind: manual

# Seeds /etc/skel/.config/niri/ — copied into new accounts' home dirs by
# useradd --create-home and by homectl firstboot's --skel default (both
# default to /etc/skel; confirmed SKEL=/etc/skel in the shipped
# /etc/default/useradd, from freedesktop-sdk.bst:vm/config/useradd-ostree.bst).
# Same source files as config/niri-config.bst, which keeps shipping
# /etc/niri/ as a secondary system-wide fallback for any account-creation
# path that bypasses skel copy — no content is duplicated, both elements
# read from files/niri/.
#
# Fixes #490: noctalia's theme.templates niri integration
# (assets/templates/niri/apply.sh in noctalia-dev/noctalia, active when
# theme.templates.builtin_ids contains "niri") writes
# ~/.config/niri/noctalia.kdl and, if ~/.config/niri/config.kdl does not
# already exist, creates it containing ONLY `include "noctalia.kdl"`. Once
# that stub exists, niri's own config lookup
# ($XDG_CONFIG_HOME/niri/config.kdl -> /etc/niri/config.kdl) never reaches
# the /etc fallback again for that user, silently discarding every other
# file krytis ships (input.kdl, layout.kdl, rules.kdl, startup.kdl,
# binds.kdl -- all keybinds, the GTK_IM_MODULE compose-key fix, window
# rules). Seeding a real config.kdl here means noctalia's template hits
# its "already exists" branch instead, which only *appends* the include
# line -- additive, not destructive.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    for f in config.kdl input.kdl layout.kdl noctalia.kdl rules.kdl startup.kdl binds.kdl; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/skel/.config/niri/$f"
    done
    for f in binds/*.kdl; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/skel/.config/niri/$f"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/niri
```

- [ ] **Step 3: Sanity-check YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('elements/config/niri-skel.bst'))" && echo OK
```

Expected: `OK`.

---

### Task 2: Wire `config/niri-skel.bst` into the desktop stack

**Files:**
- Modify: `elements/stacks/desktop.bst` (`## ── Config ──` section, currently lines ~183-186)

**Interfaces:**
- Consumes: `elements/config/niri-skel.bst` from Task 1.
- Produces: the element is now reachable from `oci/krytis/image.bst`, so Task 3's `mise run validate` / build will actually include it.

- [ ] **Step 1: Add the dependency next to the existing `niri-config.bst` / `noctalia-skel.bst` lines**

Current shape (re-read the file first — line numbers may have shifted):

```yaml
  # ── Config ─────────────────────────────────────────────────────────────
  - config/niri-config.bst
  - config/noctalia-skel.bst
  - config/noctalia-assets.bst
```

New shape — insert `config/niri-skel.bst` between the two, grouping the "system fallback" and "skel seed" elements for the same app together, matching how noctalia's own pair would read if it had one:

```yaml
  # ── Config ─────────────────────────────────────────────────────────────
  - config/niri-config.bst
  - config/niri-skel.bst
  - config/noctalia-skel.bst
  - config/noctalia-assets.bst
```

- [ ] **Step 2: Confirm the graph resolves**

```bash
mise run validate 2>&1 | grep -iE 'error|fail|niri-skel'
```

Expected: a `buildable <cache-key> config/niri-skel.bst` line (or `cached` if nothing changed since a previous run touched it), no `error`/`fail` lines. This does not build anything — it only resolves the element graph — so it's safe to run in any environment, no BST build cache or long runtime needed (same tier as `docs-links`, unlike `mise build`/`lint`/`boot-test` — see Global Constraints).

---

### Task 3: Update `docs/skills/desktop.md` (same commit, per the self-improvement loop)

**Files:**
- Modify: `docs/skills/desktop.md`, the section starting `Unlike niri (\`$XDG_CONFIG_HOME/niri/config.kdl\` → \`/etc/niri/config.kdl\` fallback, see \`config/niri-config.bst\`), noctalia has **no system-wide \`/etc\` config path**.` (currently around line 1135 — re-read to confirm before editing; this section already exists and documents the noctalia-vs-niri config-path asymmetry).

**Interfaces:**
- Consumes: nothing from other tasks (documentation only — can be written in parallel with Task 1/2, but land in the same commit as them per the constraint above).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Read the current section for exact wording/line numbers**

```bash
grep -n "Unlike niri" docs/skills/desktop.md
```

- [ ] **Step 2: Add a new subsection immediately after that paragraph**

Insert (as its own `##`-level or `###`-level entry, matching whatever heading depth the surrounding niri material in `desktop.md` uses — check neighboring headings before picking one):

```markdown
## noctalia's niri template silently orphans /etc/niri/config.kdl if no user config exists

noctalia's `theme.templates` niri integration (`assets/templates/niri/apply.sh`
in noctalia-dev/noctalia, active when `theme.templates.builtin_ids` contains
`"niri"`) writes theme colors to `~/.config/niri/noctalia.kdl` and, in its
`apply` post-hook: if `~/.config/niri/config.kdl` does not already exist, it
creates one containing **only** `include "noctalia.kdl"`; if it already
exists, it only *appends* that include line (checked via `grep`, not
duplicated on repeat runs).

Krytis used to ship niri's config as a system-wide fallback only
(`config/niri-config.bst` → `/etc/niri/config.kdl`, consulted via niri's own
`$XDG_CONFIG_HOME/niri/config.kdl` → `/etc/niri/config.kdl` lookup order) with
no per-user config ever seeded. That meant noctalia's "doesn't exist" branch
always fired the first time its niri template ran, creating a one-line stub
`~/.config/niri/config.kdl` that niri then preferred forever — permanently
hiding `/etc/niri/config.kdl` (and every keybind, window rule, and the
`GTK_IM_MODULE=simple` compose-key fix in it) behind a file containing nothing
but an `include` of the noctalia colors fragment. Silent: no error, no log
line, the session just came up with almost none of krytis's niri config.

Fixed by `config/niri-skel.bst` (#490): it ships the identical `files/niri/`
source tree to `/etc/skel/.config/niri/` instead. Every new account now starts
with a real `config.kdl` in place — `useradd --create-home` and `homectl
firstboot` (`docs/design/first-boot-setup.md`) both default their skel
directory to `/etc/skel/` (confirmed `SKEL=/etc/skel` in the shipped
`/etc/default/useradd`; `homectl`'s `--skel=` default per `man homectl`) — so
noctalia's template always hits the *append* branch, not the *create* one.
`config/niri-config.bst`'s `/etc/niri/config.kdl` fallback is kept as-is
alongside this, for any account-creation path that bypasses skel copy; it is
not removed.
```

- [ ] **Step 3: Confirm doc links still resolve**

```bash
mise run docs-links
```

Expected: `==> docs-links passed.`

---

### Task 4: Verify (and, only if needed, fix) the dakota-iso live ISO path

**Files:**
- No changes expected. Investigation already done and recorded in issue #490: `live/Containerfile` (kitten-lily/dakota-iso) stage 3 is `FROM ghcr.io/${REGISTRY}/${TARGET}:${TAG}` — for `TARGET=krytis` this is the real published image, so `/etc/skel` (including the new `.config/niri/`) is already present when `live/src/configure-live-krytis.sh` runs `useradd --create-home --uid 1000 --user-group liveuser`, which copies skel by default.
- Only if verification below finds a stub config: modify `live/src/configure-live-krytis.sh` (kitten-lily/dakota-iso) — add an explicit copy alongside the existing manual seed of `~/.local/state/noctalia/.setup-complete` (same file, same style, right after the existing block at the "noctalia: skip first-run welcome popup" comment):

```bash
# ── niri: ensure the real config landed (belt-and-suspenders, see #490) ──────
# Should already be true via useradd --create-home's skel copy (SKEL=/etc/skel
# in the built krytis image), but this live-only script already duplicates the
# noctalia .setup-complete seed for the same reason (defensive redundancy for
# a live-ISO-critical path) — match that precedent if the actual verification
# below shows skel copy did not fire here.
if [ ! -s /home/liveuser/.config/niri/config.kdl ]; then
    mkdir -p /home/liveuser/.config/niri
    cp -a /etc/skel/.config/niri/. /home/liveuser/.config/niri/
    chown -R liveuser:liveuser /home/liveuser/.config/niri
fi
```

**Interfaces:**
- Consumes: `config/niri-skel.bst` (Task 1) must already be built into the krytis image this is tested against — build/publish krytis first (or at minimum `mise run load-image` locally) before running this task.
- Produces: nothing consumed by other tasks — this is a leaf verification.

- [ ] **Step 1: Build (or pull) a krytis image that includes Task 1/2's change**

This needs an environment that can actually run `mise build`/`mise run load-image` to completion (BST-build-dependent — see Global Constraints; likely not the same environment that wrote this plan). Confirm `localhost/krytis:latest` (or whatever ref is being tested) was built *after* Task 2's commit:

```bash
podman inspect localhost/krytis:latest --format '{{.Created}}'
git -C /path/to/krytis log -1 --format=%cI 490-seed-niri-config-via-skel -- elements/stacks/desktop.bst
```

The image's `Created` timestamp must be later than the branch commit's.

- [ ] **Step 2: Build the krytis live ISO** (from the `kitten-lily/dakota-iso` checkout, sibling of the krytis checkout — already cloned at `/home/lily/Projects/dakota-iso` as of this plan being written)

```bash
cd /path/to/krytis
mise run build-iso --debug
```

`--debug` is required so the live session is SSH-reachable for the check below (`docs/skills/mise.md` § `mise/tasks/build-iso` delegates to dakota-iso's `just iso-sd-boot`).

- [ ] **Step 3: Boot the ISO and inspect `liveuser`'s niri config**

Follow the existing live-session SSH pattern (`docs/skills/pam.md` § dakota-iso's E2E gate: `sshpass -p live ssh liveuser@127.0.0.1 -p <forwarded-port>` once the live session is up — `mise run boot-iso` / dakota-iso's `run-iso` just recipe starts it). Then:

```bash
ssh liveuser@127.0.0.1 -p <port> 'wc -l ~/.config/niri/config.kdl; cat ~/.config/niri/config.kdl'
```

Expected: the real multi-line krytis `config.kdl` (matching `files/niri/config.kdl`'s line count), **not** a 1-line file containing only `include "noctalia.kdl"`.

- [ ] **Step 4a (if the check passes):** No further action. Note the confirmed result on issue #490 and close it as part of this PR (or a follow-up comment if the PR merges first).

- [ ] **Step 4b (if the check finds a stub or missing file):** Apply the `configure-live-krytis.sh` patch shown above in the `kitten-lily/dakota-iso` checkout, on its own branch (dakota-iso has no issue tracker entry for this — descriptive branch name per `AGENTS.md`'s "No issue" row, e.g. `fix/niri-skel-live-copy`). Update `docs/skills/krytis-live-config.md` in that same repo, in the same commit, recording why the explicit copy was needed (this is the cross-repo case — see Global Constraints and `AGENTS.md`'s Cross-repo exception: both PRs opened in the same session, commits cross-reference each other).

---

### Task 5: Commit and open the PR

**Files:** all of the above.

- [ ] **Step 1: Stage and commit (krytis side)**

```bash
cd /path/to/krytis-worktree
git add elements/config/niri-skel.bst elements/stacks/desktop.bst docs/skills/desktop.md
git commit -m "feat(niri): seed config via /etc/skel, fix noctalia template clobber

Closes #490

Assisted-by: Claude Sonnet 5"
```

If Task 4 required a dakota-iso change, do **not** fold it into this commit — it belongs in the dakota-iso PR (Cross-repo exception, Global Constraints above).

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin 490-seed-niri-config-via-skel
gh pr create --repo starlit-os/krytis \
  --base main --head 490-seed-niri-config-via-skel \
  --title "feat(niri): seed config via /etc/skel, fix noctalia template clobber" \
  --body "Closes #490. See docs/plans/2026-08-05-seed-niri-config-via-skel.md for the full investigation and plan."
```

Mark **draft** if Task 4's live-ISO verification (or the `mise build`/`lint`/`boot-test` gates) hasn't been run yet in a capable environment — same posture as PR #487. Include in the PR description exactly which checks were and weren't run, and what's still needed before merge (mirror the "Verification" / "Verification plan" split used in PR #487's description).

- [ ] **Step 3: Archive this plan on merge**

```bash
git mv docs/plans/<file> docs/plans/done/
```

Per `AGENTS.md` § Plan & Design Docs — do this in the merging PR, not as a separate follow-up.
