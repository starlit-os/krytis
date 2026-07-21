# Upstream Fork Lesson-Mining

Load when working on `docs/upstreams.yml`, `mise/tasks/upstream-sync`, or the
`upstream-lessons` Claude Code skill (`.claude/skills/upstream-lessons/`) — the system that
keeps krytis current with lessons from the `dakota` and `zirconium-hawaii` fork repos.
Background and design rationale: [issue #141](https://github.com/starlit-os/krytis/issues/141).

## What It Is

Krytis shares its foundation (Freedesktop SDK, BST, bootc, niri/greetd) with two sibling
projects the user maintains as GitHub forks. Both regularly solve problems krytis will hit
too. Rather than manually watching both repos, `docs/upstreams.yml` tracks a "last checked"
ref per repo, and the `upstream-lessons` skill diffs from there to find what's new,
proposes candidate lessons to a human, and writes accepted ones into `docs/skills/`.

## `docs/upstreams.yml` Schema

```yaml
repos:
  - name: dakota                              # matches mise upstream-sync <name>
    fork: starlit-os/dakota                   # owner/repo of the user's fork
    upstream: projectbluefin/dakota           # owner/repo it was forked from
    branch: main                              # branch to sync (not necessarily upstream's default branch — see note below)
    local_path: dakota                        # dir name, sibling of krytis's *main* checkout
    skill_file: docs/skills/dakota.md         # where accepted lessons for this repo land
    last_checked_sha: <sha>                   # fork HEAD at the last completed mining pass
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

## `mise upstream-sync`

```bash
mise upstream-sync                # sync + report range for every tracked repo
mise upstream-sync dakota         # just one repo
mise upstream-sync --check        # fetch and report only — no gh repo sync, no local pull
```

The sync itself is `gh repo sync <fork> --branch <branch>` (fast-forward from upstream)
followed by `git pull --ff-only` in the local checkout. This is a push to the user's own
fork on GitHub — low blast radius since it's fast-forward-only and it's their own fork, but
still worth flagging before running, same as any other push.

Output per repo is either "up to date" or an `old_sha..new_sha (N commits)` range — that
range is what the `upstream-lessons` skill mines. The task deliberately does not do any
mining itself; parsing commit relevance is a judgment call, not something to bake into a
shell script.

## Bootstrap State

The first pass (2026-07-09) seeded `last_checked_sha` at each fork's HEAD at the time
without mining anything — there was no prior ref to diff against, so "mine the full
history" would have been a firehose rather than a diff. Real mining starts on the next
sync once there's an actual commit range.

## `docs/skills/dakota.md` Doesn't Exist Yet

Unlike `zirconium-hawaii.md`, no dakota reference file exists yet — nothing's been mined
from it. The `upstream-lessons` skill creates it on the first accepted dakota lesson,
following `zirconium-hawaii.md`'s shape (What It Is / Directory Layout / per-topic
sections) rather than starting from a blank template.
