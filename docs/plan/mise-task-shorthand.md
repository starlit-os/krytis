# Plan: Mise Task Shorthand Audit

## Context

Mise tasks can be invoked as `mise run <task>` (canonical) or `mise <task>`
(shorthand). The shorthand works for any task name that does not collide with a
mise built-in subcommand. Using the shorter form in docs and workflow steps
reduces noise without any functional difference.

---

## Findings (2026-06-18)

All current tasks were checked against `mise --help` built-in subcommands.
**No conflicts found** — every task in the project supports the shorthand today.

| Task | Shorthand | Notes |
|------|-----------|-------|
| `bst` | `mise bst` | ✓ |
| `validate` | `mise validate` | ✓ |
| `generate-image-version` | `mise generate-image-version` | ✓ (`generate` is a built-in but exact match is not hit) |
| `lint` | `mise lint` | ✓ |
| `load-image` | `mise load-image` | ✓ |
| `generate-disk` | `mise generate-disk` | ✓ |
| `boot-vm` | `mise boot-vm` | ✓ |
| `kernel-update` | `mise kernel-update` | ✓ |
| `runner:build` | `mise runner:build` | ✓ confirmed working |
| `runner:start` | `mise runner:start` | ✓ |
| `runner:stop` | `mise runner:stop` | ✓ |
| `runner:logs` | `mise runner:logs` | ✓ |
| `runner:status` | `mise runner:status` | ✓ confirmed working |
| `u2f-login` | `mise u2f-login` | ✓ |

---

## What to update

1. **`AGENTS.md`** — the `bst.md` skill and any inline examples currently use
   `mise run <task>`. Update to shorthand.

2. **`docs/skills/bst.md`** — task reference table uses `mise run bst ...`.
   Update all `mise run` examples to `mise <task>`.

3. **`docs/skills/mise.md`** — same audit; replace `mise run` with shorthand
   where appropriate.

4. **`docs/plan/ci-workflows.md`** — any `mise run` references in prose.

5. **Workflow files** (`.github/workflows/*.yml`) — steps like
   `mise run kernel-update`, `mise run generate-image-version` can be shortened.
   Lower priority; functional either way.

6. **New task files** (`mise/tasks/runner/*`) — already documented with shorthand
   in `docs/plan/runner-verification.md`.

---

## Convention going forward

Use `mise <task>` (shorthand) in all documentation and workflow steps. Reserve
`mise run` only in contexts where the shorthand would be ambiguous (none currently
known) or in shell scripts where explicitness aids readability.

**Watch list:** task names to avoid in future (would conflict with built-ins):
`set`, `env`, `exec`, `shell`, `install`, `use`, `link`, `sync`, `lock`, `watch`,
`cache`, `generate`, `ls`, `prune`, `upgrade`, `version`, `which`, `where`.
