# Renovate

Load when changing `.github/renovate.json5`, enabling a manager, or deciding whether a dependency should auto-merge. Expansion plan and per-source rationale: [`docs/design/renovate-expansion.md`](../design/renovate-expansion.md).

## Current coverage

| Manager | Files | Auto-merge |
|---|---|---|
| `github-actions` | `.github/workflows/*.yml` | digest/pin/patch/minor |
| `pep621` | `pyproject.toml` (+ `uv.lock`) | patch/minor, except the packages listed below |
| `custom.regex` | `RUNNER_VERSION` in `mise.toml` and `Containerfile.runner` | patch/minor |

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

Subjects are derived from the config's own `matchPackageNames`/`matchDepTypes`, so a new rule gets covered automatically. `(any other package)` is the fall-through: it proves the blanket auto-merge rule still applies to everything a rule does *not* name.

## `pep621`, not `uv`

There is no `uv` manager — `docs.renovatebot.com/modules/manager/uv/` is a 404. `pep621` owns `pyproject.toml` for pdm/uv/hatch/pixi projects alike and refreshes `uv.lock` by shelling out to `uv lock` when it changes a dependency, so lockfile and manifest stay in step without `lockFileMaintenance`.

Two extraction behaviours that need explicit rules:

- **`requires-python` is extracted as a dependency** named `python`, `depType: "requires-python"`. `requires-python = ">=3.12"` is a *floor*; a Renovate bump to `>=3.14` drops interpreter support rather than picking anything up. Disabled via `matchDepTypes: ["requires-python"]`.
- **Direct git references are extracted as PyPI packages.** `buildstream-sbom @ git+https://gitlab.com/…@<sha>` parses through Renovate's PEP 508 regex as `packageName: buildstream-sbom`, `currentValue: "@ git+https://…"`, `datasource: pypi`. Nothing sane can come of that lookup, and if the name ever appears on PyPI Renovate would offer to replace the git ref with a release. Disabled by name.

## Custom regex managers

`RUNNER_VERSION` lives in `mise.toml`'s `[env]` block, which Renovate's `mise` manager does not read (it only handles `[tools]`), so it needs a `custom.regex` manager. Four things about them are easy to get wrong:

1. **`enabledManagers` must list `"custom.regex"`.** With an allowlist in place, `customManagers` is silently skipped otherwise — no error, no PR, nothing in the log to notice.
2. **The config keys are `customManagers` + `customType: "regex"` + `managerFilePatterns`.** `regexManagers` and `fileMatch` are the old spellings; `renovate-config-validator --strict` fails on them.
3. **Renovate uses RE2, and matches per *file*, not per line.** No lookahead, no backreferences; `^`/`$` anchor the whole file. For a line boundary use `(?:^|\r\n|\r|\n|$)`.
4. **Tag prefixes need `extractVersionTemplate`.** `actions/runner` tags releases `v2.325.0` while both pins hold the bare `2.325.0`, so `"^v(?<version>.+)$"` strips the prefix — without it every lookup mismatches the current value.

### One manager, two files, one PR

The runner version is pinned twice — `mise.toml` `[env]` (what `mise run runner/build` passes as `--build-arg`) and the `ARG RUNNER_VERSION` default in `Containerfile.runner` (what a direct `podman build -f Containerfile.runner` uses). Both `managerFilePatterns` and both `matchStrings` live in a *single* custom manager so the two deps come out with the same `depName` and `currentValue`, which puts them on one branch: Renovate rewrites both files in one PR instead of bumping one and leaving the other to rot.

If the two pins ever drift apart, Renovate will open *two* branches (one per `currentValue`) — that is the drift showing up, not a config bug.

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
