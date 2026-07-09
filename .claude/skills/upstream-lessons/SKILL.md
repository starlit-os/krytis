---
name: upstream-lessons
description: Sync the dakota and zirconium-hawaii fork repos to their upstream branch, mine the commits/docs/AI-guidance that changed since the last check, and turn anything applicable into docs/skills/ or AGENTS.md updates for krytis. Use whenever the user asks to sync forks, check dakota or zirconium-hawaii for lessons, mine upstream, "run the upstream check", or references docs/upstreams.yml or GitHub issue #141. Also the right tool if the user just says something like "see what's new in dakota" or "has zirconium-hawaii changed anything we should steal".
---

# Upstream Lessons

Krytis shares its foundation (Freedesktop SDK, BST, bootc, niri/greetd) with two sibling
projects the user maintains as forks: `dakota` (upstream: projectbluefin/dakota) and
`zirconium-hawaii` (upstream: zirconium-dev/zirconium-hawaii). Both repos regularly solve
problems krytis will hit too — a workaround for an FDSDK quirk, a BST element gotcha, a
convention that isn't obvious until you've been burned by it. This skill is how those
lessons get pulled into krytis's `docs/skills/` instead of being independently
rediscovered later.

The tracking state lives in `docs/upstreams.yml` — one entry per repo, recording the fork,
its upstream, which local branch to follow, and `last_checked_sha`: the fork commit that
was HEAD the last time this skill finished mining it. Read that file first; it's the
source of truth for what "new" means on this run.

## Workflow

### 1. Sync

Run `mise upstream-sync` (optionally `mise upstream-sync <name>` for just one repo) to
fast-forward each fork from its upstream and report the commit range since
`last_checked_sha`. This pushes to the user's own fork on GitHub (via `gh repo sync`) —
low-risk since it's their fork and fast-forward-only, but say what you're about to do
before running it, same as any other push.

If you want to preview without syncing, `mise upstream-sync --check` fetches and reports
the pending range without touching the fork or the local checkout.

### 2. Bootstrap case

If a repo has no prior state to diff against — this is the very first run, or
`last_checked_sha` is missing — there's nothing to mine yet. Just record the current HEAD
into `docs/upstreams.yml` as the baseline and say so. Mining starts from the *next* run.
Don't invent lessons from the entire history on a bootstrap pass; that's a firehose, not a
diff.

### 3. Mine the range

For each repo with a nonempty `last_checked_sha..HEAD`:

- `git -C <sibling-dir>/<repo> log <old>..<new> --oneline` for the full commit list.
- Triage by relevance to krytis: BST element patterns, mesa/GPU config, greetd or
  compositor (niri/wlroots) behavior, bootc/composefs, PAM, environment/systemd
  quirks, CI conventions. Read `git show` on anything that looks substantive rather than
  guessing from the subject line — the interesting part of a fix is usually in the diff or
  commit body, not the title.
- Also diff the repo's own guidance files over that range — `AGENTS.md`, `CLAUDE.md`,
  `README.md`, and anything under a `docs/` or `skills/`-shaped directory. These are
  *already-distilled* lessons from that project's own agents; they're often higher
  signal than raw commits and easy to miss if you only look at `git log`.

A commit is worth surfacing if it encodes something non-obvious: a workaround for an
upstream bug, a convention you'd only learn by getting bitten, or a pattern that isn't
inferable from reading the code cold. Routine version bumps, formatting, and one-off
project-specific fixes aren't — leave those out rather than padding the candidate list.

### 4. Present candidates, don't just apply them

List every candidate lesson in the conversation: source commit SHA (or file), a
one-or-two-sentence summary, and which krytis file it belongs in — usually the matching
`docs/skills/<repo-name>.md` (create `docs/skills/dakota.md` on its first accepted lesson;
`docs/skills/zirconium-hawaii.md` already exists and shows the shape to follow), but route
genuinely cross-cutting workflow/process lessons to `AGENTS.md` instead. Ask the user which
to accept. This mirrors issue #141's design — human judgment decides what's worth carrying
forward, this skill just makes the candidates cheap to review.

Only write the accepted ones. Match the target file's existing structure (headings,
tables, code blocks) rather than appending a flat log of commits.

### 5. Advance the ref and commit together

Update `docs/upstreams.yml` for every repo you synced — `last_checked_sha` to the new HEAD,
`last_checked_date` to today — regardless of how many lessons were accepted. "Checked and
found nothing worth porting" is still a completed check; the ref should move so the next
run doesn't re-mine the same commits.

Commit the skill-file edits and the `upstreams.yml` update together, in the same commit —
this *is* the self-improvement-loop mandate from `AGENTS.md`: the learning and the record
of having looked land as one unit, not a follow-up.

### 6. PR, don't merge

Follow `AGENTS.md`'s worktree/branch policy for the commit (this is "no issue" maintenance
work unless the user ties a specific run to a GitHub issue — branch name like
`chore/sync-upstream-lessons-<date>`). Open a PR summarizing what was accepted, what was
rejected and why, and the new tracked SHAs. Merging is the human's call per the Merge Gate
— don't merge it yourself even if CI is green.

## Reference

See `docs/skills/upstream-sync.md` for the `docs/upstreams.yml` schema and the
`mise upstream-sync` task's behavior in more detail.
