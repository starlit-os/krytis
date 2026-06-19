# Agent Workflow

Reference for setting up worktrees, branches, and following the self-improvement loop. Load this before starting any implementation task.

## Worktree & Branch Setup

Always create a worktree and branch together before touching any files:

```shell
git worktree add -b <branch> <worktree-path>
```

### Step 1 — resolve the worktree base

Use the first that exists:

1. `<repo-root>/.worktrees/`
2. `<parent-dir>/<repo-name>.worktrees/` (e.g. `krytis.worktrees/`)
3. Neither exists → create option 2

### Step 2 — look up the issue (do this before constructing the path)

```shell
gh issue view <number>
```

Read the `parent:` field in the output. This determines which path form to use.

**Common failure mode:** constructing the path from the issue number alone and missing the parent. Always look up the issue first.

### Step 3 — construct the path and branch name

| Scenario | Worktree path | Branch name |
|---|---|---|
| Top-level issue | `<base>/gh<number>-<slug>` | `<number>-<slug>` |
| Issue with parent | `<base>/gh<parent-number>/<number>-<slug>` | `<number>-<slug>` |
| No issue | `<base>/<branch-name>` | `<branch-name>` (Conventional Commits style) |

Branch name is always flat — no parent number encoding.

### Step 4 — trust mise in the new worktree

```shell
cd <worktree-path>
mise trust
```

Required before any `mise run` command. Every new worktree directory starts untrusted; forgetting this blocks all task execution.

## Slug Derivation

Issue title → lowercase → spaces and non-alphanumeric chars → hyphens → consecutive hyphens collapsed → leading/trailing hyphens stripped.

Example: `Add git to base-system` → `add-git-to-base-system`

The ≤ 5-word issue title constraint means no truncation is needed.

## Self-Improvement Loop

Before committing — when you hit a non-obvious pattern, workaround, or convention:

1. Open the relevant `docs/skills/` file (or create one if none exists for the area).
2. Add the entry.
3. Stage it alongside your change.
4. Commit them together.

The skill file update must be in the same commit as the change that produced the learning. A follow-up commit is a failure of the loop.

See `AGENTS.md` § Self-improvement loop for the full mandate and `/skills-check` for a compliance self-diagnosis.
