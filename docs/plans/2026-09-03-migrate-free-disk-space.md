# Migrate `remove-unwanted-software` → `hastd/free-disk-space` — Implementation Plan

**Issue:** [starlit-os/krytis#703](https://github.com/starlit-os/krytis/issues/703) (no parent — top-level)

**Goal:** Fix the Renovate Dependency Dashboard lookup failure on
`ublue-os/remove-unwanted-software` (no `v10` tag was ever cut upstream, so the
`github-tags` datasource cannot resolve a digest) by replacing that action with
`hastd/free-disk-space` in `.github/workflows/cache-warm.yml` and
`.github/workflows/publish.yml` — option (a) from the issue, matching
`zirconium-hawaii`'s already-proven migration.

## Key finding that simplifies the migration: no input mapping is needed

The issue body assumed `remove-dotnet`/`remove-android` → default behavior and
`extra-squeeze` → explicit `include:` paths would need working out. Reading
both actions' `action.yml` at the exact pinned commits shows this isn't
necessary — **both workflows can adopt `hastd/free-disk-space` with zero
`with:` inputs** and free comparable-or-more space:

- **The old action's per-tool boolean inputs (`remove-dotnet`,
  `remove-android`, `remove-haskell`, `remove-codeql`) do nothing at
  `695eb75b` — confirmed for *both* workflows, not just `publish.yml`.**
  `publish.yml`'s existing comment (#389) already documented this for its own
  `extra-squeeze` input; reading the same `action.yml` shows the composite
  step runs one fixed `rm -rf` list unconditionally, `extra-squeeze` is the
  *only* input it reads, and every input `cache-warm.yml` passes
  (`remove-dotnet`/`remove-android`/`remove-haskell`/`remove-codeql`) is
  silently ignored (composite actions warn, not error, on unrecognized
  inputs). So `cache-warm.yml`'s "remove-codeql: true" has never actually
  removed `/opt/hostedtoolcache` — that only happens with `extra-squeeze:
  true`, which `cache-warm.yml` never sets.

- **`hastd/free-disk-space`'s default path list is a superset of what the old
  action's fixed list + `extra-squeeze` actually deleted.** Diff (old action's
  real behavior, both flags on, vs. new action's bare defaults):

  | Old (`695eb75b`, extra-squeeze=true) | New default equivalent |
  |---|---|
  | `/opt/PyPy /opt/az /opt/node /opt/pipx /opt/go /opt/Ruby` | `/opt/{az,pipx}` + `/opt/hostedtoolcache/{PyPy,node,go,Ruby}` |
  | `/usr/lib/llvm-*` | `/usr/lib/llvm-*` (exact) |
  | `/usr/local/julia*` | `/usr/local/julia1.12.1` (versioned, not globbed) |
  | `/usr/local/lib/android` | `/usr/local/lib/android` (exact) |
  | `/usr/share/dotnet` | `/usr/share/dotnet` (exact) |
  | `/usr/share/swift` | `/usr/share/swift` (exact) |
  | `/usr/local/.ghcup` | `/usr/local/.ghcup` (exact) |
  | `/usr/lib/firefox` | `/usr/lib/firefox` (exact) |
  | `/opt/google/chrome` | `/opt/google` (whole dir, broader) |
  | `/opt/microsoft/msedge` | `/opt/microsoft` (whole dir, broader) |
  | `/usr/share/miniconda /opt/hostedtoolcache` (extra-squeeze) | `/usr/share/miniconda` + `/opt/hostedtoolcache/{CodeQL,PyPy,Python,Ruby,go,node}` |

  Plus the new default additionally removes `/etc/skel`, `/home/packer`,
  `/opt/hostedtoolcache/{CodeQL,Python}`, `/usr/lib/google-cloud-sdk`,
  `/usr/local/{aws-cli,aws-sam-cli}`, `/usr/local/lib/node_modules`,
  `/usr/local/share/{chromium,powershell}` — none of which either workflow
  needs (neither uses `actions/setup-python`/`setup-node`/hosted npm; both
  install Python via `uv`/mise, not the runner's hosted toolcache).

  `swapoff` defaults to `true` (matches old `sudo swapoff -a || true`
  unconditionally), and `skip-if-available` defaults to unset, so the new
  action also always runs unconditionally like the old one.

  Net effect: dropping `cache-warm.yml`'s four dead booleans and
  `publish.yml`'s `extra-squeeze: "true"` and using bare defaults is not a
  behavior regression — it's closer to `extra-squeeze: true` behavior on
  *both* workflows than what `cache-warm.yml` gets today.

- Both workflows end up with the **identical** step (no `with:` block),
  so verifying the new action once (via `cache-warm.yml`, the cheaper of the
  two to test — see Task 6) is sufficient evidence for both.

## Pin

```
uses: hastd/free-disk-space@78ec0490f953d89f024c95d0c293e6307ceac02e # v0.1.1
```

Verified: `v0.1.1` is an annotated, SSH-signature-verified tag
(`verification.verified: true`) whose target commit is exactly
`78ec0490f953d89f024c95d0c293e6307ceac02e`. Confirmed via
`GET /repos/hastd/free-disk-space/git/refs/tags/v0.1.1` →
`GET .../git/tags/<tag-sha>`.

**Deliberately one release behind newest (`v0.1.2`), not the tip.** The
issue's own recommendation and `zirconium-hawaii`'s pin both point at
`v0.1.2` (`68572aeaadb7f76bd408246328e95926323402b5`) — diffed
`v0.1.1...v0.1.2` via GitHub's compare API (`ahead_by: 4`) and the only
functional change in `action.yml` is an opt-in `skip-if-available` input
(default empty); the default path-removal list is byte-identical between the
two. So pinning `v0.1.1` costs nothing behaviorally and leaves Renovate a
real minor bump (`v0.1.1` → `v0.1.2`) to open once this merges — proof the
`github-tags` lookup that broke on the old action now resolves an actual
update end-to-end, not just that `--dry-run` extraction succeeds. That bump
falls under the existing blanket `digest`/`pin`/`patch`/`minor` automerge
rule already in `renovate.json5`, so no config change is needed for it to
land on its own.

## Global Constraints

- No RPMs, no dnf, no container overlays — N/A here (CI-only change), but
  keep in scope per `AGENTS.md`.
- **Org allowlist gate (blocking, cannot self-serve):** `hastd/free-disk-space`
  is a new `owner/repo` krytis has never used. `docs/skills/ci-runner.md` §
  Org allowlist: any `uses:` not already on the `starlit-os` org's allowed-
  actions list is blocked at runtime with a permissions error, and the org
  policy API needs org-admin (`gh api orgs/starlit-os/actions/permissions/
  selected-actions` → `403` for this session, confirmed 2026-09-03). **A
  human with org-admin must add `hastd/free-disk-space` to the allowlist
  before either workflow can actually run the migrated step** — flag this
  explicitly when opening the PR, same pattern as PR #689's
  `actions/upload-artifact` allowlist gap.
- Skill file update lands in the **same commit** as the workflow change
  (`AGENTS.md` Self-Improvement Loop) — Task 5 below.
- Renovate config needs no change: no existing `packageRules` entry
  references `ublue-os/remove-unwanted-software` (confirmed by reading
  `.github/renovate.json5` — the lookup failure was a hard error, not a
  suppressed/disabled rule), and the new dependency falls under the existing
  blanket `matchUpdateTypes: ["digest","pin","patch","minor"]` automerge rule
  with no exception needed (not in the `click`/`dulwich`/`buildstream*`
  manual-merge list).
- Worktree: not yet created. Issue #703 has no parent, so per `AGENTS.md`'s
  top-level convention: `krytis.worktrees/ci/gh703-fix-remove-unwanted-
  software-renovate-lookup`, branch `703-fix-remove-unwanted-software-
  renovate-lookup`.

---

### Task 1: Create the worktree

```bash
cd /var/home/lily/Projects/StarlitOS/krytis
git worktree add -b 703-fix-remove-unwanted-software-renovate-lookup \
  ../krytis.worktrees/ci/gh703-fix-remove-unwanted-software-renovate-lookup
```

---

### Task 2: Migrate `cache-warm.yml`

**Files:** `.github/workflows/cache-warm.yml` (currently lines 31-37)

- [ ] Replace:

```yaml
      - name: Maximize build space
        uses: ublue-os/remove-unwanted-software@695eb75bc387dbcd9685a8e72d23439d8686cba6 # v10
        with:
          remove-dotnet: "true"
          remove-android: "true"
          remove-haskell: "true"
          remove-codeql: "true"
```

  with:

```yaml
      - name: Maximize build space
        # ublue-os/remove-unwanted-software has had no push since 2025-10-10
        # and no v10 tag was ever cut, breaking Renovate's github-tags lookup
        # (#703). hastd/free-disk-space is properly tagged, actively
        # maintained, and its bare defaults already free more space than the
        # old action's fixed removal list ever did with these inputs — see
        # docs/skills/ci-runner.md § remove-unwanted-software migration for
        # the full path-by-path comparison.
        #
        # Deliberately pinned to v0.1.1, not the newest v0.1.2 — see the Pin
        # section above: leaves Renovate a real minor bump to prove the fix.
        uses: hastd/free-disk-space@78ec0490f953d89f024c95d0c293e6307ceac02e # v0.1.1
```

---

### Task 3: Migrate `publish.yml`

**Files:** `.github/workflows/publish.yml` (currently lines 77-85)

- [ ] Replace:

```yaml
      - name: Maximize build space
        # This pinned SHA's action.yml only accepts `extra-squeeze` (verified
        # against ublue-os/remove-unwanted-software@695eb75... directly) — the
        # remove-dotnet/remove-android/remove-haskell/remove-codeql inputs
        # cache-warm.yml uses predate this pin and are silently ignored
        # (composite actions warn, not error, on unrecognized inputs). See #389.
        uses: ublue-os/remove-unwanted-software@695eb75bc387dbcd9685a8e72d23439d8686cba6 # v10
        with:
          extra-squeeze: "true"
```

  with:

```yaml
      - name: Maximize build space
        # Migrated off ublue-os/remove-unwanted-software (#703, untagged
        # upstream broke Renovate). hastd/free-disk-space's bare defaults
        # already cover what extra-squeeze: true used to remove (miniconda +
        # hostedtoolcache) plus more — see docs/skills/ci-runner.md § remove-
        # unwanted-software migration. Same step as cache-warm.yml verbatim,
        # including the deliberate v0.1.1 (not newest v0.1.2) pin.
        uses: hastd/free-disk-space@78ec0490f953d89f024c95d0c293e6307ceac02e # v0.1.1
```

---

### Task 4: Sanity-check both workflow files parse

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/cache-warm.yml'))" && echo OK
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/publish.yml'))" && echo OK
```

---

### Task 5: Update `docs/skills/ci-runner.md` (same commit)

**Files:** `docs/skills/ci-runner.md`, new subsection under "GitHub Actions:
SHA Pinning and Org Allowlist"

- [ ] Add a `### remove-unwanted-software migration (#703)` entry recording:
  - The old action's per-tool boolean inputs were dead code at the pinned SHA
    (only `extra-squeeze` was ever read; `cache-warm.yml`'s four booleans did
    nothing) — so if this ever needs re-litigating, don't trust the input
    names, read the composite `action.yml` at the exact pinned commit.
  - The path-list diff table showing `hastd/free-disk-space`'s bare defaults
    are a superset of what the old action + `extra-squeeze` removed.
  - The org-allowlist gate this migration hit, and that it needed a human
    org-admin action (not resolvable by an agent session).

---

### Task 6: Verify with a real CI run

**Decision:** test via `cache-warm.yml`'s `workflow_dispatch` only, not
`publish.yml`. Both workflows end up with an identical, input-free step
(Tasks 2-3), so one real run proves the action for both — and
`cache-warm.yml` is non-blocking (`exit 0` on build failure, no image push,
no signing) versus `publish.yml`, which would push a real `:latest` tag to
`ghcr.io/starlit-os/krytis` even in branch-test mode. No reason to take on
that blast radius just to re-prove an already-shared step.

- [x] Pushed the branch, dispatched `cache-warm.yml`.
      First dispatch (`run 33750706783`) hit `startup_failure` with zero
      jobs — the exact documented allowlist-block signature ("the workflow
      job simply won't start"); the org's `hastd/free-disk-space` allowlist
      entry was initially misformatted. After it was corrected, re-dispatch
      (`run 33750902153`) went `in_progress`, and the "Maximize build space"
      step completed with `conclusion: success` in 6s
      (`started_at 11:39:57Z` → `completed_at 11:40:03Z`).
- [x] Confirmed the step ran clean (no script/permission error) via the
      GitHub Actions API. **Could not** pull raw `df -h` before/after log
      text for a byte-for-byt comparison: GitHub withholds step logs until
      the whole job completes, and `cache-warm.yml` is a multi-hour BST
      build (`timeout-minutes: 360`) — not worth running to completion just
      to read log text, so the run was cancelled once the step's success
      was confirmed. A clean `success` conclusion (vs. the prior run's
      `startup_failure`) is treated as sufficient proof the action itself
      executes correctly under real GitHub Actions conditions; the
      path-by-path analysis in "Key finding" above is the evidence for
      "comparable-or-more space freed."

---

### Task 7: Verify Renovate resolves cleanly

```bash
mise run renovate-check --dry-run    # hastd/free-disk-space extracted, no lookup error;
                                      # ublue-os/remove-unwanted-software gone entirely
mise run renovate-check --explain    # confirm hastd/free-disk-space falls under the
                                      # blanket digest/pin/patch/minor automerge rule
```

**Blocked by a pre-existing local host gap, not by this change.**
`mise run renovate-check --dry-run` failed pulling
`ghcr.io/renovatebot/renovate:latest` with `potentially insufficient UIDs or
GIDs available in user namespace` — this workstation's `/etc/subuid`/
`/etc/subgid` have no range for `lily` (`podman info` shows only a
single-UID `{0 60339 1}` rootless mapping), so podman can't unpack a
multi-layer image needing UID remapping. Fixing it needs
`sudo usermod --add-subuids`/`--add-subgids` (interactive `sudo`, not
available to this session — confirmed via `sudo -n true`). Unrelated to
`.github/renovate.json5` (untouched by this PR) or the workflow changes.

Not a blocker for #703's acceptance criteria: the issue's wording accepts
either `--dry-run` **or** the next real dashboard run as proof. Task 9 below
covers the real end-to-end check post-merge, which is the stronger signal
anyway (an actual bump PR opening and auto-merging, not just extraction
succeeding).

---

### Task 8: Open the PR

- [x] Link the `cache-warm.yml` dispatch run
      (https://github.com/starlit-os/krytis/actions/runs/33750902153,
      "Maximize build space" step `conclusion: success`) as verification
      evidence. `renovate-check --dry-run`/`--explain` output not available
      (Task 7's local podman/subuid gap) — deferred to Task 9's real
      post-merge check instead.
- [x] Org allowlist: `hastd/free-disk-space` added to the `starlit-os` org's
      allowed-actions list by a human org-admin (2026-09-03, confirmed by the
      user out of band — this session still has no `admin:org` scope to
      verify the list contents directly, so Task 6's real dispatch run is the
      empirical proof it took effect).
- [x] Confirm `docs/skills/ci-runner.md` (Task 5) is in the same commit as the
      workflow changes (Tasks 2-3), not a follow-up.

---

### Task 9: Confirm the Renovate bump PR (post-merge)

After this PR merges to `main`, Renovate's next run should open a
`v0.1.1` → `v0.1.2` PR for `hastd/free-disk-space` and auto-merge it
unattended (falls under the blanket automerge rule — no `prBodyNotes`
exception applies). This is the real end-to-end proof of #703, stronger than
`--dry-run`.

- [ ] After merge, check the Dependency Dashboard issue (#3) — the
      `ublue-os/remove-unwanted-software` lookup-failure line should be gone.
- [ ] Confirm a `hastd/free-disk-space` bump PR appears
      (`gh pr list --search "free-disk-space"`) and auto-merges within
      seconds of its check run completing, same pattern documented in
      `docs/skills/renovate.md` § Auto-merge works here despite no
      `pull_request` workflow.
- [ ] If no PR appears within a normal Renovate cycle, or it doesn't
      auto-merge, that means something about the new dependency's config is
      still wrong — re-open investigation, don't just re-run `--dry-run`
      again (it already passed and wasn't sufficient).
