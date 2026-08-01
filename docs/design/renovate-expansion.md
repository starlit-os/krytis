# Plan: Renovate Expansion

## Context

Renovate started with a single manager (`github-actions`) that SHA-pins and
auto-merges Action digest/patch/minor updates; `pep621` was added for
`pyproject.toml` in #26. Everything else in the project is updated manually or
by the `track-bst-sources.yml` CI matrix. This document tracks what else
Renovate could own.

**Principle: prefer Renovate over manual or custom CI tracking wherever
possible.** Renovate provides consistent PR descriptions, configurable
auto-merge, audit trails, and cross-repo coordination without custom scripting.
Custom CI jobs (e.g. `track-linux-cachyos`) are appropriate only when no
Renovate datasource covers the source — treat them as a last resort, not a
default.

---

## Current coverage

| What | Manager | Auto-merge? |
|------|---------|-------------|
| GitHub Actions `uses:` | `github-actions` | Yes (digest/patch/minor) |
| `pyproject.toml` + `uv.lock` | `pep621` | Yes, except `click`/`dulwich`/`buildstream*` (held for review) and `requires-python`/`buildstream-sbom` (disabled) |
| `RUNNER_VERSION` in `mise.toml` + `Containerfile.runner` | `custom.regex` | Yes (patch/minor) |

Config changes are verified with `mise run renovate-check` (`--explain` resolves
every rule to its enabled/auto-merge verdict; `--dry-run` lists pending
updates). Operational detail lives in `docs/skills/renovate.md`.

---

## Candidates to investigate

### mise tools (`mise.toml` `[tools]`)

`usage`, `python`, `uv`, `gum` are all pinned to `"latest"` — unpinned and
invisible to Renovate. Options:

- Enable the `mise` manager in `enabledManagers` — Renovate has native support
  for `mise.toml` tool versions.
- Pin tools to explicit versions first (e.g. `uv = "0.7.13"`) so Renovate has
  something to bump. Commit `mise.lock` for reproducible installs.
- `RUNNER_VERSION` also lives in `mise.toml`, but in `[env]` rather than
  `[tools]`, so the `mise` manager will never see it — it is covered by a
  `custom.regex` manager instead (#27).

### Python dependencies (`pyproject.toml` / `uv.lock`) — done (#26)

`pep621` is the manager (there is no `uv` manager); it also refreshes `uv.lock`
via `uv lock`. Held back from auto-merge: `click`/`dulwich` (hard-pinned for
BuildStream 2.5.x) and the `buildstream*` family (junction-coupled, see below),
each carrying a `prBodyNotes` explanation. Disabled outright: `requires-python`
(a `>=` floor, not a pin) and `buildstream-sbom` (a `git+https://…@<sha>`
direct reference the pypi datasource cannot represent).

### BST element sources (remote binaries)

Any future `remote`-sourced element needs a `custom.regex` manager, since there
is no first-class BST datasource. `RUNNER_VERSION` (#27) is the worked example
of the pattern: `customManagers` + `customType: "regex"`, `"custom.regex"` added
to `enabledManagers`, and `extractVersionTemplate` where upstream tags carry a
`v` prefix the pin does not.

### Freedesktop SDK / gnome-build-meta junctions

Already tracked by the `track-core-junctions` CI job — Renovate would be
redundant here and could conflict. Leave with CI tracking.

### Linux kernel (`core/linux-cachyos.bst`)

Already tracked by `track-linux-cachyos` CI job. Leave with CI tracking.

### `buildstream` version in `pyproject.toml` — partly settled (#26)

Tied closely to junction versions — a BST upgrade may require junction bumps
in lockstep. Auto-merge is therefore off for `buildstream`,
`buildstream-plugins`, and `buildstream-plugins-community`: Renovate opens the
PR for visibility and a human decides whether `elements/freedesktop-sdk.bst` /
`elements/gnome-build-meta.bst` need bumping alongside it. Revisit whether the
coupling can be encoded (rather than left to review) once it is better
understood.

---

## Suggested next steps

1. Pin mise tool versions + commit `mise.lock` (prerequisite for mise manager).
2. Add `mise` to `enabledManagers`; add a `packageRule` for mise tools.
3. ~~Add `pep621` to `enabledManagers` for Python deps; exclude `click` and
   `dulwich` from auto-merge.~~ Done in #26.
4. ~~Add a `regexManager` for `RUNNER_VERSION` (see
   `docs/plans/done/2026-06-18-runner-followup.md` §3).~~ Done in #27, as a
   `custom.regex` manager covering both pins.
5. Revisit `buildstream` version tracking once the junction/BST coupling is
   better understood.
