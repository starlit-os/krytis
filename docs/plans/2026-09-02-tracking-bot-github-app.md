# GitHub App for Tracking-PR Auto-Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `track-bst-sources.yml` PRs from landing with `Checks` stuck in `action_required` (issue #656, Option A) by opening them with a GitHub App installation token instead of `GITHUB_TOKEN`.

**Architecture:** A GitHub App owned by `starlit-os`, installed only on `krytis`, with `contents: write` + `pull-requests: write`. Each of the 24 tracking jobs mints a short-lived installation token via `actions/create-github-app-token` right after checkout, and the existing "Create or update PR" step's `GH_TOKEN` env var — currently `secrets.GITHUB_TOKEN` — switches to that token. `gh pr create`/`gh pr edit`/`gh api graphql` (via `scripts/commit-tracking-update.sh`, #699) all read `GH_TOKEN` from that same step env, so this one change re-points every GitHub-write call in the step at the App token. `pull_request` events opened by a GitHub App installation token do not get the `GITHUB_TOKEN`-specific approval-required treatment — that's the entire fix.

**Tech Stack:** GitHub Apps, `actions/create-github-app-token`, GitHub Actions secrets, YAML, `gh api`.

## Global Constraints

- App permissions must be exactly `contents: write` + `pull-requests: write` (+ mandatory `metadata: read`) — no broader scope than the jobs need.
- Install the App on `starlit-os/krytis` only, not org-wide.
- Private key is a repo secret (`TRACKING_APP_PRIVATE_KEY`), never committed, never handled by an agent outside the GitHub Actions secrets UI/`gh secret set`.
- `actions/create-github-app-token` pinned to a full commit SHA with a version comment, matching every other `uses:` in this repo (AGENTS.md § SHA pinning).
- Only the `GH_TOKEN` inside each job's **"Create or update PR"** step changes. Every other `secrets.GITHUB_TOKEN` use in the workflow (release-data lookups in "Update mise element" and similar steps) stays as-is — those don't open PRs and don't need the App token.
- This plan supersedes issue #656's Options B and C — once merged and verified, close #656 referencing this plan.

---

### Task 1: Create the GitHub App — human, Security Gate

Per AGENTS.md, provisioning auth/secrets is a human decision point. Do this in a browser, not via an agent.

**Files:** none — this is entirely in the GitHub UI.

- [ ] **Step 1: Create the App**

Go to `https://github.com/organizations/starlit-os/settings/apps/new`. Fill in:

| Field | Value |
|---|---|
| GitHub App name | `krytis-tracking-bot` (must be globally unique on GitHub; if taken, try `krytis-source-tracker`) |
| Homepage URL | `https://github.com/starlit-os/krytis` |
| Webhook → Active | **unchecked** — this App only mints tokens, no webhook events needed |
| Repository permissions → Contents | **Read and write** |
| Repository permissions → Pull requests | **Read and write** |
| Where can this GitHub App be installed? | **Only on this account** |

Leave every other permission at "No access". Click **Create GitHub App**.

- [ ] **Step 2: Generate and download the private key**

On the App's settings page, scroll to **Private keys** → **Generate a private key**. A `.pem` file downloads. Note the **App ID** shown near the top of the same page (a short integer, e.g. `123456`) — needed in Task 2.

- [ ] **Step 3: Install the App on krytis only**

App settings → **Install App** (left sidebar) → next to `starlit-os`, click **Install** → choose **Only select repositories** → select `krytis` → **Install**.

### Task 2: Provision secrets — human, Security Gate

**Files:** none — GitHub repo secrets, not a file in the tree.

- [ ] **Step 1: Set the two secrets**

```bash
gh secret set TRACKING_APP_ID --repo starlit-os/krytis --body "<App ID from Task 1 Step 2>"
gh secret set TRACKING_APP_PRIVATE_KEY --repo starlit-os/krytis < /path/to/downloaded-private-key.pem
```

- [ ] **Step 2: Verify both are set (names only — GitHub never returns secret values)**

```bash
gh secret list --repo starlit-os/krytis
```

Expected: `TRACKING_APP_ID` and `TRACKING_APP_PRIVATE_KEY` both listed.

- [ ] **Step 3: Delete the local private key file**

```bash
shred -u /path/to/downloaded-private-key.pem  # or securely delete by your platform's equivalent
```

It must not remain on disk once it's in the GitHub secrets store.

### Task 3: Wire the token into the workflow — agent

**Files:**
- Modify: `.github/workflows/track-bst-sources.yml`

Both anchor patterns below are verified uniform across all 24 jobs on current `main` (checked directly, not assumed):
- `- name: Checkout repository` → `uses: actions/checkout@...` → `with: fetch-depth: 0` → blank line → `- name: Setup mise`: **24/24** jobs match exactly.
- `- name: Create or update PR` → `if: ...` → `env:` → `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`: **24/24** jobs match exactly. No special cases this time (unlike #699's two stragglers) — every job already has the identical 4-line shape post-#699.

- [ ] **Step 1: Insert the token-mint step after every "Checkout repository" step**

```python
import re, pathlib

p = pathlib.Path(".github/workflows/track-bst-sources.yml")
text = p.read_text()

checkout_anchor = re.compile(
    r'(      - name: Checkout repository\n'
    r'        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n'
    r'        with:\n'
    r'          fetch-depth: 0\n'
    r'\n)'
    r'(      - name: Setup mise\n)'
)

token_step = (
    '      - name: Generate tracking bot token\n'
    '        id: app-token\n'
    '        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n'
    '        with:\n'
    '          app-id: ${{ secrets.TRACKING_APP_ID }}\n'
    '          private-key: ${{ secrets.TRACKING_APP_PRIVATE_KEY }}\n'
    '\n'
)

new_text, count = checkout_anchor.subn(lambda m: m.group(1) + token_step + m.group(2), text)
assert count == 24, f"expected 24 insertions, got {count}"
p.write_text(new_text)
print(f"inserted token-mint step in {count} jobs")
```

- [ ] **Step 2: Re-point `GH_TOKEN` in every "Create or update PR" step at the new token**

```python
import re, pathlib

p = pathlib.Path(".github/workflows/track-bst-sources.yml")
text = p.read_text()

pr_step_anchor = re.compile(
    r'(      - name: Create or update PR\n'
    r'        if: [^\n]+\n'
    r'        env:\n'
    r'          )GH_TOKEN: \$\{\{ secrets\.GITHUB_TOKEN \}\}\n'
)

new_text, count = pr_step_anchor.subn(
    lambda m: m.group(1) + 'GH_TOKEN: ${{ steps.app-token.outputs.token }}\n',
    text,
)
assert count == 24, f"expected 24 replacements, got {count}"
p.write_text(new_text)
print(f"re-pointed GH_TOKEN in {count} Create-or-update-PR steps")
```

- [ ] **Step 3: Verify no other `secrets.GITHUB_TOKEN` uses were touched**

```bash
grep -c "secrets.GITHUB_TOKEN" .github/workflows/track-bst-sources.yml
grep -c "steps.app-token.outputs.token" .github/workflows/track-bst-sources.yml
grep -c "actions/create-github-app-token" .github/workflows/track-bst-sources.yml
```

Expected: the `steps.app-token.outputs.token` count is exactly `24`; the `actions/create-github-app-token` count is exactly `24`; `secrets.GITHUB_TOKEN` still appears in every job's other steps (release-data lookups, `mise run <name>-update`, etc.) — count should be noticeably more than 0 and should **not** have dropped to 0, confirming Step 2 only touched the PR-creation step, not the read-only lookups.

- [ ] **Step 4: Validate YAML and shell syntax**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/track-bst-sources.yml')); print('YAML OK, jobs:', len(d['jobs']))"
```

Expected: `YAML OK, jobs: 24`.

- [ ] **Step 5: Spot-check one standard job and the two structurally distinct jobs**

```bash
sed -n '61,72p' .github/workflows/track-bst-sources.yml   # track-linux-cachyos: token step present, checkout->token->setup-mise order
grep -A2 "app-token.outputs.token" .github/workflows/track-bst-sources.yml | grep -B1 "core-junctions" -A1 || true
```

Confirm by eye: `track-linux-cachyos` (standard single-file job), `track-core-junctions` (hardcoded branch/title, no stash — different `Create or update PR` body, same env-block shape), and `track-tarball` (matrix job) all show the token-mint step and the re-pointed `GH_TOKEN`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/track-bst-sources.yml
git commit -m "ci(track-bst-sources): open PRs with a GitHub App token

github-actions[bot]-opened pull_request events land every tracking PR
with Checks stuck in action_required, requiring a human Approve click
before anything runs -- unconditional, regardless of PR content
(#656). A GitHub App installation token does not get this treatment.

Every job mints a short-lived, repo-scoped token via
actions/create-github-app-token right after checkout and uses it for
the Create-or-update-PR step's GH_TOKEN -- the only step that opens
PRs. Every other secrets.GITHUB_TOKEN use (release-data lookups) is
untouched.

Closes #656."
```

### Task 4: Document the App — agent

**Files:**
- Modify: `docs/skills/bst.md` (§ around "Wiring the CI job" / the track-mise reference section — same neighborhood #699's lessons landed in)

- [ ] **Step 1: Add a subsection documenting the App and its scope**

Insert after the "Signed commits via `scripts/commit-tracking-update.sh`" section added by #699 (search `docs/skills/bst.md` for that heading to find the exact insertion point — it will have moved from any specific line number given later edits):

```markdown
### GitHub App token for opening tracking PRs

Every job mints a token via `actions/create-github-app-token` (the `krytis-tracking-bot` App, installed only on this repo, `contents: write` + `pull-requests: write`) and uses it for the "Create or update PR" step's `GH_TOKEN` — not `secrets.GITHUB_TOKEN`. Reason: a `pull_request` event opened by a workflow authenticated as `GITHUB_TOKEN` always lands with `Checks` in `action_required`, needing a human Approve click before anything runs, regardless of PR content (#656). A GitHub App installation token doesn't get this treatment.

Only the PR-opening step uses the App token. Every other `secrets.GITHUB_TOKEN` use in this workflow (release-data lookups in `mise run <name>-update` and similar) is untouched — those don't open PRs and don't need it.

App ID and private key: `TRACKING_APP_ID` / `TRACKING_APP_PRIVATE_KEY` repo secrets. Rotating the key: generate a new one on the App's settings page, `gh secret set TRACKING_APP_PRIVATE_KEY < new-key.pem`, then revoke the old key from the App settings page — installation tokens are minted fresh per run, so there's no in-flight token to invalidate.
```

- [ ] **Step 2: Verify docs links still resolve**

```bash
mise run docs-links
```

Expected: `docs-links passed.`

- [ ] **Step 3: Commit**

```bash
git add docs/skills/bst.md
git commit -m "docs(bst): document the tracking-bot GitHub App"
```

### Task 5: Verify end to end — agent + human

**Files:** none — verification only.

- [ ] **Step 1: Push the branch and open the PR**

```bash
git push -u origin <branch>
gh pr create --repo starlit-os/krytis --title "ci(track-bst-sources): open PRs with a GitHub App token" --body-file <body-file>
```

- [ ] **Step 2: Merge it**

This is a Merge Gate item — human clicks merge (per the established `main` merge-commit flow from #697). Wait for this before Step 3; the fix can only be observed once it's live on `main`, since `track-bst-sources.yml`'s "Create or update PR" step only runs when `github.ref == 'refs/heads/main'`.

- [ ] **Step 3: Dispatch a real tracking job on `main`**

```bash
gh workflow run track-bst-sources.yml --repo starlit-os/krytis --ref main -f group=mise
```

Pick whichever group currently has real pending drift — check `gh pr list --repo starlit-os/krytis --search "head:auto/track"` first; re-running a job with no drift skips the PR-creation step entirely and proves nothing.

- [ ] **Step 4: Confirm the resulting PR's checks did not land in `action_required`**

```bash
gh run list --repo starlit-os/krytis --branch auto/track-mise --limit 3 --json databaseId,conclusion,workflowName
```

Expected: `conclusion` is `success`, `null` (still running), or anything other than `action_required` — no manual approve step needed this time. Contrast with the pre-fix behavior documented in #656 (every run landed `action_required` unconditionally).

- [ ] **Step 5: Confirm the PR shows the App as the actor, not `github-actions[bot]`**

```bash
gh pr view <pr-number> --repo starlit-os/krytis --json author
```

Expected: `author.login` is the App's bot identity (`krytis-tracking-bot[bot]` or similar), not `app/github-actions`.

- [ ] **Step 6: Close #656 with this evidence**

```bash
gh issue comment 656 --repo starlit-os/krytis --body "Closed via <PR URL>. Verified: PR #<n> opened by the App, run <run-id> conclusion=<conclusion>, no action_required gate. Closing."
gh issue close 656 --repo starlit-os/krytis
```

---

## Self-Review

**Spec coverage:** Option A's every stated component is covered — App creation (Task 1), installation token minting via `actions/create-github-app-token` (Task 3), secrets (Task 2), and the "not what it looks like" causes from the issue (fork-PR policy, self-approval) don't need tasks since Option A sidesteps both by construction (same-repo App install, App token isn't `GITHUB_TOKEN` so the approval gate never triggers).

**Placeholder scan:** No TBD/TODO. Every code step is the actual script or exact command, not a description of one. The two regex transforms are real, tested-pattern (24/24 verified against live `main` before writing this plan, not assumed).

**Type consistency:** `steps.app-token.outputs.token` (Task 3 Step 2) matches the step `id: app-token` set in Task 3 Step 1 — same identifier throughout.
