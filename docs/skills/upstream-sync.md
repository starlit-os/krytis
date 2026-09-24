# Upstream Fork Lesson-Mining

Load when working on `docs/upstreams.yml`, `mise/tasks/upstream-sync`, or the
`upstream-lessons` Claude Code skill (`.claude/skills/upstream-lessons/`) — the system that
keeps krytis current with lessons from the `dakota`, `zirconium-hawaii` and `dakota-iso`
upstream mirrors.
Background and design rationale: [issue #141](https://github.com/starlit-os/krytis/issues/141).

## What It Is

Krytis shares its foundation (Freedesktop SDK, BST, bootc, niri/greetd) with two upstream
projects, and forked its live-ISO pipeline out of a third. All of them regularly solve
problems krytis will hit too. Rather than manually watching each repo, `docs/upstreams.yml`
tracks a "last checked" ref per repo, and the `upstream-lessons` skill diffs from there to
find what's new, proposes candidate lessons to a human, and writes accepted ones into
`docs/skills/`.

| Tracked repo | Branch | Skill file | Onboarded |
|---|---|---|---|
| `projectbluefin/dakota` | `testing` | `docs/skills/dakota.md` | #141 |
| `zirconium-dev/zirconium-hawaii` | `stable` | `docs/skills/zirconium-hawaii.md` | #141 |
| `projectbluefin/dakota-iso` | `main` | `docs/skills/dakota-iso.md` | #841 |

`dakota-iso` joined only once krytis stopped *depending* on it: until #840 the ISO build
shelled out to a sibling checkout of the `kitten-lily/dakota-iso` fork, which carried four
krytis-only commits. A repo cannot be both a live dependency and a fast-forward mirror —
`git merge --ff-only` refuses the moment the local checkout carries anything upstream does
not have. See `docs/skills/dakota-iso.md` § Fork State.

## `docs/upstreams.yml` Schema

```yaml
repos:
  - name: dakota                              # matches mise upstream-sync <name>
    upstream: projectbluefin/dakota           # owner/repo to fetch from directly
    branch: testing                           # branch to sync (not necessarily upstream's default branch — see note below)
    local_path: dakota                        # dir name, sibling of krytis's *main* checkout; origin must point to upstream
    skill_file: docs/skills/dakota.md         # where accepted lessons for this repo land
    last_checked_sha: <sha>                   # upstream HEAD at the last completed mining pass
    last_checked_date: "YYYY-MM-DD"
```

**`branch` is not always the upstream repo's GitHub default branch.** dakota's upstream
(`projectbluefin/dakota`) defaults to `testing`, its bleeding-edge branch; `main` is the
promoted-stable branch (`auto/promote-testing-to-main` handles that promotion upstream).
Confirm which branch is actually the one worth mining before adding a new repo; don't
assume `gh repo view --json defaultBranchRef` gives the right answer.

As of 2026-07-21, dakota is tracked on `testing`, not `main` — `main` had zero new commits
over a 10-day window because promotions from `testing` had stalled, leaving nothing to
mine. `testing` moves continuously and is where the lessons actually surface first; the
tradeoff is that a `testing` commit can still get reverted before promotion, so treat
anything mined from it as provisional until it lands on `main` too.

**`local_path` is a bare directory name, not a relative path.** `mise upstream-sync`
resolves it against the sibling of krytis's *main* git worktree (via `git worktree list`),
not `$PWD` — `$PWD` is wrong whenever the task runs from inside a `git worktree` checkout
of krytis itself, which is the normal case per `AGENTS.md`'s worktree policy. An earlier
draft of this task stored `../dakota` and resolved it relative to `$PWD`; it silently
skipped both repos the first time it ran from a worktree. Keep it a bare name.

**The local checkout's `origin` must point to the upstream repo** (i.e. clone from
`github.com/<upstream>`, not from a fork). `mise upstream-sync` runs `git fetch origin`
directly — there is no `gh repo sync` step and no fork involved.

**An `origin` pointing at a fork makes the sync lie, silently.** `git fetch origin` +
`git merge --ff-only origin/<branch>` then measures the *fork's* tip, and a fork only moves
when somebody syncs it — so the task reports "up to date" while upstream runs away. Found
while onboarding `dakota-iso` (#841): `../dakota`'s `origin` was `starlit-os/dakota` with
`projectbluefin/dakota` on a second remote, and `origin/testing` was **57 commits behind**
`upstream/testing` at that moment — 57 commits the lesson-mining pass never saw, reported
as "up to date at 1cf9ef65…" because that *was* the fork's tip.

All three checkouts are now wired the documented way: `../dakota`'s remotes were swapped
(`origin` = `projectbluefin/dakota`, the unused `starlit-os/dakota` kept as `fork`, the
duplicate `upstream` remote removed) and its `testing` branch retargeted at
`origin/testing`; `../dakota-iso` was cloned from the fork but repointed at
`projectbluefin/dakota-iso` when that fork was deleted (#841); `zirconium-hawaii` never had
a fork at all. **No tracked repo goes through a fork any more.** If you add one, clone from
the upstream — and check `git -C <local_path> remote -v` before trusting an "up to date"
line on an existing one.

## `docs/upstreams.yml` Values Must Not Carry Inline Comments

`mise upstream-sync` parses this file with `awk -F': '` on fixed field names — not a YAML
library — because the schema is a flat, fixed shape (see the task's own comment on this).
An inline comment on a value line (e.g. `branch: testing  # rationale`) becomes part of the
parsed value verbatim, since awk doesn't know `#` starts a comment here. This broke `gh repo
sync` with an opaque `HTTP 404: Branch not found` when a rationale comment was appended to
`branch: testing`. Put explanatory comments on their **own line above** the field, never
trailing on the same line as a value.

## `mise upstream-sync`

```bash
mise upstream-sync                # sync + report range for every tracked repo
mise upstream-sync dakota         # just one repo
mise upstream-sync dakota-iso     # …or another
mise upstream-sync --check        # report the pending range without merging
```

The sync is `git fetch origin <branch>` followed by `git merge --ff-only origin/<branch>`
in the local checkout. No push is involved — `origin` in the local checkout must point to
the upstream repo. `--check` still runs the `git fetch` (there is no way to measure the
pending range without it) and compares `origin/<branch>` instead of `HEAD` — it skips only
the `--ff-only` merge, so it never moves the local checkout.

A repo whose `local_path` has no checkout on this machine is **skipped with a warning on
stderr**, not an error: `==> <name>: no checkout at <path>, skipping`. A clean exit
therefore does not mean every tracked repo was actually measured — read the per-repo lines.

Output per repo is otherwise either "up to date" or an `old_sha..new_sha (N commits)`
range — that range is what the `upstream-lessons` skill mines. The task deliberately does
not do any mining itself; parsing commit relevance is a judgment call, not something to
bake into a shell script.

## Bootstrap State

The first pass (2026-07-09) seeded `last_checked_sha` at each repo's HEAD at the time
without mining anything — there was no prior ref to diff against, so "mine the full
history" would have been a firehose rather than a diff. Real mining starts on the next
sync once there's an actual commit range. `dakota-iso` was bootstrapped the same way on
2026-09-15 at `f5fbf99`, with one difference: its pre-existing content was already mined
in anger by #519's port investigation, and what that found is written up in
`docs/skills/dakota-iso.md` rather than left for a first mining pass to rediscover.

## `docs/skills/dakota.md`

Created on the first accepted dakota lesson (PR #303/#141) and grown since — unlike
`zirconium-hawaii.md`'s "What It Is / Directory Layout / per-topic sections" shape, it uses
a flatter "What It Is / Lessons Mined" structure with one `### <title>` + `*Source: ...*`
entry per lesson. Match that existing shape when adding new entries rather than
introducing a third structure. `dakota-iso.md` follows the same flatter shape, plus a
`## Fork State` section that exists only because that repo had a fork with real divergence
to unwind — don't copy that section into a new entry that never had one.
