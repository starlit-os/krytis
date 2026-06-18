# Plan: Renovate Expansion

## Context

Renovate is currently configured with a single manager (`github-actions`) that
SHA-pins and auto-merges Action digest/patch/minor updates. Everything else in
the project is updated manually. This document tracks what else Renovate could
own.

---

## Current coverage

| What | Manager | Auto-merge? |
|------|---------|-------------|
| GitHub Actions `uses:` | `github-actions` | Yes (digest/patch/minor) |

---

## Candidates to investigate

### mise tools (`mise.toml` `[tools]`)

`usage`, `python`, `uv`, `gum` are all pinned to `"latest"` — unpinned and
invisible to Renovate. Options:

- Enable the `mise` manager in `enabledManagers` — Renovate has native support
  for `mise.toml` tool versions.
- Pin tools to explicit versions first (e.g. `uv = "0.7.13"`) so Renovate has
  something to bump. Commit `mise.lock` for reproducible installs.
- See also: `runner-followup.md` §3 for `RUNNER_VERSION` which needs a regex
  manager since it lives in `[env]`, not `[tools]`.

### Python dependencies (`pyproject.toml` / `uv.lock`)

`buildstream`, `buildstream-plugins`, `buildstream-plugins-community`,
`click==8.2.1`, `dulwich==0.24.0`, `requests`, `tomlkit`. Options:

- Enable the `uv` or `pep621` manager to track `pyproject.toml`.
- `click` and `dulwich` are hard-pinned for compatibility reasons — Renovate
  PRs for these need manual review, not auto-merge. Add a `packageRule` to
  exclude them from auto-merge, or pin with a comment explaining the constraint
  so the PR description is informative.

### BST element sources (remote binaries)

`core/mise.bst` `RUNNER_VERSION` (in `runner-followup.md`), and any future
`remote`-sourced elements. These need `regexManagers` since there is no
first-class BST datasource. Pattern established in `runner-followup.md` §3.

### Freedesktop SDK / gnome-build-meta junctions

Already tracked by the `track-core-junctions` CI job — Renovate would be
redundant here and could conflict. Leave with CI tracking.

### Linux kernel (`core/linux-cachyos.bst`)

Already tracked by `track-linux-cachyos` CI job. Leave with CI tracking.

### `buildstream` version in `pyproject.toml`

Tied closely to junction versions — a BST upgrade may require junction bumps
in lockstep. Auto-merge is risky. Could add a Renovate PR for visibility but
require manual merge.

---

## Suggested next steps

1. Pin mise tool versions + commit `mise.lock` (prerequisite for mise manager).
2. Add `mise` to `enabledManagers`; add a `packageRule` for mise tools.
3. Add `uv` or `pep621` to `enabledManagers` for Python deps; add a rule to
   exclude `click` and `dulwich` from auto-merge.
4. Add a `regexManager` for `RUNNER_VERSION` (see `runner-followup.md` §3).
5. Revisit `buildstream` version tracking once the junction/BST coupling is
   better understood.
