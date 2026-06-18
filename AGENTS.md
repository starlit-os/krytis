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

**Before marking your work complete:**

- [ ] Did I discover any workaround, non-obvious pattern, or convention?
- [ ] Is there a skill file for the area I worked in?
- [ ] If yes — did I update it?
- [ ] If no — did I create one?
- [ ] Is the skill file committed in the same PR?

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

**Operator accountability:** The human deploying the agent is responsible for all decisions.

**Verification:** Every PR must confirm `mise lint` passed and the image booted. Use `mise boot-test` for automated pass/fail. No WIP PRs.

**Mise task integrity:** All maintenance tasks must be `mise` tasks. No loose shell commands. If a task isn't covered by an existing task, add one alongside your change. Every agent action must be replicable by a human via `mise <task>`. Do not rename existing tasks without explicit human approval.

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

| Scenario | Path |
|---|---|
| Issue (top-level) | `<base>/gh<number>-<slug>` |
| Issue with parent issue | `<base>/gh<parent-number>/<number>-<slug>` |
| No issue | `<base>/<branch-name>` |

Platform prefixes: `gh` = GitHub · `gl` = GitLab · `bb` = Bitbucket.

### Branch name

Mirrors the worktree leaf name, **without** the platform prefix:

| Scenario | Branch |
|---|---|
| Issue | `<number>-<slug>` (e.g. `42-fix-composefs-boot-failure`) |
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
