# AGENTS.md

Krytis is a [BuildStream 2](https://buildstream.build/) project producing a bootc OCI desktop image built on [Freedesktop SDK](https://gitlab.com/freedesktop-sdk/freedesktop-sdk). No RPMs. No dnf. No container package overlays. BST elements only.

Stack: **niri** (Wayland compositor) + **greetd** + **noctalia-greeter** + **bootc**.

Load **[docs/SKILL.md](docs/SKILL.md)** for the full reference skill tree. Only load docs relevant to your task.

---

## The Self-Improvement Loop

> **This is the core operating model. Read it.**

Every agent session produces two outputs:
1. **The work** — the PR, fix, or improvement.
2. **The learning** — what you discovered that a future agent should know.

Output 1 without Output 2 leaves the system no smarter. **The loop only compounds if agents write back.**

```
Agent works on task
  └─ discovers pattern / workaround / convention
       └─ writes it to the relevant skill file in docs/skills/
            └─ commits in the same PR
                 └─ next agent starts smarter
                      └─ loop
```

### Skill-improvement mandate

The skill file update is part of the implementation — not a post-task step. Update `docs/skills/` **before you commit**, not after you open the PR. A learning committed as a follow-up is a failure of the loop.

**When you hit a non-obvious pattern, workaround, or convention — before your next commit:**

1. Open the relevant `docs/skills/` file (or create one).
2. Add the entry.
3. Stage it alongside your change.
4. Commit them together.

**Cross-repo exception.** Some work spans two repositories — most commonly a code change in the `dakota-iso` fork paired with its skill entry in this repo's `docs/skills/` tree. A single commit cannot span two repos, so "commit them together" is impossible there. It is satisfied instead when **both** hold:

- The skill entry lands in the paired PR (the two PRs are opened/updated in the same work session), and
- The code commit message references the skill entry, or the skill commit references the code commit SHA — so the pairing is traceable.

This substitution counts as same-commit compliance for §3 below; it does **not** relax the rule for changes that are wholly within one repo.

**Before opening a PR — confirm:**

- [ ] Did I discover any workaround, non-obvious pattern, or convention?
- [ ] Is the relevant `docs/skills/` file updated and in this PR's commits?
- [ ] If no skill file exists for this area, did I create one?

### Self-diagnosis

The user may request a compliance check at any time by asking for a **skills check** (or running `/skills-check` in Claude Code). When asked, run the following diagnosis and report pass/fail per item with specific evidence. Offer to fix failures in place.

**1. Worktree & branch naming**
- Get the current branch: `git branch --show-current`.
- If the branch addresses a GitHub issue, run `gh issue view <number>` and read the `parent:` field.
- Verify the worktree path (`git worktree list`) matches the AGENTS.md convention for top-level issue, issue-with-parent, or no-issue.

**2. Skill file updates**
- List areas touched: `git diff main...HEAD -- '*.bst' mise/ .github/ docs/`.
- List skill file changes: `git diff main...HEAD -- docs/skills/`.
- For each touched area, confirm the corresponding `docs/skills/` file was updated. Flag any gap, and note whether a skill file exists for that area.

**3. Skill file commit timing**
- List commits: `git log main...HEAD --oneline`.
- Confirm skill file updates appear in the same commit as the change that produced the learning — not in a later commit.
- **Cross-repo work** (e.g. a `dakota-iso` fork change paired with a skill entry here): apply the *Cross-repo exception* in the Skill-improvement mandate. Pass when the skill entry is in the paired PR **and** the two commits cross-reference each other; do not flag the unavoidable two-repo split as a failure.

**4. Memory vs skill file**
- Recall any lessons written to the memory system this session.
- For each, confirm a corresponding `docs/skills/` entry exists. Memory is supplementary; the skill file is the authoritative record.

**Verdict:** summarise Pass / Fail / N/A per item. If any failures, offer to fix them before the PR is opened (or add a commit to the branch if the PR is already open).

**5. Root-cause introspection (required for every failure)**

For each failure found above, answer:
- *What specifically was skipped or missed?*
- *Why wasn't the discipline applied at the time?* Choose the most accurate:
  - **Oversight** — knew the rule, had the information, didn't act on it
  - **Misjudgement** — incorrectly decided this pattern wasn't worth writing back
  - **Rule gap** — the rule as written didn't clearly cover this case
  - **Sequencing error** — planned to do it later; later never came
- *What would have triggered correct behaviour?* (e.g. "checking before committing", "recognising this pattern type earlier")

This step is not optional. A failure reported without a root cause is itself a compliance failure.

### What counts as a learning worth writing back

Write it:
- A workaround for an upstream bug (include component + issue link)
- A non-obvious pattern required for correctness
- A convention that isn't obvious from the code
- Something you had to discover by trial and error

Don't write it:
- One-off task notes ("use commit message X for this PR")
- Obvious things any developer would know
- Ephemeral state ("currently broken, fix pending")

---

## Mandatory Gates

Non-compliance = automatic rejection.

**Read-First:** Read `README.md`, `AGENTS.md`, and `docs/SKILL.md` before modifying anything. Do not assume project structure or patterns.

**Assume the user knows the system:** Default to assuming the human knows krytis and the machine they're currently on — whether that machine is actually running krytis or something else. A static grep of this repo's `.bst` files is not proof of what's on a live system: transitive dependencies (see `docs/skills/bst.md`) and out-of-repo builds both produce real gaps between "what the source says" and "what's installed." Before contradicting a user's claim about running-system state, verify against the live system itself (`systemctl`, `busctl`, `/usr/manifest.json` SBOM, binaries on disk) — not just the dependency graph in this checkout.

**Operator accountability:** The human deploying the agent is responsible for all decisions.

**Verification:** Every PR must confirm `mise lint` passed and the image booted. Use `mise boot-test` for automated pass/fail. No WIP PRs.

**Mise task integrity:** All maintenance tasks must be `mise` tasks. No loose shell commands. If a task isn't covered by an existing task, add one alongside your change. Every agent action must be replicable by a human via `mise <task>`. Do not rename existing tasks without explicit human approval.

**Update path gate:** Before opening a PR that adds a new element, confirm one of:
- (a) The source is `git_repo` with a `track:` glob **and** the element is listed in the `track` matrix in `.github/workflows/track-bst-sources.yml`.
- (b) A `<name>-update` mise task exists **and** a corresponding CI job in `track-bst-sources.yml` follows the `track-mise` pattern.

`bst source track` is a no-op on `kind: tar` and `kind: remote` sources — elements using these source kinds silently fall out of the automated update loop unless option (b) is in place. See `docs/skills/bst.md` § Element update path.

**Agents MUST NOT push directly to `main`.** All changes via PR from a feature branch.

---

## Worktree & Branch Policy

Always create a worktree and branch before starting work. Exception: explicit instruction to work on an existing branch or directly on `main`.

Create both together:

```shell
git worktree add -b <branch> <worktree-path>
```

### Worktree base

Resolved in order — use the first that exists, or create the third:

1. `<repo-root>/.worktrees/`
2. `<parent-dir>/<repo-name>.worktrees/` (e.g. `krytis.worktrees/` — already the family convention)
3. Fall back: create `<parent-dir>/<repo-name>.worktrees/`

### Worktree path

**Before constructing the path:** run `gh issue view <number>` and read the `parent:` field. A non-empty `parent:` requires the nested form — use the parent issue number, not the child's.

| Scenario | Path |
|---|---|
| Issue (top-level) | `<base>/<cc-type>/gh<number>-<slug>` |
| Issue with parent issue | `<base>/gh<parent-number>/<number>-<slug>` |
| No issue | `<base>/<branch-name>` |

`<cc-type>` is the Conventional Commits type that best describes the work: `fix`, `feat`, `ci`, `chore`, `docs`, `refactor`, etc.

Platform prefix (`gh` = GitHub, `gl` = GitLab, `bb` = Bitbucket) appears in two places: the leaf name of top-level issues (`gh<number>-<slug>`) and the parent grouping directory (`gh<parent-number>/`). It does **not** appear on the leaf name of issues that have a parent.

### Branch name

Mirrors the worktree leaf name, **without** the type prefix directory:

| Scenario | Branch |
|---|---|
| Issue (top-level) | `<number>-<slug>` (e.g. `42-fix-composefs-boot-failure`) |
| Issue with parent | `<number>-<slug>` — flat, no parent encoding in the branch name |
| No issue | descriptive name following Conventional Commits style (e.g. `feat/add-greetd-service`) |

### Issue title convention

Issue titles must be **short imperative phrases of ≤ 5 words**. Applies to both agents and humans.

Good: `Fix composefs boot failure` · `Add greetd service` · `Update mise to 2.1`

Bad: `The composefs boot is broken and needs to be fixed` (too long) · `feat: add greetd` (conventional-commit prefixes belong in commits, not issue titles)

### Slug derivation

Issue title → lowercase → spaces and non-alphanumeric chars → hyphens → consecutive hyphens collapsed → leading/trailing hyphens stripped. The ≤ 5-word title constraint means no truncation is needed.

Example: `Fix composefs boot failure` → `fix-composefs-boot-failure`

Worktrees are not automatically deleted — prune manually after merge or abandonment.

**Merge strategy is squash-only**, enforced at the GitHub repo settings level (`allow_squash_merge: true`, `allow_merge_commit: false`, `allow_rebase_merge: false` — not just convention, the other options are disabled). This matters for cleanup:
- `git branch -d <branch>` after merge will refuse — a squashed merge commit has no ancestry link back to the local branch's commits, so git can't see it as "merged." Use `git branch -D` (or check `gh pr view <n> --json state` first) instead of treating the safety check as a signal something's wrong.
- Same applies to worktree pruning — don't rely on `git log --merged` to decide whether a worktree's branch landed; check the PR state directly.

---

## Human Decision Points — Stop and Ask

Agents implement autonomously **except** at these gates. Stop and request human input:

| Gate | When |
|---|---|
| **Design Gate** | Architecture changes, new subsystem design, behavioral changes visible to users |
| **Security Gate** | Auth, signing, supply chain, secrets handling |
| **Breakage Gate** | Changes that affect the boot path, PAM stack, greeter session, or OCI assembly |
| **Merge Gate** | Final PR approval and merge — always human |

When in doubt, open a draft PR with your implementation and ask explicitly.

---

## Verification — Implement and Verify; Humans Approve and Merge

Do not request review without evidence. Before opening a PR for review:

- Link to a CI run, workflow run, or test output that exercises your change.
- If no automated test exists, describe how you manually verified the change.
- Skill file update must be committed in the same PR (not a follow-up).

---

## Development Standards

### Commit format

[Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <description>`

Common types: `feat` `fix` `docs` `ci` `refactor` `chore` `build`

Subject line: soft max 72 characters.

### AI attribution

```
feat(greetd): update to 0.10.4

Closes #NNN

Assisted-by: Claude Sonnet 4.6
```

### SHA pinning (CI actions)

All `uses:` references to external GitHub Actions must be pinned to a full commit SHA with a version comment. Never use floating tags.

---

## PR Comment Policy

**One comment per PR event, max.** Combine all findings into a single comment. Never post a follow-up comment for a new observation — edit the existing one instead.

**Never duplicate GitHub UI state.** Do not post CI pass/fail summaries or approval counts — GitHub already surfaces these.

**When in doubt, don't post.** If the only thing to report is "tests pass", post nothing.
