# Plan: Convert Planning Documents to GitHub Issues

## Context

Planning documents in `docs/plan/` are useful for detailed design notes but
are invisible to collaborators, not trackable, and can't express dependencies
or progress. Converting them to GitHub issues (with sub-issues and a project
board) makes work visible, prioritisable, and linkable from PRs.

---

## Inventory

Review each document and decide: top-level issue, sub-issue of another, or
reference-only (keep as a doc, no issue needed).

| Document | Suggested disposition |
|---|---|
| `ci-workflows.md` | Top-level issue: "Implement CI workflows" — largely done; open sub-issues for remaining gaps (track-mise job, cache-warm migration to self-hosted) |
| `native-bst-local-dev.md` | Likely complete — verify and close or convert to a done sub-issue |
| `mise-task-shorthand.md` | Top-level issue: "Use mise task shorthand throughout docs and workflows" with sub-issues per file (AGENTS.md, bst.md, mise.md, workflow files) |
| `renovate-expansion.md` | Top-level issue: "Expand Renovate coverage" with sub-issues per candidate (mise tools, Python deps, BST remote elements, RUNNER_VERSION) |
| `runner-followup.md` | Sub-issues under a "Self-hosted runner" parent: cache-warm migration, systemd user service, Renovate tracking for RUNNER_VERSION |
| `composefs-chunkah.md` | Top-level issue (or sub-issue of a composefs parent) — read doc to determine scope |
| `deferred-from-dakota.md` | Read and triage: each deferred item becomes its own issue or is explicitly dropped |
| `secure-boot-uki.md` | Top-level issue: "Secure boot / UKI" — likely a milestone-level item |
| `multimedia-codecs.md` | Top-level issue: "Multimedia codecs" |

---

## GitHub structure to set up

1. **Project board** — create a GitHub Project (table or board view) for
   krytis to track all open work in one place.

2. **Milestones** (optional) — consider milestones for large themes:
   - `v0.1 — bootable baseline` (CI, composefs, secure boot)
   - `v0.2 — desktop` (multimedia, greeter polish)

3. **Issue hierarchy** — GitHub supports sub-issues natively (issues can be
   added as "tracked by" / "tracks" relationships). Use this rather than
   task-list checkboxes in the body, so each sub-item is individually
   closeable and linkable.

4. **Issue title convention** — follow the ≤5-word imperative rule from
   `AGENTS.md` (e.g. "Add mise tracking job", not "We need to add a job that
   tracks the mise element version in the BST pipeline").

---

## Suggested next steps

1. Read each doc listed above and draft issue titles + descriptions.
2. Create the GitHub Project board.
3. Open issues top-down (parents before children so sub-issue links work).
4. Link issues back to the relevant `docs/plan/` doc in the issue body for
   the detailed design notes.
5. Once an issue is open, add a `Tracked-by: #NNN` line to the plan doc so
   the two stay connected.
6. Deprecate plan docs that are fully superseded by issues — either delete
   them or add a header note pointing to the issue.
