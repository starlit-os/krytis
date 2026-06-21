# mise — task runner and tool manager

Replaces `just` entirely. Every maintenance task must be a `mise <task>` call.
**Requires mise ≥ 2026.6.10** (for `[env]` default values).

## Quick reference

```bash
mise bst build stacks/base-system.bst             # build an element
mise bst show --deps all stacks/bootc.bst         # show dep graph
mise bst source track core/bootupd.bst            # track new refs
mise validate                                      # check all key element graphs resolve
mise generate-image-version                        # update include/image-version.yml from git
mise load-image                                    # bst build + podman load → localhost/krytis-input:latest
mise lint                                          # bootc container lint via Containerfile
mise kernel-update                                 # bump linux-cachyos to latest CachyOS v3 release
```

`--` is not needed. The bst task uses `#USAGE arg "<args>" var=#true` which captures all
remaining args as positionals, so flags like `--deps` and `--tar` pass through without it.

## Standard build workflow

```
mise generate-image-version   # stamp include/image-version.yml
mise validate                 # confirm element graph resolves
mise load-image               # BST build → podman local storage
mise lint                     # bootc container lint (squash-all)
mise generate-disk            # bootc install to-disk → bootable.raw
mise boot-vm                  # QEMU boot (native KVM or qemux/qemu-docker)
```

- `lint` must be run after `load-image` — not automatically re-triggered.
- `generate-disk` requires `sudo` (bootc loopback install needs root).
- `boot-vm` requires `qemu-system-x86_64` + `edk2-ovmf`, or falls back to `docker.io/qemux/qemu-docker`.
- `.ovmf-vars.fd` (writable UEFI state) and `bootable.raw` are `.gitignore`d.
- `VM_RAM` and `VM_CPUS` are overrideable via `mise.toml [env]` or shell export.

### `console=` karg ordering matters for interactive services

With multiple `console=` kernel arguments, all consoles receive output, but `/dev/console` (used for interactive input by services like `systemd-firstboot`) maps to the **last** one listed. To keep serial output for native QEMU debugging while making firstboot interactive on VGA/noVNC, put `console=ttyS0` first and `console=tty1` last:

```
--karg console=ttyS0 --karg console=tty1
```

Reversing the order (tty1 first, ttyS0 last) breaks interactive firstboot on the VGA display.

## File tasks

All tasks are **file tasks** — standalone executable scripts in `mise/tasks/`. Each file becomes a `mise <name>` command.

```
mise/tasks/
├── bst                      # mise bst [args...]
├── validate                 # mise validate
├── generate-image-version   # mise generate-image-version
├── load-image               # mise load-image
├── lint                     # mise lint
├── generate-disk            # mise generate-disk
├── boot-vm                  # mise boot-vm
├── kernel-update            # mise kernel-update
└── mise-update              # mise mise-update
```

Subdirectory nesting uses `:` as separator: `mise/tasks/test/units` → `mise test:units`.

### Creating a new task

1. Create `mise/tasks/<name>` with a shebang and `#MISE`/`#USAGE` metadata header.
2. `chmod +x mise/tasks/<name>`.
3. `usage lint mise/tasks/<name>` — auto-generates `--help` and catches spec errors.
4. `mise <name> --help` to confirm.
5. Update this skill if the pattern is non-obvious.

Template:
```bash
#!/usr/bin/env bash
#MISE description="What this task does"
#MISE depends=["other-task"]             # optional prerequisite tasks
#USAGE arg "<name>" help="Required positional"
#USAGE arg "[name]" help="Optional positional"
#USAGE arg "<files>" var=#true help="Variadic (zero or more)"
#USAGE flag "--dry-run" help="Boolean flag"
#USAGE flag "--region <region>" default="us-east-1" help="Value flag"

set -euo pipefail
# Parsed values: $usage_<name> (hyphens → underscores); raw args still in $@
DRY_RUN="${usage_dry_run:-false}"
```

### Calling other tasks

Use `#MISE depends=["other-task"]` to declare a prerequisite task (no args). mise runs it
before the script body.

Call `./mise/tasks/<name>` directly when a script needs to invoke another task inline —
as part of a pipeline, multiple times with different args, or alongside other work.
The env vars from `mise.toml` are already injected when running as a mise task.

```bash
# Prerequisite with no args — use depends
#MISE depends=["generate-image-version"]

# Multiple calls or pipeline — use direct script call
./mise/tasks/bst show --deps all stacks/base-system.bst
./mise/tasks/bst artifact checkout --tar - oci/krytis/image.bst | podman load
```

Never use `mise other-task` from inside a task script — it spawns a nested mise process.

### Supported `#MISE` metadata fields

| Field | Example |
|---|---|
| `description` | `"Build the OCI image"` |
| `alias` | `"b"` |
| `depends` | `["lint", "test"]` |
| `sources` | `["Cargo.toml", "src/**/*.rs"]` |
| `outputs` | `["target/debug/bin"]` |
| `env` | `{RUST_BACKTRACE = "1"}` |
| `dir` | `"{{cwd}}"` (default is `{{config_root}}`) |

## Working directory

Tasks run from `{{config_root}}` (the directory containing `mise.toml`) by default.
Use **relative paths** in task scripts — no need for `$MISE_PROJECT_ROOT`.

```bash
# Good — relative path, works because dir defaults to config_root
cat > include/image-version.yml <<EOF ...

# Avoid — $MISE_PROJECT_ROOT is not documented as stable
cat > "${MISE_PROJECT_ROOT}/include/image-version.yml" <<EOF ...
```

## Tool declarations

Tools managed by mise go in `mise.toml`. `usage` is always present to power `#USAGE` annotations and shell completions:

```toml
[tools]
usage = "latest"
```

Run `mise install` to install declared tools. System tools (podman, git, qemu) are **not** managed here.

## User-overrideable environment defaults

Use `[env]` with `{ default = "..." }` in `mise.toml`. Mise applies the fallback only when the variable is **unset or empty** in the calling environment; existing non-empty values are preserved.

```toml
[env]
BST2_IMAGE = { default = "registry.gitlab.com/.../bst2:pinned-sha" }
BST_MEMORY_LIMIT = { default = "16g" }
```

Override from the shell before calling mise:
```bash
BST_MEMORY_LIMIT=8g mise bst build stacks/base-system.bst
```

In a mise-activated shell `hook-env` already injects these defaults, so overriding requires a clean environment (e.g. `env -u BST_MEMORY_LIMIT mise bst ...`) or a parent mise config file that sets the variable first.

Truly optional flags with no meaningful default (e.g. `BST_FLAGS`, `BST_FLAGS_OVERRIDE`) stay as shell expansion in the script: `${BST_FLAGS:-}`.

## The `bst` task

Wraps the pinned `bst2` container image. Override points:

| Variable | Source | Effect |
|---|---|---|
| `BST2_IMAGE` | `mise.toml [env]` default | The bst2 container image |
| `BST_MEMORY_LIMIT` | `mise.toml [env]` default | Container memory cap |
| `BST_FLAGS` | Shell only | Appended to default flags |
| `BST_FLAGS_OVERRIDE` | Shell only | Replaces all flags |

Default flags applied: `-o x86_64_v3 true --no-interactive`

```bash
mise bst build stacks/base-system.bst
BST_FLAGS="--config /src/buildstream-ci.conf" mise bst build stacks/base-system.bst
```

## Bootstrap packages (`mise bootstrap`)

System packages required for builds and source tracking live in `[bootstrap.packages]` in `mise.toml`. This makes them available for both local dev setup and CI:

```toml
[bootstrap.packages]
"apt:bubblewrap" = "latest"
"apt:lzip" = "latest"
"apt:xz-utils" = "latest"
"apt:bzip2" = "latest"
"apt:gzip" = "latest"
"apt:patch" = "latest"
```

Run locally:

```bash
mise settings experimental=true   # required once before first invocation
mise bootstrap                     # installs packages and tools, then runs the bootstrap task
```

**How the bootstrap task fits in:** `mise bootstrap` (the built-in) runs `[bootstrap.packages]` → installs tools → then calls the `bootstrap` task as a post-hook. The task's only job is to set `experimental=true` for subsequent mise invocations. **Never call `mise bootstrap` from inside the `bootstrap` task** — the built-in calls the task, so calling the built-in from the task creates infinite recursion (issue #87).

### Package manager support

`[bootstrap.packages]` supports both `apt:` (Debian/Ubuntu) and `dnf:` (Fedora) prefixes — mise selects the right one for the current system. Note that Fedora package names differ from apt: `apt:xz-utils` → `dnf:xz`.

On image-based systems (running Krytis), these packages are baked into `stacks/dev-tools.bst` so `mise run bootstrap` is not needed — use `mise bst --container` if the native sandbox still fails.

In CI with `jdx/mise-action`, **any job that calls `mise run` (or `mise bootstrap`) needs `experimental: true`** when the project `mise.toml` uses any experimental feature — including `[bootstrap.packages]` *and* `[deps.uv] auto = true`. Omitting it causes:

```
mise ERROR  deps is experimental. Enable it with `mise settings experimental=true`
```

Add to every job that invokes mise tasks:

```yaml
- uses: jdx/mise-action@... # v4.2.0
  with:
    experimental: true
- run: mise bootstrap --yes
```

## `jdx/mise-action` and `mise_toml`

Without the `mise_toml:` input the action reads the project's `mise.toml` directly — this is the preferred mode. Only use `mise_toml:` when you genuinely need to override config for a specific job.

**When `mise_toml:` is set, it completely overwrites the project's `mise.toml`.** Any tools or settings in the project file are invisible to that job unless also listed in the inline block. This is why bootstrap packages belong in the project's `mise.toml` rather than being duplicated per-workflow.

## Propagating flags through tasks that call other tasks

When a task (e.g. `validate`) calls another task script directly (`./mise/tasks/bst`), mise does not parse the child's `#USAGE` annotations — it just runs the script. Flags must be forwarded explicitly as positional args.

**Pattern — caller:**
```bash
#USAGE flag "--container" help="Use the bst2 podman container instead of native BST"
CONTAINER=${usage_container:+--container}
./mise/tasks/bst ${CONTAINER:-} show --deps all stacks/base-system.bst
```

**Pattern — callee (`mise/tasks/bst`):**
```bash
#USAGE flag "--container" help="..."
CONTAINER="${usage_container:-false}"
# Consume --container if passed as a literal first arg from a parent task.
# Do NOT guard on "$CONTAINER" != "true" — see the env-inheritance note below.
if [ "${1:-}" = "--container" ]; then
    CONTAINER=true
    shift
fi
```

The unquoted `${CONTAINER:-}` in the caller expands to nothing when empty, so no spurious empty-string arg is passed.

## `usage_container` is inherited by child processes

When mise runs a task it sets `usage_*` env vars for that task's parsed flags. These vars are **inherited by every child process** the task spawns — including direct script invocations like `./mise/tasks/bst`.

This means when `validate --container` calls `./mise/tasks/bst --container show ...`, the bst script sees **both** `usage_container=true` (inherited) **and** `--container` as `$1`. If the shift is guarded by `[ "$CONTAINER" != "true" ]`, the guard fires false and the shift is skipped — `--container` stays in `$@` and is passed through to BST, which rejects it with "No such option".

**Fix:** always shift unconditionally when `$1 = "--container"`. Mise already strips the flag from `$@` for the direct-call case (`mise bst --container`), so a double-shift cannot happen.

## New worktrees require `mise trust`

`mise` treats each new worktree directory as untrusted. Any `mise run` command fails immediately with:

```
mise ERROR Config files in .../mise.toml are not trusted. Trust them with `mise trust`.
```

**Fix:** run `mise trust` once in the worktree root before any `mise run` invocation.

## Pushing the image to ghcr.io

`mise push` tags `localhost/krytis:latest` (produced by `mise lint`) to `ghcr.io/starlit-os/krytis:<version>` and `:latest`, then pushes both. Run `mise build` first.

```bash
mise push                                       # push to default registry
mise push --registry ghcr.io/my-fork/krytis    # override target
```

### GitHub token auth for podman login

`GITHUB_TOKEN` is the canonical source — mise injects it automatically via `hook-env` when OAuth is configured (see [mise.jdx.dev/dev-tools/github-tokens.html](https://mise.jdx.dev/dev-tools/github-tokens.html)), and CI (GitHub Actions) also sets it. Fall back to `gh auth token` for local dev where mise OAuth is not configured:

```bash
TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "token")
echo "$TOKEN" | podman login ghcr.io --username "$GH_USER" --password-stdin
```

The `|| echo "token"` fallback matters in CI where `gh` may not be authenticated — ghcr.io accepts any non-empty username alongside a valid PAT/GITHUB_TOKEN.

### File task list (updated)

```
mise/tasks/
├── bst
├── validate
├── generate-image-version
├── load-image
├── lint
├── push                     # tag + push to ghcr.io/starlit-os/krytis
├── generate-disk
├── boot-vm
├── kernel-update
└── mise-update
```

## Never add loose shell scripts

All development workflows must be `mise run` tasks. No standalone scripts outside `mise/tasks/`.

## BST CAS quota

BST's local CAS has an internal storage quota separate from OS disk space. Hitting it produces:

```
OutOfSpaceException: Insufficient storage quota
```

The `mise bst` task (both container and native paths) sets a default quota of 50G via `BST_CACHE_QUOTA`. This matches CI. Override per-run with:

```bash
BST_CACHE_QUOTA=60G mise load-image --container
```

For the container path, the quota is written to `/root/.config/buildstream/user.conf` inside the container on each run. For the native path, it is appended to `~/.config/buildstream/user.conf` once (idempotent — skipped if `quota:` already present).

A full fdsdk bootstrap from a cold cache needs ~50G. If the disk itself is low (check `df -h ~/.cache/buildstream`), run `podman system prune --all --force` first — old krytis build images accumulate quickly and can consume hundreds of GB.
