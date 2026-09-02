# Renovate

Load when changing `.github/renovate.json5`, enabling a manager, or deciding whether a dependency should auto-merge. Expansion plan and per-source rationale: [`docs/design/renovate-expansion.md`](../design/renovate-expansion.md).

## `platformCommit`

Every manager commits via the GitHub API (Contents/GraphQL) rather than a raw
git push — `"platformCommit": "enabled"` at the top level. API-authored
commits are auto-signed by GitHub regardless of caller credential, which is
what lets these PRs merge once `main` requires signed commits (#154, #698).
No other behavior changes; this is purely how the commit object gets
created.

## Current coverage

| Manager | Files | Auto-merge |
|---|---|---|
| `github-actions` | `.github/workflows/*.yml` | digest/pin/patch/minor |
| `pep621` | `pyproject.toml` (+ `uv.lock`) | patch/minor, except the packages listed below |
| `mise` | `mise.toml` `[tools]` (+ `mise.lock`) | digest/pin/patch/minor — except `pass-cli` (see below), which is never |
| `custom.regex` | `RUNNER_VERSION` in `mise.toml` and `Containerfile.runner`; the `pass-cli` pin | patch/minor; `pass-cli` never |

Everything else is tracked by the `track-bst-sources.yml` CI matrix, not Renovate — see [`bst.md`](bst.md) § Element update path.

## Verifying a config change

```bash
mise run renovate-check              # validate (repo config, --strict)
mise run renovate-check --explain    # resolve every rule to enabled/automerge
mise run renovate-check --dry-run    # extract + look up against the working tree
```

All three run Renovate's own code in `ghcr.io/renovatebot/renovate:latest`. Never reach for `npx renovate`: npm resolves `renovate@latest` against the host node's `engines` field, and on a node newer than the newest release supports it silently walks *back* to an ancient major — node 26 gets Renovate **37.x**, which validates against a schema years out of date and reports nothing wrong. The container also matches what the hosted Mend app runs, which is always the newest release; that is why `:latest` is deliberate here rather than a pinned digest.

### `renovate-config-validator` validates a *global* config if you pass it a path

```
$ renovate-config-validator .github/renovate.json5
 INFO: Validating .github/renovate.json5 as global config     ← wrong mode
$ renovate-config-validator                                    ← auto-discovery
 INFO: Validating .github/renovate.json5
```

An explicit path makes the validator treat the file as *global* (self-hosted admin) config and skip repo-scoped checks. Run it with no arguments from the repo root. Add `--strict` so migration warnings fail the run too — that is what caught `baseBranches` needing to become `baseBranchPatterns`.

### `--dry-run` does not tell you whether something will auto-merge

`renovate --platform=local --dry-run=full` stops after extract + lookup (`"splits": {…, "update": 0}`); branch config is never materialised, so `automerge` never appears in the log. Use `--explain`, which calls Renovate's own `applyPackageRules()` (`scripts/renovate-explain.mjs`) against the real config and prints a verdict per package per update type:

```
  pep621
    click                          digest=hold  pin=hold  patch=hold  minor=hold  major=hold
    python                         digest=off   pin=off   patch=off   minor=off   major=off
    (any other package)            digest=AUTO  pin=AUTO  patch=AUTO  minor=AUTO  major=hold
```

Subjects are derived from the config's own `matchPackageNames`, `matchDepNames` and `matchDepTypes`, so a new rule gets covered automatically. `(any other package)` is the fall-through: it proves the blanket auto-merge rule still applies to everything a rule does *not* name. A rule with no `matchManagers` shows up under every manager — that is the rule's real scope, not a display bug. What the table cannot show is `allowedVersions`: it filters candidate *versions*, so its effect is visible only in a `--dry-run`.

## `pep621`, not `uv`

There is no `uv` manager — `docs.renovatebot.com/modules/manager/uv/` is a 404. `pep621` owns `pyproject.toml` for pdm/uv/hatch/pixi projects alike and refreshes `uv.lock` by shelling out to `uv lock` when it changes a dependency, so lockfile and manifest stay in step without `lockFileMaintenance`.

Two extraction behaviours that need explicit rules:

- **`requires-python` is extracted as a dependency** named `python`, `depType: "requires-python"`. `requires-python = ">=3.12"` is a *floor*; a Renovate bump to `>=3.14` drops interpreter support rather than picking anything up. Disabled via `matchDepTypes: ["requires-python"]`.
- **Direct git references are extracted as PyPI packages.** `buildstream-sbom @ git+https://gitlab.com/…@<sha>` parses through Renovate's PEP 508 regex as `packageName: buildstream-sbom`, `currentValue: "@ git+https://…"`, `datasource: pypi`. Nothing sane can come of that lookup, and if the name ever appears on PyPI Renovate would offer to replace the git ref with a release. Disabled by name.

## The `mise` manager

Reads `mise.toml` `[tools]` only — `[env]` values need a custom manager (see below) — and picks each tool's datasource out of the [mise registry](https://mise.jdx.dev/registry.html), so any registry tool on a supported backend works without configuration. It also reads `mise.lock`, reporting each tool's `lockedVersion` alongside the pin.

**The native manager auto-merges patch/minor/digest bumps; the `pass-cli` custom-regex pin does not.** Renovate's `mise` manager updates `mise.lock` in the same commit as the `mise.toml` bump when it changes a dependency — proven reliable across every native-manager PR since 2026-08 (zero CI failures) — so it inherits the repo's default `automerge: true` for digest/patch/minor. `pass-cli` comes from a `custom.regex` manager instead (see below) and does *not* get that lockfile treatment: two of its PRs (2026-08-25, 2026-08-27) landed with a stale `mise.lock` entry and failed CI's `mise install --locked` step, needing a manual force-push fix — so that rule stays `automerge: false`. Either way, CI's `mise install --locked` (`checks.yml`, via `jdx/mise-action`) hard-fails on any `mise.toml`/`mise.lock` mismatch, which is what makes auto-merging the native manager safe — see [`mise.md`](mise.md) § `mise.lock`.

Two tools need rules of their own:

- **`python` is capped at `allowedVersions: "<3.13"`.** It resolves to `python/cpython` on the `github-tags` datasource, so without a ceiling Renovate offers the newest CPython tag. The pin tracks `pyproject.toml`'s `requires-python = ">=3.12"`, so patch bumps are routine and the minor boundary is a human decision.
- **`pass-cli` is not in the mise registry.** The manager extracts it (`depType: "tools"`, `lockedVersion` and all) but gives up with `skipReason: "unsupported-datasource"` — the `[tool_alias]` pointing at the `github:` backend is a mise-side detail Renovate does not read. A `custom.regex` manager covers that one line instead.

A tool pinned to `"latest"` is extracted with nothing to compare against, so it is invisible to the update loop. Pinning every tool (#24) is what makes this manager useful at all.

## Custom regex managers

Two pins need one: `RUNNER_VERSION`, which lives in `mise.toml`'s `[env]` block that the `mise` manager does not read, and `pass-cli`, which is in `[tools]` but absent from the mise registry. Four things about custom managers are easy to get wrong:

1. **`enabledManagers` must list `"custom.regex"`.** With an allowlist in place, `customManagers` is silently skipped otherwise — no error, no PR, nothing in the log to notice.
2. **The config keys are `customManagers` + `customType: "regex"` + `managerFilePatterns`.** `regexManagers` and `fileMatch` are the old spellings; `renovate-config-validator --strict` fails on them.
3. **Renovate uses RE2, and matches per *file*, not per line.** No lookahead, no backreferences; `^`/`$` anchor the whole file. For a line boundary use `(?:^|\r\n|\r|\n|$)`.
4. **Tag prefixes need `extractVersionTemplate`.** `actions/runner` tags releases `v2.325.0` while both pins hold the bare `2.325.0`, so `"^v(?<version>.+)$"` strips the prefix — without it every lookup mismatches the current value.

### One manager, two files, one PR

The runner version is pinned twice — `mise.toml` `[env]` (what `mise run runner/build` passes as `--build-arg`) and the `ARG RUNNER_VERSION` default in `Containerfile.runner` (what a direct `podman build -f Containerfile.runner` uses). Both `managerFilePatterns` and both `matchStrings` live in a *single* custom manager so the two deps come out with the same `depName` and `currentValue`, which puts them on one branch: Renovate rewrites both files in one PR instead of bumping one and leaving the other to rot.

If the two pins ever drift apart, Renovate will open *two* branches (one per `currentValue`) — that is the drift showing up, not a config bug.

### Match the version, not every line with that key

`pass-cli` appears twice in `mise.toml` — once under `[tool_alias]` mapping the short name to the `github:` backend, once under `[tools]` as the pin:

```toml
[tool_alias]
pass-cli = "github:protonpass/pass-cli"
[tools]
pass-cli = "2.2.3"
```

`pass-cli = "(?<currentValue>[^"]+)"` matches both, and the alias line yields a dep whose "version" is `github:protonpass/pass-cli`. Requiring a leading digit — `"(?<currentValue>\d[^"]*)"` — pins the match to the real version without needing lookahead, which RE2 does not have anyway.

### Prove the round trip, not just the match

A `--dry-run` showing the dep extracted only proves half of it. The other half — that the pin Renovate *writes* is one it will then read back as current — is what stops a manager opening the same PR forever. Check the `replaceString` in the debug log is the whole assignment, apply the bump by hand, and confirm the update disappears:

```bash
sed -i 's/2\.325\.0/2.336.0/' mise.toml Containerfile.runner
mise run renovate-check --dry-run --log-level debug   # actions/runner gone from "flattened updates found"
git restore mise.toml Containerfile.runner
```

Commit before simulating, and restore with `git restore` — never `git checkout <path>`, which silently discards unstaged work elsewhere in the tree.

## Rule ordering

`packageRules` are applied in order and later rules win, so the blanket auto-merge rule stays first and the exception rules follow it with `automerge: false`. Verify with `--explain` rather than reasoning about it.

Exceptions carry `prBodyNotes` instead of a label: the note renders in the PR body where the human deciding whether to merge is already looking, and it needs no repo label to exist first. `addLabels` would require creating the label out-of-band, which is not reproducible from the repo.

Two families are held for manual merge:

- `click`, `dulwich` — hard-pinned in `pyproject.toml` for BuildStream 2.5.x compatibility (see the comments there). A bump has to survive `mise run validate` and `mise run build`.
- `buildstream`, `buildstream-plugins`, `buildstream-plugins-community` — coupled to the junction pins in `elements/freedesktop-sdk.bst` / `elements/gnome-build-meta.bst`, which may need bumping in lockstep.

## Auto-merge works here despite no `pull_request` workflow

Renovate waits for a passing status check before calling GitHub's auto-merge API (`platformAutomerge`, default `true`). A repo with **zero** checks on the PR never satisfies that and the PR sits open forever with `autoMergeRequest: null` and no error — the failure mode called out in [#14](https://github.com/starlit-os/krytis/issues/14#issuecomment-4853545174).

None of `cache-warm.yml`, `publish.yml`, or `track-bst-sources.yml` trigger on `pull_request`, so this repo looks like exactly that case — but it is not. Blacksmith's app posts a single `[code]smith` check run on every PR (verified on #420, #423, #425, #426 — bot- and human-authored alike), and its `SKIPPED` conclusion counts as resolved rather than pending. Evidence, PR #426 (`jdx/mise-action` v4.2.4): created `16:42:26Z`, auto-merge enabled `16:42:27Z`, check run completed `16:42:28Z`, merged by `app/renovate` at `16:42:30Z` — four seconds end to end. So `ignoreTests` is not needed, and no new manager needs its own workflow to unblock merging.

Re-check this if the Blacksmith app is ever removed: the symptom is a PR that is `MERGEABLE`/`CLEAN` with `autoMergeRequest` null indefinitely, and

```bash
gh pr view <n> --json autoMergeRequest,statusCheckRollup
```

is enough to tell the two cases apart.
