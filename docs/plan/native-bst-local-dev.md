# Plan: Native BST for Local Dev

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

`mise run bst` (and the tasks that call it) should call `uv run bst` instead.
The `pyproject.toml` + `uv.lock` added for CI (see the CI plan) supply the BST
Python package. The podman wrapper is preserved as `mise run bst-container` for
edge cases.

## Changes required

### `mise.toml`

Add to `[tools]`:
```toml
python = "3.12"
uv = "latest"
```

Add to `[settings]`:
```toml
python.uv_venv_auto = "create|source"
```

Add `[deps.uv]`:
```toml
[deps.uv]
auto = true
sources = ["pyproject.toml", "uv.lock"]
outputs = [".venv/"]
run = "uv sync"
```

The `BST2_IMAGE` env var stays for `bst-container`; it is no longer referenced by
the primary `bst` task.

### `mise/tasks/bst`

Replace the podman invocation with:

```bash
#!/usr/bin/env bash
#MISE description="Run any bst command with native BST (uv venv)"
#USAGE arg "<args>" var=true help="bst subcommand and arguments"

set -euo pipefail
DEFAULT_FLAGS="-o x86_64_v3 true --no-interactive"
FLAGS="${BST_FLAGS_OVERRIDE:-${DEFAULT_FLAGS} ${BST_FLAGS:-}}"
# shellcheck disable=SC2086
exec uv run bst --colors ${FLAGS} "$@"
```

### `mise/tasks/bst-container` (new)

Preserve the existing podman wrapper verbatim, renamed. Useful on systems with
restricted user namespaces (non-Fedora corporate laptops, restricted WSL).

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

Consider adding a `mise run check-deps` or documenting these in `README.md` or
`AGENTS.md`.

## Considerations and open questions

### BST version skew between local and upstream CI

The upstream `bst2` container (pinned by `BST2_IMAGE`) ships a specific BST
version built from source. The venv pins `buildstream>=2.5.0` in
`pyproject.toml`. These must stay compatible:

- When the upstream bst2 image upgrades BST, evaluate whether `uv.lock` needs a
  bump to match.
- Currently `click==8.2.1` is required due to a BST 2.5.x API break in Click
  8.3.0 (see zirconium-hawaii's comment in `utils/requirements.txt`). Watch for a
  new BST release that lifts this constraint and update `pyproject.toml` when it
  does.

### `dulwich` version stability

`dulwich` is the Git implementation used by the `git_repo` source plugin
(buildstream-plugins-community). The upstream project is known to break API in
patch releases — pin a specific version in `pyproject.toml` (e.g.
`dulwich==0.24.0`) and test after any bump.

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
Or fall back to `mise run bst-container`.

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

## Migration order

1. Add `pyproject.toml` + `uv.lock` (required by CI plan — likely done first)
2. Update `mise.toml` (`[tools]`, `[settings]`, `[deps.uv]`)
3. Add `.venv/` to `.gitignore`
4. Rename `mise/tasks/bst` → `mise/tasks/bst-container`; write new `mise/tasks/bst`
5. Verify `mise run validate` and `mise run load-image` still work
6. Document Fedora system deps in `README.md` or `AGENTS.md`
