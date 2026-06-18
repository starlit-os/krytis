# Plan: Convert Planning Documents to GitHub Issues

## Status: complete

Project board: https://github.com/orgs/starlit-os/projects/1

Milestones: `v0.1 — bootable baseline`, `v0.2 — desktop`, `v0.3 — secure`

---

## Context

Planning documents in `docs/plan/` are useful for detailed design notes but
are invisible to collaborators, not trackable, and can't express dependencies
or progress. Converting them to GitHub issues (with sub-issues and a project
board) makes work visible, prioritisable, and linkable from PRs.

---

## Inventory

| Document | Disposition | Tracked-by |
|---|---|---|
| `ci-workflows.md` | Largely done; one gap remaining | #18 |
| `native-bst-local-dev.md` | Sub-issue under self-build (#13) | #22 |
| `mise-task-shorthand.md` | Complete — no issue needed | — |
| `renovate-expansion.md` | Parent issue with four sub-issues | #14 |
| `runner-followup.md` | Two issues: systemd service + RUNNER_VERSION tracking | #19, #27 |
| `composefs-chunkah.md` | Parent issue with three sub-issues (deferred to v0.2) | #15 |
| `deferred-from-dakota.md` | Four issues under desktop parent | #17, #35–#38 |
| `secure-boot-uki.md` | Parent issue with four sub-issues | #16 |
| `multimedia-codecs.md` | Sub-issue under desktop parent | #35 |
| `self-build.md` | Parent issue with four sub-issues | #13 |
| `runner-verification.md` | Complete — runner validated, cache-warm on self-hosted | — |

---

## GitHub structure

1. **Project board** — https://github.com/orgs/starlit-os/projects/1
   Status options: Todo → In Progress → In Review → Done

2. **Milestones**
   - `v0.1 — bootable baseline` — CI tracking, self-build, composefs
   - `v0.2 — desktop` — multimedia, chunkah, memory-safe userspace, optional elements
   - `v0.3 — secure` — secure boot / UKI

3. **Issue hierarchy** — GitHub native sub-issues used throughout. Parents:
   - #13 Enable self-build → #20 #21 #22 #23
   - #14 Expand Renovate coverage → #24 #25 #26 #27
   - #15 Add chunkah pipeline → #28 #29 #30
   - #16 Implement secure boot → #31 #32 #33 #34
   - #17 Build desktop stack → #35 #36 #37 #38

4. **Issue title convention** — ≤5-word imperative rule from `AGENTS.md`.
