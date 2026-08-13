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

```shell
mise run prune-worktrees --dry-run   # report only
mise run prune-worktrees             # remove, with a confirmation prompt
```

It removes a worktree and its branch only when GitHub says the branch's newest PR is `MERGED`. Do not hand-roll the `git worktree remove` / `git branch -D` pair — the task encodes four things that are easy to get wrong:

**Ancestry checks all lie on a squash-only repo.** `git branch -d`, `git branch --merged main` and `git log --merged` all treat a merged branch as unmerged, because the squashed commit on `main` shares no ancestry with it. The PR state is the only trustworthy signal; `-D` is mandatory once it says `MERGED`.

**`include/image-version.yml` is always locally modified.** `mise generate-image-version` writes a timestamp and commit SHA into it, so any worktree that ran a build carries it dirty and `git worktree remove` refuses. The task ignores that one path and refuses on anything else, rather than blanket-forcing.

**Empty parent dirs survive their children.** Worktrees under `<cc-type>/` (`feat/`, `fix/`, …) or `gh<number>/` leave the parent directory behind. The task runs `git worktree prune` and deletes empty parents; `git worktree list` shows `prunable` next to stale entries if you are checking by hand.

**A diverged tip is held back on purpose.** A local tip that does not match the merged PR's head means the branch was reused, force-pushed, or carries unpushed commits — the task reports it and keeps it:

```
.worktrees/fido-dropin    tip c62ebb1 != #543 head 3e02894 (--allow-diverged to override)
```

Verify before overriding, by whichever of these two routes applies:

- **The tip is an ancestor of a branch you are keeping.** `git merge-base --is-ancestor <tip> <kept-branch>` exiting 0 means every commit stays reachable after the delete, so nothing can be lost regardless of what the diff looks like. This is the common shape for an investigation branch whose PR merged while a longer-running branch continued from its tip.
- **Otherwise, compare against `main`.** `git diff origin/main <branch>` must show only content `main` already has — deletions relative to `main`, no additions of the branch's own.

Note that `git diff <pr-head> <tip>` is *not* available as a check: GitHub deletes the head ref on merge, so the reported head OID is not fetchable locally (`unknown revision`). Compare against `main` or a kept branch, never against the PR head.

Then re-run with `--allow-diverged`.

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

## Stacked PRs on a Squash-Only Repo

Stack when the next piece of work needs a file state that only exists in an open PR — a prerequisite (#24 → #25) or the same lines of one config (#26 → #27). Base the child on the parent branch and say so in the body, so the reviewer knows the order:

```shell
git worktree add -b <child-branch> <base>/<path> <parent-branch>
cd <worktree-path> && gh pr create --base <parent-branch> --title "..."
```

### The parent's merge breaks the child, every time

This repo is squash-only (`AGENTS.md` § Merge strategy), so when the parent merges, `main` gains the parent's changes as **one new commit with a new SHA**, and the parent branch is deleted. GitHub retargets the child PR to `main`, and it immediately reads:

```
"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"
```

This is not a real content conflict. The child branch still carries the parent's *original* commit, so git sees two unrelated commits touching the same files and refuses. Do not try to merge `main` in and hand-resolve — that reintroduces the duplicate. Replay only your own commits:

```shell
git fetch origin --prune
git rebase --onto origin/main <parent-tip-sha>      # the SHA the child branched from
git push --force-with-lease origin <child-branch>
```

`<parent-tip-sha>` is the parent's last local commit — `git log --oneline` on the child shows it directly under your own commits.

### Confirm the rebase kept the right scope

```shell
git diff origin/main --stat              # must be exactly the child's own files
git diff <parent-tip-sha> origin/main --stat   # empty ⇒ the squash was verbatim
```

If the second diff is *not* empty the maintainer edited something while merging — no action needed, since the rebase replays only your commit and `main`'s version of the parent's files wins automatically. Then re-run the change's verification against the merged `main`: a clean rebase still shifts the ground your change sits on.

Worked examples: #430 rebased onto the squashed #427, #432 onto the squashed #431 — both were three commands, no conflict markers touched.

## Testing Scripts Shipped in the Image

Rebuilding the OCI image to test a script change takes significant time. For scripts shipped via BST elements (e.g. `files/fido2-tasks/fido2/enroll`), iterate locally first:

1. Write the script to `~/.mise/tasks/<path>` with a `-local` suffix (e.g. `~/.mise/tasks/fido2/enroll-local`).
2. Run it directly against the live system — no image rebuild needed.
3. Once confirmed working, copy back to `files/` in the element and commit.

The `-local` suffix distinguishes the test copy from the system version (which has no suffix). Never commit the `-local` copy to the element.

## Referencing Sister Projects (Dakota, Zirconium Hawaii)

Two sibling projects are used as references for element patterns. Locate them by checking sibling directories first (same parent as this repo). If not found, ask the user where they are.

For pulling in lessons from what's *changed* in these repos since they were last checked — rather than reading them ad hoc — see [`docs/skills/upstream-sync.md`](upstream-sync.md) and the `upstream-lessons` skill.

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

## Sync a Component Fork Before Branching From It (`kitten-lily/*`)

Krytis pins upstream components (`noctalia-dev/noctalia`, `noctalia-dev/noctalia-greeter`, …)
directly, so the `kitten-lily` forks are only touched when someone is actively carrying a patch.
Between those episodes they rot silently: as of 2026-08-12 `kitten-lily/noctalia`'s `main` was
**111 commits behind** upstream, and the local checkout was parked on a stale feature branch
1043 commits behind, still at `v5.0.0-beta1` while krytis pinned `v5.0.0-beta.7`.

**Before starting any work on a fork, sync it and check whether the old branch is still needed.**

```shell
cd <fork checkout>
git fetch upstream --tags && git fetch origin
# Fork-only commits on main? Empty output = clean fast-forward, safe to push.
git log --oneline upstream/main..origin/main
git push origin upstream/main:refs/heads/main
git checkout main && git merge --ff-only origin/main && git push origin --tags
```

Then branch from `upstream/main`, not from the fork's stale tip:
`git worktree add -b <branch> <path> upstream/main`. Basing a prototype on the fork's old `main`
means writing against APIs that no longer exist — `src/security/` did not exist at `beta1` but
is central at `beta.8`.

**Check whether the stale feature branch was upstreamed before assuming it still matters.** Diff
its change against current upstream rather than trusting the branch name: `fix/wifi-persist-polkit-async`
turned out to be redundant because upstream had since made the same call async
(`callMethodAsync("AddAndActivateConnection2")` in `src/dbus/network/network_manager_service.cpp`).
Report obsolete branches to the user rather than deleting them — they are the user's work.

Worktrees for fork work live beside the fork, not in krytis:
`<parent>/<fork-name>.worktrees/<branch-leaf>`.

## Where Plan and Design Docs Go

`docs/design/<topic>.md` for living reference (architecture, rationale, deferred work — undated, edited in place). `docs/plans/YYYY-MM-DD-<slug>.md` for dated execution plans, `git mv`'d to `docs/plans/done/` in the PR that lands the work. Full rule and decision test in `AGENTS.md` § Plan & Design Docs.

**The `writing-plans` skill emits to `docs/superpowers/plans/` by default.** That directory was removed in #393 — the tool's brand name has no business in the durable doc tree. A `PreToolUse` hook (`.claude/hooks/block-superpowers-path.sh`, wired in `.claude/settings.json`) rejects writes under it, the same way `EnterWorktree` is blocked. Prose in `AGENTS.md` alone did not reliably beat a skill default; the hook is what actually enforces it.

**`docs/plans/done/` is frozen.** Archived plans reproduce past `git commit -m` bodies, `grep` invocations and `**Result: PASS.** Present at <path>:<line>` evidence verbatim. Rewriting a path inside one — even a correct-looking rename — falsifies a record of what was true when the check ran. When a migration renames files, update references everywhere *except* there, and let the stale paths stand.

**Live plans quote content destined for other files.** A plan that says "add this row to `docs/SKILL.md`" embeds the row with a relative link target of `skills/foo.md` — correct in `docs/SKILL.md`'s frame, broken in the plan's. Do not "fix" these. `mise run docs-links` excludes `docs/plans/` from markdown-link checking for exactly this reason, while still checking its repo-root-relative `docs/…` paths.

**Run `mise run docs-links` before opening any PR that touches docs.** It resolves both repo-root-relative `docs/….md` references (including those in `.bst` files, mise tasks, and Containerfile comments — several exist) and markdown inline links. It is standalone, not wired into `mise lint`: `lint` is a full `podman build` of the image, and a text check has no business behind a container build.

Two categories may go in `docs/.links-ignore`: docs a design doc forward-references but that nobody has written yet, and paths belonging to an upstream repo (dakota, bootc) quoted as a source citation. Anything else is rot — fix the reference.

## Self-Improvement Loop

Before committing — when you hit a non-obvious pattern, workaround, or convention:

1. Open the relevant `docs/skills/` file (or create one if none exists for the area).
2. Add the entry.
3. Stage it alongside your change.
4. Commit them together.

The skill file update must be in the same commit as the change that produced the learning. A follow-up commit is a failure of the loop.

**Standalone skill updates** (not tied to any element change) still require a branch and PR — never commit directly to `main`. Create a no-issue worktree (`<base>/docs/<slug>`) and open a PR the same as any other change.

See `AGENTS.md` § Self-improvement loop for the full mandate and `/skills-check` for a compliance self-diagnosis.
