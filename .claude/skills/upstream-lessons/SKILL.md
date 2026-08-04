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

Sort every commit worth a second look into three buckets, not two:

- **Accept-candidate** — non-obvious, and krytis's current architecture can hit it today
  (a workaround for an upstream bug, a convention you'd only learn by getting bitten, a
  pattern not inferable from reading the code cold). Goes to step 4's proposal list.
- **Deferred** — the lesson itself is genuinely good (same bar as accept-candidate: not
  obvious, not a routine bump) but doesn't apply to krytis *yet* because krytis lacks the
  subsystem it addresses — e.g. an NVIDIA-variant fix when krytis has no NVIDIA element, a
  gaming-variant/aarch64/remote-execution pattern krytis doesn't build, a merge-queue
  convention krytis's human-approved squash-merge flow doesn't use. Don't write these back
  anywhere; they're a watch list, not a lesson. Track source commit SHA + one-line summary
  + the krytis precondition that would make it relevant (e.g. "if krytis ever adds an
  NVIDIA variant").
- **Rejected outright** — routine version bumps, formatting, one-off project-specific
  fixes with no transferable idea, or something krytis already handles (verify against the
  current `docs/skills/` file and element tree before assuming it's new — krytis may have
  already solved it, sometimes with a different approach worth noting as such). Leave
  these out of both lists entirely; don't pad either one.

### 4. Present candidates, don't just apply them

List every accept-candidate in the conversation: source commit SHA (or file), a
one-or-two-sentence summary, and which krytis file it belongs in — usually the matching
`docs/skills/<repo-name>.md` — both `docs/skills/dakota.md` and
`docs/skills/zirconium-hawaii.md` already exist and show the shape to follow — but route
genuinely cross-cutting workflow/process lessons to `AGENTS.md` instead. Ask the user which
to accept. This mirrors issue #141's design — human judgment decides what's worth carrying
forward, this skill just makes the candidates cheap to review.

Always also present the deferred list from step 3 in the same message, as its own section
— even when empty, say so explicitly rather than omitting the section. This is what lets
the human decide "not yet" versus "actually, do this one" without re-mining the range
later; it is not an invitation to write anything back for a deferred item unless the user
explicitly promotes it to an accept-candidate.

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
deferred (and the precondition that would revisit it), what was rejected outright and why,
and the new tracked SHAs. Merging is the human's call per the Merge Gate — don't merge it
yourself even if CI is green.

## Reference

See `docs/skills/upstream-sync.md` for the `docs/upstreams.yml` schema and the
`mise upstream-sync` task's behavior in more detail.
