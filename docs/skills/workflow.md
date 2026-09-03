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

`git diff <pr-head> <tip>` **is** available, contrary to what the deleted head ref suggests: GitHub retains every PR's head commit at `refs/pull/<n>/head` after the branch is gone, for merged and closed PRs alike. Fetch it, then diff against a real local object:

```shell
git fetch origin refs/pull/543/head   # FETCH_HEAD == the PR's headRefOid
git diff FETCH_HEAD <tip>
```

Fetching the bare OID (`git fetch origin <headRefOid>`) works too. Both were verified from a clean clone against merged #584 and closed #522, whose branches were both deleted. Comparing against `main` or a kept branch remains the better check when the question is "is anything lost" — but "the head is unfetchable" is not the reason.

Then re-run with `--allow-diverged`.

### Abandoning a PR: extract the lessons, then delete the branch

`mise run prune-worktrees` only touches branches whose PR is `MERGED`, so an
abandoned branch is always a manual `git push origin --delete <branch>`. Do it —
but in this order, in one session:

1. **Extract first.** Every workaround, constraint and verified fact the branch
   discovered goes into `docs/skills/` or `docs/design/` (§ Self-Improvement
   Loop applies to rejected work too — arguably more, since the code will not be
   there to re-read).
2. **Record the recovery ref**, not the branch name. Cite
   `refs/pull/<n>/head` plus the SHA; a branch name that no longer exists is a
   dead pointer, and the PR number alone makes a reader hunt for the commit.
3. **Then delete the branch.** The commit is not lost — see the `refs/pull` note
   above.

Worked example: #522's gaming sysext, mined into
`docs/design/gaming-variant.md` + two skill files by #589, branch deleted, tree
still reachable at `refs/pull/522/head`.

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

## The One Verification Gate an Agent Cannot Run: `generate-disk`

AGENTS.md § Verification requires every PR to confirm the image booted, and `mise run boot-test` is the automated pass/fail for it. An agent session cannot complete that command. Step 1/5 shells out to `mise/tasks/generate-disk`, which needs real root, and an agent's non-TTY shell dies immediately with:

```
==> [1/5] Installing localhost/krytis:latest → /var/tmp/krytis-boot-test.XXXX/test.raw (filesystem: btrfs)...
==> Creating 15G sparse disk image at /var/tmp/krytis-boot-test.XXXX/test.raw...
==> Copying localhost/krytis:latest to root podman store...
sudo: A terminal is required to authenticate
```

There is nothing to retry: `sudo -n true` also fails (no `NOPASSWD` rule for these commands), and a `sudo` timestamp primed in the human's own terminal is not visible to the agent's shell. Do not try to work around it — hand it off.

**The privileged part is one step, not the whole gate.** `bootc install to-disk --via-loopback` has to create a loop device and mount the new filesystem, which requires `CAP_SYS_ADMIN` in the initial user namespace (see the comment block at `mise/tasks/boot-test:76`). Everything after it — the QEMU boot, the serial-console assertions, the verdict — is unprivileged, and `boot-test` exposes the split via `--reuse-disk`:

```shell
# human, once per built image — the only privileged command
mise run generate-disk --image localhost/krytis:latest \
    --disk /var/tmp/krytis-test.raw --size 15G

# agent, unprivileged, as many times as needed
mise run boot-test --reuse-disk /var/tmp/krytis-test.raw
```

`--reuse-disk` is only honest for the image that disk was installed from. A disk left over from an earlier build proves nothing about the current one, so a new image means a new `generate-disk` — don't reuse a stale disk to make the checklist look complete.

**Sequence the handoff so it is the last thing outstanding.** Run every gate that works unprivileged first — `mise run build` (which ends in `bootc container lint`), `mise run validate`, `mise run docs-links`, `mise run vuln-scan`, the element build, and any in-sandbox smoke check via `bst shell` — then open the PR with that evidence and exactly one named command left for the maintainer. When they report the result, **edit the PR body** to record it; AGENTS.md § PR Comment Policy forbids a follow-up comment for a new observation.

The same root requirement applies to `mise run chunkify` and to `mise/tasks/load-image-root` (which `generate-disk` calls to copy the image into the root podman store, invisible to rootless podman).

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

## Splitting a Branch: Cherry-Pick, Never `checkout <sha> -- <paths>`

*Source: the `feat/oo7-prompter-testbed` split (#579), where this nearly shipped a silent regression.*

To move part of a stale branch onto a fresh one, the obvious move is to name the files you want:

```shell
git checkout <sha> -- path/a path/b        # ← DO NOT
```

**This reverts every main-side change to those files, silently.** `checkout <sha> -- <path>` writes
that commit's *whole file*, not its delta. A stale branch is by definition missing commits that
landed on `main` since it was cut, so any file both sides touched comes back at the old content
with no conflict, no warning, and a diff that looks plausible.

Observed: splitting a 20-commit branch that was 19 commits behind. The file-checkout form quietly
reverted `files/noctalia-skel/settings.toml` (dropping `launch_apps_as_systemd_services = true`
from the just-merged #563) and eight `jdx/mise-action` SHA pins in
`.github/workflows/track-bst-sources.yml` back to v4.2.4.

Use a no-commit cherry-pick instead, then drop what you don't want:

```shell
git cherry-pick -n <sha>                   # 3-way merge — conflicts surface
git rm --cached <paths-that-belong-elsewhere>
git commit
```

The same split with `cherry-pick -n` raised a real conflict in `elements/desktop/noctalia.bst`
(the branch pinned a fork; `main` had moved to a newer upstream tag) — the one place a human
decision was actually needed, and precisely what the file-checkout form hid.

### Prove the split kept both sides

Absolute content comparison is the *wrong* test — a branch behind `main` legitimately differs on
files it never touched. Compare **deltas**, scoped to the branch's own merge-base:

```shell
MB=$(git merge-base origin/main <old-branch>)
git diff --name-only "$MB" <old-branch>          # files the branch itself changed
git diff "$MB" <old-branch>   -- <file>          # its delta ...
git diff origin/main <new-branch> -- <file>      # ... must match here
```

Then check the other direction too — `git diff <original-sha> <new-branch> -- <file>` should show
only the main-side lines you expect to have gained. Retire the old branch only once every file it
changed is accounted for.

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

### Rebasing a carried fork branch: verify the *introduced hunks*, not the tips

After rebasing a carried branch onto a moved upstream, the useful question is "did my change
survive intact?" — and a tip-to-tip diff cannot answer it, because it also contains every
upstream commit you just absorbed. Comparing `old-tip` against `new-tip` for the 2026-08-17
noctalia rebase reported 285 files and +14624/-3523, which says nothing at all.

Compare each side's diff *against its own base* instead, normalised to just the changed lines:

```shell
OLD_BASE=8403cb987 OLD_TIP=fcaf05e84      # what the branch was rebased from
NEW_BASE=87b203c68 NEW_TIP=47c1df893      # what it now sits on
for f in <files the branch touches>; do
  a=$(git diff $OLD_BASE $OLD_TIP -- "$f" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | md5sum)
  b=$(git diff $NEW_BASE $NEW_TIP -- "$f" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | md5sum)
  [ "$a" = "$b" ] && echo "$f IDENTICAL" || echo "$f DIFFERS"
done
```

Stripping `+++`/`---` and `@@` context is what makes it work — line numbers move even when the
change does not. Files the branch owns outright can be compared directly
(`git diff $OLD_TIP $NEW_TIP -- <paths>`, expect empty).

This turned a vague "it rebased cleanly and compiles" into: all 9 modified upstream files carry
byte-identical hunks, and all 6 branch-owned files are byte-identical. That is what licenses
reusing the *previous* runtime verification instead of re-doing it.

Use full 40-char SHAs in scripted loops. Abbreviated revs failed to resolve inside a `$(…)`
loop while `git rev-parse` resolved them fine a moment later, and the loop silently compared two
empty strings — reporting `IDENTICAL` for everything. Any comparison loop that can pass by
comparing nothing must print the hash it compared, so an empty compare is visible.

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

## Getting a Commit Signature to Show "Verified" on GitHub

Three things must line up, and a valid local signature proves only the first:

1. The signature verifies locally — `git verify-commit HEAD` prints `Good "git" signature`.
2. The public key is registered on the account **as a Signing Key**, not an Authentication Key (the dropdown at `github.com/settings/ssh/new` defaults to the wrong one).
3. The **committer** email is an address GitHub can map to that account.

### Check registration without the `admin:ssh_signing_key` scope

`gh api user/ssh_signing_keys` needs a scope the default `gh` token does not carry, and `gh auth refresh` drags in a device-code flow to get it. Skip both — the per-user list is public and unauthenticated:

```bash
curl -sS https://api.github.com/users/<login>/ssh_signing_keys
```

`[]` means the key is not on that account, whatever the browser appeared to say. Compare the returned `key` field against `cut -d' ' -f1,2 <keyfile>.pub` — GitHub stores type + blob and drops the comment, so a whole-line comparison always reports a spurious mismatch.

If you genuinely need the scope, the device code expires after 15 minutes: do not start `gh auth refresh` until you are ready to authorize immediately, and close any stale `github.com/login/device` tab first. A second run will happily land on the old tab, and authorizing an expired code reports nothing to the waiting terminal — `gh` just keeps polling until the code times out.

### A repo-local `user.email` silently kills the badge

GitHub awards the badge on the committer email. Verify an address is attached to the account rather than assuming:

```bash
gh api repos/<owner>/<repo>/commits/<sha> \
  --jq '"\(.commit.author.email) → \(.author.login // "UNMATCHED")"'
```

`UNMATCHED` means GitHub cannot map that address to any account, so a cryptographically perfect signature still renders **Unverified**. The `<id>+<login>@users.noreply.github.com` form always maps.

Linked worktrees share one `.git/config`, so a single `git config --local --unset user.email` fixes every worktree of the repo at once — confirm `git config --get extensions.worktreeConfig` is unset first, otherwise per-worktree overrides survive it.

The hardware-key enrollment side lives in `docs/skills/fido2.md` § Signing git commits with the same key.
