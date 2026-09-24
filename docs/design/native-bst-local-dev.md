# Plan: Native BST for Local Dev

Status: **shipped.** `mise run bst` is native-by-default with a `--container`
fallback, and `validate`/`load-image` forward the flag. Sections below are the
design record; where the shipped code has moved past the sketch it is called out
inline.

## Motivation

The current `mise run bst` task wraps BuildStream in the upstream `bst2` podman
container. This guarantees a hermetic environment but adds overhead: every BST
invocation pulls (on first run) or starts a privileged container. For everyday
tasks like `bst source track`, `bst show`, and `bst build`, native BST on Fedora
works equally well and is substantially faster.

The CI port (see the CI workflow plan) already commits to native BST via
`uv`+`mise`. Aligning local dev with CI eliminates the dev/CI split that
zirconium-hawaii accepts.

## Current state

`mise/tasks/bst` wraps:

```bash
podman run --rm --privileged --device /dev/fuse --network=host \
    --memory "${BST_MEMORY_LIMIT}" \
    -v "$(pwd):/src:rw" \
    -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
    -w /src \
    "${BST2_IMAGE}" bash -c 'bst --colors "$@"' -- ${FLAGS} "$@"
```

`mise/tasks/validate` and `mise/tasks/load-image` call `./mise/tasks/bst`
directly, so they inherit this container invocation.

## Target state

`mise run bst` defaults to `uv run bst`. A `--container` flag switches it to the
existing podman invocation for systems without local BST dependencies (restricted
user namespaces, non-Fedora hosts, etc.). The `--container` flag is propagated
through `validate` and `load-image` so any task can be run container-backed
without editing task files. No separate `bst-container` task is needed.

## Changes required

### `mise.toml`

`[tools]` gained `python` and `uv`. Both were sketched here as `python = "3.12"` /
`uv = "latest"`; they are now **exact pins** (`python = "3.12.14"`,
`uv = "0.12.18"`) because Renovate's `mise` manager cannot bump a `"latest"`
literal — see `docs/design/renovate-expansion.md` (#24/#25).

`[settings]`:
```toml
python.uv_venv_auto = "create|source"
```

`[deps.uv]`:
```toml
[deps.uv]
auto = true
sources = ["pyproject.toml", "uv.lock"]
outputs = [".venv/"]
run = "uv sync"
```

The `BST2_IMAGE` env var stays for the `--container` path; it is no longer
referenced by the default native path.

### `mise/tasks/bst`

Replaced the podman invocation with a native-by-default task that accepts
`--container` to fall back to podman:

```bash
#!/usr/bin/env bash
#MISE description="Run any bst command (native uv venv by default; --container for podman)"
#USAGE flag "--container" help="Use the pinned bst2 podman container instead of native BST"
#USAGE arg "<args>" var=true help="bst subcommand and arguments"

set -euo pipefail
DEFAULT_FLAGS="-o x86_64_v3 true --no-interactive"
FLAGS="${BST_FLAGS_OVERRIDE:-${DEFAULT_FLAGS} ${BST_FLAGS:-}}"

if [ "${usage_container:-false}" = "true" ]; then
    mkdir -p "${HOME}/.cache/buildstream"
    # shellcheck disable=SC2086
    exec podman run --rm \
        --privileged --device /dev/fuse --network=host \
        --memory "${BST_MEMORY_LIMIT}" \
        -v "$(pwd):/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "${BST2_IMAGE}" bash -c 'bst --colors "$@"' -- ${FLAGS} "$@"
fi

# shellcheck disable=SC2086
exec uv run bst --colors ${FLAGS} "$@"
```

The shipped task has since grown past this sketch: `--push`/`--pull` flags that wire
the Buildbarn remote cache, a `BST_CACHE_QUOTA` override, and
`#MISE depends=["generate-image-version"]`. Read the file, not this snippet, before
changing it.

### `mise/tasks/validate` and `mise/tasks/load-image`

Add `--container` and pass it through to each `./mise/tasks/bst` call:

```bash
#USAGE flag "--container" help="Use the bst2 podman container instead of native BST"
./mise/tasks/bst ${usage_container:+--container} show --deps all stacks/base-system.bst
```

### `.gitignore`

Add `.venv/` (the uv virtual environment created by `uv_venv_auto`).

## System dependencies (Fedora)

Native BST needs a working bubblewrap sandbox on the host. On Fedora these are
all in the default dnf repositories:

```
bubblewrap     # BST sandbox
lzip           # source fetching (some tarballs)
xz             # source fetching
bzip2          # source fetching
gzip           # source fetching
ostree-libs    # BST artifact checkout (ostree backend)
```

BST's Python deps (buildstream, dulwich, etc.) are provided by the venv — no
system Python packages needed.

A `mise run check-deps` task was suggested here and **never built**; the host
requirements are not listed in `README.md` or `AGENTS.md` either. Today the only
record of them is this section.

## Considerations and open questions

### BST version skew between local and upstream CI

The upstream `bst2` container (pinned by `BST2_IMAGE`) ships a specific BST
version built from source. The venv pins `buildstream>=2.5.0` in
`pyproject.toml`. These must stay compatible:

- When the upstream bst2 image upgrades BST, evaluate whether `uv.lock` needs a
  bump to match.
- Currently `click` is hard-pinned (`click==8.5.0`) because Click 8.3.0 broke a BST
  2.5.x internal API; `pyproject.toml` carries the warning. Renovate opens the PR but
  never auto-merges it. Watch for a BST release that lifts the constraint.

### `dulwich` version stability

`dulwich` is the Git implementation used by the `git_repo` source plugin
(buildstream-plugins-community). The upstream project is known to break API in
patch releases — it is pinned exactly in `pyproject.toml` (`dulwich==1.2.15` today)
and excluded from Renovate auto-merge for that reason. Test after any bump.

### FUSE access and bubblewrap

BST's build sandbox uses bubblewrap + user namespaces. On Fedora with default
settings (`/proc/sys/kernel/unprivileged_userns_clone` = 1) this works without
root. The podman container used `--privileged --device /dev/fuse`; native BST
does not need either — bubblewrap handles namespacing itself.

If bubblewrap fails with `bwrap: No permissions to creating new namespace`, the
system has restricted user namespaces. Run:
```bash
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
# or on older kernels:
sudo sysctl -w kernel.unprivileged_userns_clone=1
```
Or fall back to `mise run bst --container` (or `mise run validate --container`, etc.).

### Cache compatibility

Both the container and native BST use `~/.cache/buildstream` as the local
artifact cache. The container mapped it as
`-v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw"` so existing local
caches are immediately usable without any migration.

### `bst artifact checkout --tar -` in `load-image`

The current `mise/tasks/load-image` pipes `bst artifact checkout --tar -` into
`podman load`. This works identically with native BST — no changes needed there
beyond replacing `./mise/tasks/bst` with `bst` (or `uv run bst`).

### The `BST_FLAGS` / `BST_FLAGS_OVERRIDE` interface

The existing convention is preserved: `BST_FLAGS` appends to defaults,
`BST_FLAGS_OVERRIDE` replaces them entirely. CI workflows use
`BST_FLAGS_OVERRIDE` when they need clean flag sets (e.g. source track without
`-o x86_64_v3 true`). This interface is unchanged.

## Migration order — completed

1. ~~Add `pyproject.toml` + `uv.lock`~~ — both committed at the repo root.
2. ~~Update `mise.toml` (`[tools]`, `[settings]`, `[deps.uv]`)~~ — done, with exact
   version pins rather than `"latest"`.
3. ~~Add `.venv/` to `.gitignore`~~ — done.
4. ~~Rewrite `mise/tasks/bst` with `--container`; update `validate` and `load-image`
   to accept and pass it through~~ — done; both carry
   `#USAGE flag "--container"` and forward it as a positional arg (the forwarding is
   load-bearing, see `docs/skills/mise.md` § Propagating flags through tasks that call
   other tasks).
5. ~~Verify `mise run validate` and `mise run load-image` still work~~ — done.
