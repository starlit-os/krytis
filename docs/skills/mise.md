# mise — task runner and tool manager

Replaces `just` entirely. Every maintenance task must be a `mise run <task>` call.
**Requires mise ≥ 2026.6.10** (for `[env]` default values).

## Quick reference

```bash
mise run bst build stacks/base-system.bst             # build an element
mise run bst show --deps all stacks/bootc.bst         # show dep graph
mise run bst source track core/bootupd.bst            # track new refs
mise run validate                                      # check all key element graphs resolve
mise run generate-image-version                        # update include/image-version.yml from git
mise run load-image                                    # bst build + podman load → localhost/krytis-input:latest
mise run lint                                          # bootc container lint via Containerfile
mise run kernel-update                                 # bump linux-cachyos to latest CachyOS v3 release
```

`--` is not needed. The bst task uses `#USAGE arg "<args>" var=#true` which captures all
remaining args as positionals, so flags like `--deps` and `--tar` pass through without it.

## Standard build workflow

```
mise run generate-image-version   # stamp include/image-version.yml
mise run validate                 # confirm element graph resolves
mise run load-image               # BST build → podman local storage
mise run lint                     # bootc container lint (squash-all)
mise run generate-disk            # bootc install to-disk → bootable.raw
mise run boot-vm                  # QEMU boot (native KVM or qemux/qemu-docker)
```

- `lint` must be run after `load-image` — not automatically re-triggered.
- `generate-disk` requires `sudo` (bootc loopback install needs root).
- `boot-vm` requires `qemu-system-x86_64` + `edk2-ovmf`, or falls back to `docker.io/qemux/qemu-docker`.
- `.ovmf-vars.fd` (writable UEFI state) and `bootable.raw` are `.gitignore`d.
- `VM_RAM` and `VM_CPUS` are overrideable via `mise.toml [env]` or shell export.

## File tasks

All tasks are **file tasks** — standalone executable scripts in `mise/tasks/`. Each file becomes a `mise run <name>` command.

```
mise/tasks/
├── bst                      # mise run bst [args...]
├── validate                 # mise run validate
├── generate-image-version   # mise run generate-image-version
├── load-image               # mise run load-image
├── lint                     # mise run lint
├── generate-disk            # mise run generate-disk
├── boot-vm                  # mise run boot-vm
├── kernel-update            # mise run kernel-update
└── mise-update              # mise run mise-update
```

Subdirectory nesting uses `:` as separator: `mise/tasks/test/units` → `mise run test:units`.

### Creating a new task

1. Create `mise/tasks/<name>` with a shebang and `#MISE`/`#USAGE` metadata header.
2. `chmod +x mise/tasks/<name>`.
3. `usage lint mise/tasks/<name>` — auto-generates `--help` and catches spec errors.
4. `mise run <name> --help` to confirm.
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

Never use `mise run other-task` from inside a task script — it spawns a nested mise process.

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
BST_MEMORY_LIMIT=8g mise run bst build stacks/base-system.bst
```

In a mise-activated shell `hook-env` already injects these defaults, so overriding requires a clean environment (e.g. `env -u BST_MEMORY_LIMIT mise run bst ...`) or a parent mise config file that sets the variable first.

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
mise run bst build stacks/base-system.bst
BST_FLAGS="--config /src/buildstream-ci.conf" mise run bst build stacks/base-system.bst
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

Run locally: `mise bootstrap --yes`

In CI with `jdx/mise-action`, `mise bootstrap` requires `experimental: true` on the action step (sets `MISE_EXPERIMENTAL=1`). Add as a shell step — the `bootstrap:` action input is unreleased as of v4.2.0:

```yaml
- uses: jdx/mise-action@... # v4.2.0
  with:
    experimental: true
- run: mise bootstrap --yes
```

## `jdx/mise-action` and `mise_toml`

Without the `mise_toml:` input the action reads the project's `mise.toml` directly — this is the preferred mode. Only use `mise_toml:` when you genuinely need to override config for a specific job.

**When `mise_toml:` is set, it completely overwrites the project's `mise.toml`.** Any tools or settings in the project file are invisible to that job unless also listed in the inline block. This is why bootstrap packages belong in the project's `mise.toml` rather than being duplicated per-workflow.

## Never add loose shell scripts

All development workflows must be `mise run` tasks. No standalone scripts outside `mise/tasks/`.
