---
name: skill-rot-audit
description: Audit docs/skills/ and docs/design/ for rot — claims that name a concrete artifact (path, mise task, flag, #USAGE default, config key, element, unit) and no longer match the tree. Use whenever the user asks to audit skills for rot, check whether a skill file is stale, prune or fact-check documentation, run a "rot pass" or "docs audit", or references GitHub issue #860. Also the right closing step after an upstream-lessons mining run that appended to a skill file, and the right response to discovering that a doc sent you hunting for a file that does not exist.
---

# Skill-Rot Audit

`AGENTS.md` § "Skill files rot too — prune, don't just append" says an agent touching a
section should check whether it, or a neighbour, has drifted from what the code actually
does. That rule fires opportunistically. This skill is the deliberate sweep — the version
you run when nobody happened to be editing the rotten section.

The failure mode it prevents is specific and expensive: **an agent trusts a skill file,
acts on a claim that is no longer true, and burns a session discovering that by hand.**
#840 hit three separate instances in one PR. Sibling fork `dakota` let it run until its CI
documentation reached 5385 lines — stale in places, contradicted by the workflow YAML it
described in others — and needed an emergency prune to ~450 lines.

**Not a line-count exercise.** An accurate 3000-line reference beats a vague 300-line one.
Nothing here licenses deleting a correct section because it is long, splitting a file, or
reflowing prose. The output is *fixes to claims*, and the null result — "sampled 40 claims,
all still true" — is a real, reportable outcome.

## What rots, and why it rots silently

Ranked by how often it has bitten, and by how expensive the bite was:

| Class | Shape | Why it survives review |
|---|---|---|
| Renamed artifact | Doc names `scripts/fisherman-install.sh`; tree has `scripts/iso-install-fisherman.sh` | The rename PR touched `scripts/` and `mise/`, so nobody opened a `docs/skills/` file |
| Upstream path read as local | Doc names `include/install-extra.yml` or `elements/components/foo.bst` — freedesktop-sdk's layout, not krytis's | Correct *as a citation*; only wrong because the sentence never says whose tree it is. A reader greps krytis, finds nothing, and cannot tell whether the doc or the tree is wrong |
| Mechanism gone | A whole section on a tool/recipe/task nothing in the repo can invoke any more | Deleting the mechanism is a code change; the prose about it is elsewhere |
| Stale status | "not yet verified", "pending", "blocked on #N", "currently broken, fix pending" | Written mid-investigation, true that day. The issue closing does not notify the doc |
| Drifted default | A documented `#USAGE` default, flag, or config key that the task/config no longer has | The task file is the executable truth; the doc is a copy that was never re-derived |
| Phantom count | "this exists in **three** places — grep for `X`" where three is the upstream's count | Nobody re-runs the grep; the number reads as authoritative |
| Orphaned `§` citation | A heading is renamed; every `docs/…md § Old Title` pointing at it goes stale | The damage is entirely *outside* the file the renaming commit touched. #647 renamed one `pam.md` heading and orphaned three citers (`docs/SKILL.md`, `mise/tasks/oo7-prompter-test`, `docs/design/secrets-service.md`) for four weeks with zero signal |
| Half-dead rationale | A comment or section justifies something with two reasons; a change falsifies one and leaves the other standing | Nothing breaks — the conclusion stays correct — and the surviving clause makes the whole rationale read as verified. `elements/desktop/kmscon.bst` carried a dead "the `.pc` files are unobtainable" clause beside a live "a text console needs no GPU" one until #860. Grep for the *claim*, not for a symptom |

The common root is not carelessness. It is that **every one of these was true when
written**, and the change that falsified it lived in a different directory. Rot is the
default state of prose about code, not an anomaly.

## Workflow

### 1. Run the mechanical half first

```bash
mise run docs-links
```

It checks five classes of reference and is the cheapest possible finding source:

1. repo-root-relative `docs/<name>.md` paths, anywhere in the tree;
2. markdown inline links, resolved relative to the linking file;
3. **backticked repo-relative paths** under `elements/ files/ include/ live/ mise/
   patches/ quadlet/ scripts/ .github/`, in markdown;
4. **backticked `mise run <task>` / `mise <task>` invocations**, in markdown;
5. **`<path>.md § <anchor>` section citations**, anywhere in the tree — resolved against
   the target file's `##`+ headings *and* its `**bold paragraph leads**`, because this repo
   cites both.

Checks 3, 4 and 5 exist because of this audit (#860) — they mechanise the highest-volume
classes in the table above. A green run is not a clean bill of health: it proves nothing
about flags, defaults, config keys, counts, or behavioural claims, which is the rest of
this skill.

Two things to know before changing check 5. It matches the citation's **first three words,
case-insensitively, as a substring** of an anchor: citations are routinely deliberate
prefixes of long headings (`§ Auditing a fdsdk major-version bump` → `## Auditing a fdsdk
major-version bump for silently-broken element refs (#305…)`) and routinely differ in case,
so an equality or `grep -F` check manufactures rot instead of finding it. And it only
handles the form where the **target path is stated on the same line** — a bare `§ Foo`
needs the target inferred, and three inference variants disagreed with each other by 40
findings on this tree. When writing a citation, delimit the anchor (`§ *Exact Heading
Text*`) so the matcher can bound it against the prose that follows.

Scope discipline when the sweep is a closing step after `upstream-lessons`: audit **the
files that run appended to**, not the whole tree.

### 2. Establish ground truth before reading any prose

Read the inventory first, so you are checking claims against a known tree instead of
forming an impression from the doc:

```bash
ls elements/*/ include/ scripts/ mise/tasks/ patches/ files/ live/src/
git ls-files 'mise/tasks/*' | sed 's|/|:|3'     # every repo task name
grep -rn '^\[tasks\.' --include='*.toml' .      # image-shipped tasks too
```

Krytis-specific traps worth memorising:

- `elements/` holds `config core deps desktop dev oci overrides plugins stacks` only.
  `elements/components/`, `elements/bootstrap/`, `elements/extensions/`, `elements/include/`
  are **freedesktop-sdk's** layout; `elements/krytis/`, `elements/zirconium/`,
  `elements/bluefin/` belong to sibling forks. A doc naming one of those is citing an
  upstream — correct content, missing attribution.
- `include/` holds `aliases.yml` and `variables.yml` (plus generated `image-version.yml`).
  Every other `include/*.yml` in the docs is freedesktop-sdk's.
- Task names are `mise/tasks/<group>/<name>` → `<group>:<name>`, **plus** `[tasks."…"]`
  headers in any `.toml`. `files/fido2-tasks/config.toml` declares the `fido2:*` tasks that
  ship to `/etc/mise/config.toml` on a booted system — real tasks, absent from `mise/tasks/`.
- `mise tasks --json` is **not** authoritative: it hides the `<name>-update` tasks and
  includes the running user's own `~/.config/mise` tasks.
- Some real paths are gitignored (`files/boot-keys/`, `include/image-version.yml`). Their
  absence from a clean checkout proves nothing — check the *generator*, not the directory.
- **"Is X actually in the image?" is one grep, not a build.** `files/fakecap-manifest.tsv`
  is a checked-in, element-attributed manifest of every file in `localhost/krytis:latest`.
  One grep each settled `gcr-prompter`, `gcr-ssh-agent`, `ykman`, the sshd drop-ins and the
  PAM module directory during this audit. It is regenerated by
  `mise run generate-fakecap-manifest`, so it lags the tree: authoritative for anything
  older than its last refresh, cross-check `elements/` for anything newer.

### 3. Sample the claims that name a concrete artifact

These are the cheap ones, and the ones that rot silently. In descending value:

- a path (element, script, task, patch, unit, config file);
- a mise task name, and its `#USAGE` flags and defaults;
- a config key or value (`mise.toml`, `project.conf`, `.github/renovate.json5`, `.grype.yaml`);
- a workflow job/step name, runner label, or action pin;
- a count ("three places", "both elements") — re-run the grep, do not trust the number;
- a version-scoped claim ("as of niri 25.x") — check the element's current pin;
- an issue/PR reference whose prose implies open work — `gh issue view <n> --json state`.

**Executable config is the source of truth; prose that disagrees with it is stale.** That
is dakota's post-prune restructuring principle and it settles every conflict: the workflow
YAML, the task file, the element, the `.toml` win over the sentence describing them.

Cheap stale-status sweep:

```bash
grep -nE 'not yet|pending|TODO|currently broken|untested|unverified|blocked on|as of' <files>
```

### 4. Classify three ways, then act

1. **wrong** — names something real, says the wrong thing about it. → Fix to what the tree
   says today.
2. **unreachable** — describes a mechanism that no longer exists here, or never did. Three
   sub-cases, and splitting them correctly is the whole judgement of this skill:
   - *mechanism gone, lesson gone* → cut the section.
   - *mechanism gone, lesson survives through a different mechanism* → **re-scope onto the
     live mechanism and keep one line of history.** Worked example (#840): `mise.md`
     documented `just` recipe variable shadowing long after nothing in the repo could
     invoke a `just` recipe — but "flags get silently dropped" was still true via a
     different mechanism (mise does not parse a child task's `#USAGE` annotations when one
     task invokes another directly). Re-scoped, not deleted.
   - *path belongs to an upstream tree and the citation is correct* → do not delete. Make
     the prose name the repo ("freedesktop-sdk's `include/install-extra.yml`",
     "dakota-iso's `scripts/build-live-squashfs.sh`") and add the path to
     `docs/.links-ignore` with a reason. A bare backticked upstream path is the finding;
     the citation is not.
3. **stale status** — a qualifier that was true during an investigation. → Resolve it
   against the issue's real state and rewrite to the settled fact, or drop the qualifier.
   Never leave a dangling "pending".

The rule as written in `AGENTS.md` nudges toward deletion. Resist that for case 2 — the
mechanism dying does not kill the lesson, and a deleted lesson gets rediscovered the
expensive way.

### 5. Constraints that are not negotiable

- **Numbered trap lists are cross-referenced by number.** `docs/design/secure-boot-testing.md`
  carries `T-1`…`T-N`, cited from skill files and code comments. Never renumber. Never
  delete an obsolete entry — mark it **resolved in place** (#840 kept T-10 that way). Check
  who cites it first: `grep -rn 'T-<n>' docs/ elements/ mise/ scripts/ .github/`.
- **`docs/plans/done/` is frozen.** Archived plans quote past commands, paths and
  `Result: PASS` evidence verbatim. Editing one falsifies the record. `docs/plans/` (live)
  is out of scope too: a live plan legitimately names files it is about to create.
- **`docs/design/` is a living reference, not a changelog.** A design doc describing
  *deliberately deferred* work — a variant never built, a mechanism explicitly parked — is
  not rot. Fix only what is wrong about today, and make the deferred framing unambiguous
  where a reader could mistake a proposal for shipped behaviour.
- **Never "fix" a claim you could not verify.** A confident wrong correction is worse than
  the rot it replaced, because the next agent has no reason to doubt it. Report it as
  unverified and say what checking it would take.
- **The mechanical checks are a candidate generator, not an adjudicator.** Over-trusting
  them deletes the evidence that made a section worth keeping. Three shapes read as rot to
  any literal matcher and are all correct as written: a doc **quoting a retracted claim in
  order to refute it** (`bst.md` quotes both broken `ldconfig -f` invocations — deleting
  them destroys the diagnosis); a **true conditional that resembles the retracted claim**
  (`desktop.md`'s "no pixman fallback in this path" describes wlroots' selection algorithm,
  not a failure); and a **dated historical marker** ("7.2.6 today — it was 7.2.2 when this
  was written"), which is the *repair* for version rot, not an instance of it.

### 6. Report, then write back

Report per finding: `<file>:<line> | wrong | unreachable | stale-status | what it said |
what the tree says | action`. Plus the paths you want in `docs/.links-ignore`, plus the
unverified list.

Routing, same convention as `upstream-lessons` and `vuln-scan-triage`: a finding about one
subsystem goes in that subsystem's `docs/skills/` file; a cross-cutting process finding —
*how* the rot got in, not what it was — goes in `AGENTS.md` § Skill files rot too. The
diagnosis is the part that compounds; a sweep that fixes 60 claims and records nothing
about why they rotted buys one clean pass and no immunity.

If the sweep exposes a rot class the mechanical checks could have caught, extend
`mise/tasks/docs-links` in the same PR. That is how checks 3 and 4 got there.

### 7. Commit and PR

One commit for the fixes plus any `docs/.links-ignore`, `mise/tasks/docs-links` and
`AGENTS.md` changes — per `AGENTS.md`'s self-improvement mandate, the learning lands with
the work, not as a follow-up. `mise run docs-links` must pass before the PR. Merge is the
human's call.

## Reference

- `AGENTS.md` § Skill files rot too — prune, don't just append (the rule this implements).
- `AGENTS.md` § Plan & Design Docs (`docs/design/` vs `docs/plans/`, and the freeze).
- `mise/tasks/docs-links` — the mechanical half; its header comment documents each check
  and why it is scoped the way it is.
- `docs/.links-ignore` — the two legitimate categories for a permanently unresolvable path.
- `docs/skills/dakota.md` — the 5385→450-line prune that established "executable config is
  the source of truth".
