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

## Workflow Runner Choices

| Workflow | Runner | Rationale |
|---|---|---|
| `cache-warm.yml` | `[self-hosted, linux, x64]` | Needs local BST cache volume mount and full disk |
| `track-bst-sources.yml` | `ubuntu-24.04` | Lightweight; must run when local machine is off |
