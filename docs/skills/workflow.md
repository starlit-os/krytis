# Agent Workflow

Reference for setting up worktrees, branches, and following the self-improvement loop. Load this before starting any implementation task.

## Worktree & Branch Setup

Always create a worktree before touching any files — including when working on an **existing** branch. Never `git checkout <branch>` in the primary worktree; that switches HEAD away from `main` and defeats the whole point.

**Always use `git worktree add` via Bash. Never use the `EnterWorktree` tool.** The tool hardcodes `.claude/worktrees/` as the base and prefixes the branch with `worktree-` — both violate this project's convention. A `PreToolUse` hook in `.claude/settings.json` blocks it with a reminder.

**Existing branch (no `-b`):**
```shell
git worktree add <worktree-path> <existing-branch>
```

**New branch:**
```shell
git worktree add -b <branch> <worktree-path>
```

The AGENTS.md exception — *"explicit instruction to work on an existing branch"* — means *the branch already exists, so skip `git branch` creation*. It does **not** mean *skip the worktree*. A human saying "check out X and verify it builds" is explicit instruction to use that branch, not to `git checkout` in the primary worktree.

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
| Top-level issue | `<base>/<cc-type>/gh<number>-<slug>` | `<number>-<slug>` |
| Issue with parent | `<base>/gh<parent-number>/<number>-<slug>` | `<number>-<slug>` |
| No issue | `<base>/<branch-name>` | `<branch-name>` (Conventional Commits style) |

`<cc-type>` is the Conventional Commits type (`feat`, `fix`, `ci`, `chore`, `docs`, `refactor`, …). Branch name is always flat — no type prefix, no parent number encoding.

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

## Cleaning Up Merged Worktrees and Branches

After a PR is merged:

```shell
git worktree remove <worktree-path>   # may need --force (see below)
git branch -D <branch>                # -D required — see below
```

**`git branch -d` fails on rebased+merged branches.** When a branch was rebased before merging, the local tip SHA differs from the merge commit on main. Git considers the branch "not fully merged" even though the PR is closed. Always use `-D` after confirming the PR is merged on GitHub.

**`include/image-version.yml` is always locally modified.** `mise generate-image-version` writes a timestamp and commit SHA into this file. Any worktree that ran a build command will have it dirty, causing `git worktree remove` to refuse. Use `--force`. It is safe — the file is fully generated and has no unrecoverable content.

**Remove empty parent directories after worktree removal.** Worktrees under `<cc-type>/` (e.g. `feat/`, `chore/`, `fix/`) or `gh<number>/` parent dirs leave those directories behind when the last child worktree is removed. They must be cleaned up manually:

```shell
# Prune stale git registry entries (worktrees deleted from disk without git worktree remove):
git worktree prune

# Remove empty parent dirs left behind:
find krytis.worktrees -mindepth 1 -maxdepth 1 -type d -empty -delete
```

`git worktree list` shows `prunable` next to stale entries — run `prune` first, then check for empty dirs. `rmdir` also works for individual dirs.

## Opening Pull Requests

**PR body must contain `Closes #<issue>`** to create the GitHub PR→issue link. The commit message alone is not enough — GitHub only auto-closes and links the issue when the keyword appears in the PR body. Always include it as the first line of the PR body:

```
Closes #NNN

## Summary
...
```

Always run `gh pr create` from inside the feature branch worktree, not from the main repo directory:

```shell
# ❌ fails — gh detects main as both head and base
gh pr create --title "..."

# ✅ correct — cd into the worktree first
cd <worktree-path> && gh pr create --title "..."
```

Running from the main repo dir produces: `head branch "main" is the same as base branch "main"`.

## Testing Scripts Shipped in the Image

Rebuilding the OCI image to test a script change takes significant time. For scripts shipped via BST elements (e.g. `files/fido2-tasks/fido2/enroll`), iterate locally first:

1. Write the script to `~/.mise/tasks/<path>` with a `-local` suffix (e.g. `~/.mise/tasks/fido2/enroll-local`).
2. Run it directly against the live system — no image rebuild needed.
3. Once confirmed working, copy back to `files/` in the element and commit.

The `-local` suffix distinguishes the test copy from the system version (which has no suffix). Never commit the `-local` copy to the element.

## Referencing Sister Projects (Dakota, Zirconium Hawaii)

Two sibling projects are used as references for element patterns. Locate them by checking sibling directories first (same parent as this repo). If not found, ask the user where they are.

```shell
# Get sibling dirs — adjust the parent path to wherever this repo lives
ls "$(git rev-parse --show-toplevel)/.."
```

Look for `dakota` and `zirconium-hawaii` (or similar names) in that listing. Don't assume a path — verify it exists before reading from it.

### Dakota — layers on a bluefin OCI base (RPM)

Dakota's BST elements run on top of a pre-built bluefin OCI image. That base ships files from RPMs — `/etc/sudoers`, `/etc/pam.d/sudo`, pre-configured `/etc`, standard FHS layout from Fedora packages.

**Dakota elements only install the delta.** If a file already exists in the bluefin base, the Dakota element won't touch it.

**Krytis builds from scratch.** fdsdk provides no RPM base. If a component needs a config file, sudoers entry, PAM config, or any file the C reference implementation installs via `make install` — our element or override must install it explicitly. Overriding `components/sudo.bst` drops GNU sudo's `make install` output including `/etc/sudoers` and `/etc/pam.d/sudo`; a Dakota element for the same override doesn't reinstall those because bluefin already has them.

**Verification checklist when porting from Dakota:**

1. Read the element code — but also check what the *base image* contributes.
2. Ask: "Does this element assume any config file, PAM stack entry, or `/etc` content that bluefin's RPMs install?" If yes, Krytis must install it explicitly.
3. Run `mise lint` and attempt a build before concluding the port is complete.

### Zirconium Hawaii — closer analog to Krytis

Zirconium Hawaii also builds from fdsdk with no RPM base. It is a **better reference than Dakota** when both have an element, because it faces the same constraints Krytis does. See `docs/skills/zirconium-hawaii.md`.

### Always read their skills docs too

When referencing Dakota or Zirconium Hawaii, read `docs/skills/` in the sibling repo — not just the element file. Context that isn't in the element (what the base image provides, known workarounds, build quirks) lives there.

**Don't read only the `.bst` file.** The element captures what the author needed to add on top of their environment. The skills docs capture what that environment provides implicitly.

## Self-Improvement Loop

Before committing — when you hit a non-obvious pattern, workaround, or convention:

1. Open the relevant `docs/skills/` file (or create one if none exists for the area).
2. Add the entry.
3. Stage it alongside your change.
4. Commit them together.

The skill file update must be in the same commit as the change that produced the learning. A follow-up commit is a failure of the loop.

**Standalone skill updates** (not tied to any element change) still require a branch and PR — never commit directly to `main`. Create a no-issue worktree (`<base>/docs/<slug>`) and open a PR the same as any other change.

See `AGENTS.md` § Self-improvement loop for the full mandate and `/skills-check` for a compliance self-diagnosis.
