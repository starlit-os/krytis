# CI Runner Reference

Load when working on GitHub Actions workflows, the self-hosted runner container, or BST cache in CI.

## Self-Hosted Runner in Podman

The runner container (`Containerfile.runner`) runs as root with `--privileged` — required for bubblewrap (BST sandboxing). Managed via `mise runner:*` tasks.

### Required flags / env

| Flag / env | Why |
|---|---|
| `--privileged` | bubblewrap requires unprivileged user namespaces, which need privileged mode in podman |
| `RUNNER_ALLOW_RUNASROOT=1` | GitHub Actions runner refuses to start as root without this |
| `--replace` on `podman run` | prevents "container name already in use" errors from stale stopped containers |

### PAT requirements

Fine-grained PAT with **Administration: Read and Write** on `starlit-os/krytis`. Stored as podman secret `gh-token`. Used only for deregistration (obtaining a remove token).

### Deregistration

**Do not rely on the container's EXIT trap.** The GitHub Actions runner binary intercepts SIGTERM internally and may not exit within podman's stop timeout, preventing the trap from firing. Instead, `runner:stop` deregisters via the GitHub API directly before stopping the container:

```bash
RUNNER_ID=$(gh api repos/starlit-os/krytis/actions/runners \
    --jq ".runners[] | select(.name == \"${RUNNER_NAME}\") | .id")
gh api -X DELETE "repos/starlit-os/krytis/actions/runners/${RUNNER_ID}"
```

### Stale offline runners

After an unclean shutdown the runner stays registered as `offline`. `runner:start` auto-removes any offline registration with the same name before re-registering. To remove one manually:

```bash
gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] | "\(.id) \(.name) \(.status)"'
gh api -X DELETE repos/starlit-os/krytis/actions/runners/<id>
```

### Dependencies (Ubuntu 24.04 base)

`libicu74` must be installed explicitly in the Containerfile. The runner's bundled `installdependencies.sh` doesn't work in a separate Docker layer (no apt lists). Without it the runner binary fails with "Libicu dependencies missing for .NET Core 6.0".

---

## BST Cache in CI

### casd quota

`cache.quota` in `buildstream.conf` controls the local CAS size. **4G is too small** for a full build — casd fills it, can't evict active blobs, and crashes:

```
OutOfSpaceException: disk usage above maximum quota and no inactive blobs are available for deletion
terminate called after throwing an instance of 'std::system_error'
```

Use **50G** for a full `cache-warm` build on a machine with adequate disk.

### `actions/cache` path spec determines the version hash

`actions/cache` computes an internal **version** from the `path:` input (a hash of paths + compression). This version is part of every lookup — including restore-key prefix matching. **Changing the path spec invalidates all prior cache entries, even those with matching key prefixes.**

```yaml
# These two configs produce different version hashes and cannot restore from each other:
path: ~/.cache/buildstream

path: |
  ~/.cache/buildstream
  !~/.cache/buildstream/sources
```

When changing `path:`, expect a cold-start run. Subsequent runs will find the cache.

### What to cache

The BST cache directory layout:

| Path | Content | Cache? |
|---|---|---|
| `cas/objects/` | Built artifact blobs | ✅ yes |
| `artifacts/` | Artifact refs (34 MB) | ✅ yes |
| `cas/tmp/` | casd staging (~18 GB) | ❌ no — transient |
| `logs/` | Build logs | ❌ no |
| `sources/` | Fetched source archives | ❌ no |
| `elementsources/` | Element source metadata | ❌ no |

When using `actions/cache`, pin the paths to exactly `cas/objects` and `artifacts`:

```yaml
path: |
  ~/.cache/buildstream/cas/objects
  ~/.cache/buildstream/artifacts
```

The self-hosted runner with a volume mount already persists the CAS between runs — `actions/cache` is only needed when a GitHub-hosted runner job will consume the cache.

### Clearing the CAS

BST has no native `artifact gc` command. To fully clear the cache:

```bash
bst artifact delete '**'          # remove all artifact refs
rm -rf ~/.cache/buildstream/cas/objects/ ~/.cache/buildstream/cas/tmp/
mkdir -p ~/.cache/buildstream/cas/objects/
```

### Freedesktop SDK remote cache errors

`cache.freedesktop-sdk.io:11001` (their BuildGrid CAS) occasionally returns:

```
OutOfSpaceException: Insufficient storage quota
```

This is a server-side error on their infrastructure — their CAS is full. BST logs it as `WARNING`/`FAILURE` for the cache pull but falls back to fetching sources from upstream and building locally. The build continues; it's just slower. No action needed on our side.

---

## uv sync in CI

Mise's experimental `[deps.uv]` feature (`outputs = [".venv/"]`) skips `uv sync` on re-runs if `.venv/` already exists. On a persistent self-hosted runner this means retried jobs find the venv but without the expected packages if the first run was incomplete.

**Fix:** add an explicit `uv sync` step after `mise bootstrap`:

```yaml
- name: Install Python dependencies
  run: uv sync
```

Don't rely on `[deps.uv]` auto-run for correctness in CI.

---

## GitHub Actions: SHA Pinning and Org Allowlist

### SHA pinning — let the linter handle it

Do not manually look up and pin action SHAs when writing a new workflow. Write the version tag (`uses: actions/checkout@v4`) and commit. The linter (`mise lint`) runs `actionlint` which auto-upgrades floating tags to full commit SHAs with a version comment. The pinned SHA lands in the same PR automatically.

### Org allowlist

The `starlit-os` org has an allowlist of permitted external actions. Any `uses: <owner>/<repo>` not already on the list will be blocked at runtime with a permissions error — the workflow job simply won't start.

When adding a new action to any workflow, check whether `<owner>/<repo>` is already allowlisted. If not, prompt the user to add it before the PR is merged. The allowlist is managed in the org's GitHub Actions settings.

## Buildbarn CAS (Quadlet)

krytis owns a Buildbarn deployment (`bb-storage` + `bb-remote-asset`) on the
self-hosted runner box, providing both a source cache (fixes upstream churn
like #233's CachyOS 404) and an artifact cache for krytis-specific elements.
See #234 and its sub-issues for the design rationale.

### Why Quadlet instead of `podman run` (unlike the runner)

The self-hosted runner (`mise runner:*`) is manually started/stopped around
CI activity — a `podman run` wrapper fits that lifecycle. Buildbarn is a
**persistent** host service that should survive reboots and restart on
failure, so it's modeled as Podman Quadlet units (`quadlet/buildbarn/`)
instead: `systemctl start/stop bb-storage bb-asset` after
`mise buildbarn:install` copies the units into
`/etc/containers/systemd/` and reloads systemd. There's no `buildbarn:start`/
`buildbarn:stop` mise task — quadlet-generated `.service` units already give
us that via `systemctl`, and duplicating it in a mise task would just be a
less capable wrapper around the thing systemd already provides.

### mTLS: SAN-based push/pull split, not CN

Buildbarn's `AuthenticationPolicy.tlsClientCertificate` supports a
`validation_jmespath_expression`, but its docs explicitly recommend using it
for **authentication** decisions, not **authorization** — a failed match
returns `UNAUTHENTICATED`, not `PERMISSION_DENIED`, so gating write access
this way muddies the error semantics of a not-yet-registered pull cert vs. a
valid pull cert trying to push. Instead: one CA signs two client certs (SAN
`spiffe://krytis/ci-push` for CI, `spiffe://krytis/pull` for everyone else),
and the actual push/pull split is enforced per-operation via `putAuthorizer`/
`pushAuthorizer` (`jmespathExpression` matching the SAN) vs. `getAuthorizer`/
`fetchAuthorizer` (`allow: {}` for any cert signed by the CA). CN was
considered and rejected — SAN is what Buildbarn's own docs use for this kind
of identity check.

### Volume naming for Quadlet-referenced `.volume` units

A `.container` unit's `Volume=` line referencing a sibling `.volume` unit
must keep the **`.volume` suffix** — `Volume=buildbarn-storage-cas.volume:/data/storage-cas`.
Dropping the suffix (`Volume=buildbarn-storage-cas:/data/storage-cas`) looks
plausible but silently breaks unit-reference detection: `/usr/libexec/podman/quadlet
-dryrun` shows the generated `ExecStart=` falls back to treating the name as
a literal podman volume (`-v buildbarn-storage-cas:...`) instead of the
managed `systemd-<name>` volume the sibling `.volume` unit actually creates
(`-v systemd-buildbarn-storage-cas:...`) — two different volumes, one of
which is never created by the `-volume.service` unit. Always dry-run new
quadlet units with `QUADLET_UNIT_DIRS=<dir> /usr/libexec/podman/quadlet
-dryrun -no-kmsg-log` and grep the `ExecStart=` line for the `systemd-`
prefix on every volume reference before trusting the unit.

### First-deploy verification still pending

The jsonnet configs and quadlet units in this section are a first pass
written against Buildbarn's documented config schema and `bb-deployments`
reference examples — not yet exercised against a live deploy. Before relying
on this in CI, run `mise buildbarn:install` on the runner box and confirm:
both services start (`mise buildbarn:status`), a `pull`-cert client can
fetch, and only the `ci-push`-cert client can push (a `pull`-cert push
attempt should fail, not silently succeed).

## Workflow Runner Choices

| Workflow | Runner | Rationale |
|---|---|---|
| `cache-warm.yml` | `[self-hosted, linux, x64]` | Needs local BST cache volume mount and full disk |
| `track-bst-sources.yml` | `ubuntu-24.04` | Lightweight; must run when local machine is off |

## `max-jobs` should only be set high when remote-execution is on

*Source: zirconium-hawaii `aceeb13` — `fix: set max-jobs to 12 only when remote-execution is on`*

Setting `max-jobs` high (e.g. 12–32) on a local GitHub Actions runner **without** remote CAS causes problems — the runner doesn't have the CPU/RAM to actually parallelize that many local builds, and they contend for resources. Only raise `max-jobs` when remote-execution is enabled (the actual builds happen on the CAS server cluster). Gate the `max-jobs` setting on the remote-execution flag rather than setting it unconditionally.

## Use smaller/less-privileged CAS config for no-push phase

*Source: zirconium-hawaii `4a9b19c` — `chore: Use smaller config for no-push phase`*

When running a build phase that doesn't push to CAS (e.g. a validation-only or no-push CI phase), don't specify the key/auth/mTLS config. Use a smaller, less-privileged CAS client config that authenticates read-only or anonymously. Less privilege = smaller blast radius if the config leaks, and fewer moving parts that can fail on a phase that doesn't need push capability.

## `track-bst-sources.yml` per-job gotchas

Each `track-<element>` job in this workflow is hand-written (no shared template), so two requirements don't propagate automatically when copy-pasting a new job:

- **`gh` needs `GH_TOKEN` on the specific step that calls it.** `gh api`/`gh` CLI calls fail with `gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable` if the `env:` block is missing on that step — the job-level `permissions:` block does not supply it. Check whether the underlying `mise run <x>-update` task shells out to `gh` before assuming it's not needed (e.g. `falcond-profiles-update` uses `gh api` to get the latest commit SHA since the upstream repo has no releases; `falcond-update` doesn't, since it scrapes an HTML page instead).
- **`bst source track` needs bubblewrap.** Only jobs that run `mise bootstrap --yes` (an "Install system dependencies" step) have `bwrap` on the runner. If a `<x>-update` mise task starts invoking `bst source track` (e.g. `scx-loader-update` added this to refresh a `cargo2` crate list), the job needs that step added — otherwise it fails with `Could not find bubblewrap command "bwrap"`.
