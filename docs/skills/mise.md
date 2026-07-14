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
mise chunkify                                      # rechunk into composefs-ready component layers
mise kernel-update                                 # bump linux-cachyos to latest CachyOS v3 release
mise upstream-sync                                 # sync dakota/zirconium-hawaii forks, report new commits
```

`--` is not needed. The bst task uses `#USAGE arg "<args>" var=#true` which captures all
remaining args as positionals, so flags like `--deps` and `--tar` pass through without it.

## Standard build workflow

```
mise validate                 # confirm element graph resolves
mise load-image               # BST build → podman local storage
mise lint                     # bootc container lint (squash-all)
mise generate-fakecap-manifest # regenerate files/fakecap-manifest.tsv (only when elements change)
mise chunkify                 # rechunk into composefs-ready component layers
mise generate-disk            # bootc install to-disk → bootable.raw
mise boot-vm                  # QEMU boot (native KVM or qemux/qemu-docker)
```

- `include/image-version.yml` is **gitignored** — generated at build time, never committed.
  `bst` and `validate` tasks declare `depends=["generate-image-version"]` so it's always
  regenerated automatically. `mise bootstrap` also generates it for fresh clones.
  Manual `mise generate-image-version` is only needed if you want to regenerate without building.
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

### `git push` fails with "gh: not found" after a `gh` version bump

`~/.gitconfig`'s `credential.https://github.com.helper` can hardcode an *absolute* path to
a specific mise-installed `gh` version (e.g. `.../gh/2.95.0/.../gh`). mise only keeps the
`latest` version on disk after an upgrade — the old version dir is pruned, so the
credential helper points at a binary that no longer exists, and any `git push`/`fetch`
over HTTPS fails with `gh: not found` (not an auth error, easy to misdiagnose as one).
Fix: `gh auth setup-git` regenerates the helper to point at the current `gh`. This isn't a
krytis-specific bug, but the project's `mise`-managed `gh` makes it something any
contributor pushing from this repo can hit after their next `mise` upgrade.

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
├── mise-update              # mise mise-update
└── upstream-sync            # mise upstream-sync
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

## System-wide config: `/etc/mise/conf.d/*.toml`

mise reads a system-wide config tree at `MISE_SYSTEM_CONFIG_DIR` (default `/etc/mise`), same
shape as the user tree at `~/.config/mise/`: `config.toml` plus a `conf.d/*.toml` fragment
directory loaded alphabetically. It is the **lowest**-precedence layer — project and user
config both override it — so it's safe for image-wide defaults a user can freely shadow.
Confirmed against https://mise.jdx.dev/configuration.html; no local testing needed since
the doc explicitly diagrams `/etc/mise/conf.d/*.toml` as a first-class layer.

`config/mise-aliases.bst` ships `/etc/mise/conf.d/aliases.toml` with a curated
`[tool_alias]` block (`fish`, `micro`, `tealdeer`, …) so users get short names for
aqua/github/pipx-backed tools without needing the full backend path. Closes #153.

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
| `BST_CONTAINER` | `.mise.local.toml [env]` (per-developer) | `true` defaults every `bst`/`validate`/`load-image` call to `--container` |

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

### `BST_CONTAINER` env var as a workstation-wide default

Systems without native BST host deps (`patch`, `lzip`, `bubblewrap`, etc.) need `--container` on every invocation. Rather than typing the flag every time, a developer can set it once in `.mise.local.toml` (gitignored):

```toml
[env]
BST_CONTAINER = "true"
```

Unlike `BST2_IMAGE`/`BST_MEMORY_LIMIT`, this is **not** declared in the project `mise.toml [env]` block — it's purely a per-developer override with no meaningful project-wide default (same category as `BST_FLAGS`). Each of `bst`, `validate`, and `load-image` checks it independently, after the explicit `--container` flag computation, so a literal flag always takes precedence:

```bash
CONTAINER=${usage_container:+--container}
if [ -z "$CONTAINER" ] && [ "${BST_CONTAINER:-false}" = "true" ]; then
    CONTAINER=--container
fi
```

Each task re-checks `BST_CONTAINER` rather than relying purely on env-var inheritance through the `validate`/`load-image` → `bst` call chain, so the fallback is self-documenting at every layer and doesn't depend on assumptions about which env vars mise exports to child processes.

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

**`gh auth token` lacks `write:packages` by default.** Pushing a 4 GB image only to receive a permissions error mid-transfer is expensive. Verify the scope before pushing, skipping the check only when `GITHUB_TOKEN` is already in the environment (CI path — that token is known-good):

```bash
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  SCOPES=$(gh auth status 2>&1 | grep 'Token scopes:' || true)
  if [[ "$SCOPES" != *"write:packages"* ]]; then
    echo "ERROR: gh token is missing write:packages scope." >&2
    echo "Run: gh auth refresh -s write:packages" >&2
    exit 1
  fi
fi
```

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
├── mise-update
├── gum-update
├── pangolin-update
├── niri-update
├── ghostty-update
├── symbols-nerd-font-update
└── game-devices-udev-update # Codeberg source; uses curl+jq not gh api
```

## Element update tasks

Update tasks live in `mise/tasks/<name>-update`. Each task:
1. Fetches the latest version from the upstream source
2. Downloads the new artifact, computes SHA256
3. Patches the element file in-place with `sed -i`
4. Prints a summary; exits 0 (already up-to-date) or leaves the diff for CI to detect

The CI job in `track-bst-sources.yml` calls the task, checks `git diff`, and opens/updates a PR if anything changed.

### GitHub sources (`gh api`)

Use `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'`. Requires `GH_TOKEN` in the CI environment (`env: GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`).

```bash
LATEST_TAG=$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name')
```

### Codeberg sources (`curl + jq`)

Codeberg has no `gh`-compatible CLI. Use the Gitea-compatible REST API with `curl + jq`:

```bash
API="https://codeberg.org/api/v1/repos/<owner>/<repo>/releases?limit=1"
LATEST_TAG=$(curl -sf "$API" | jq -r '.[0].tag_name')
```

No auth token needed for public repos. Do **not** add `GH_TOKEN` to the CI step env — it only applies to `gh` CLI calls. The CI job for a Codeberg element omits the `env: GH_TOKEN:` block entirely.

Tarball URL pattern: `https://codeberg.org/<owner>/<repo>/archive/<tag>.tar.gz`. Use the `codeberg_files:` alias in the element (see `docs/skills/bst.md` § udev rules elements).

### SHA extraction pattern

```bash
curl -sSfL "$URL" -o "$TMPDIR/src.tar.gz"
NEW_SHA=$(sha256sum "$TMPDIR/src.tar.gz" | awk '{print $1}')
CURRENT_SHA=$(grep 'ref:' "$ELEMENT" | awk '{print $2}')
sed -i "s|ref: ${CURRENT_SHA}|ref: ${NEW_SHA}|" "$ELEMENT"
```

Use `mktemp -d` + `trap 'rm -rf "$TMPDIR"' EXIT` for the temp directory.

## Never add loose shell scripts

All development workflows must be `mise run` tasks. No standalone scripts outside `mise/tasks/`.

## Secret retrieval via fnox (Proton Pass)

Secrets that must never enter the repo (e.g. signing keys) are retrieved with [`fnox`](https://fnox.jdx.dev) (a standalone binary by jdx/mise, separate from the `mise` CLI itself) wrapping the Proton Pass CLI (`pass-cli`).

- `fnox.toml` at the repo root maps logical secret names to `pass://`-style vault references (`{ provider = "protonpass", value = "<item>/<field>" }`). It is committed — it contains only references, never secret values.
- One-time setup on a dev machine: `pass-cli login` (browser-based). After that, `fnox get SECRET_NAME` resolves the reference and prints the value to stdout.
- Tasks that consume secrets (e.g. `mise/tasks/pull-keys`, #311) loop over the `fnox.toml` secret names, redirect `fnox get` output to the destination file, and validate the result (`openssl x509 -noout`, `openssl rsa -check`) — a fnox misconfiguration or an empty vault field fails loudly instead of writing a garbage key file.
- Retrieved secrets land in a gitignored path (e.g. `files/boot-keys/`), never committed.
- `pass-cli` has no aqua/asdf mise backend, so it's declared via `[tool_alias]` (`pass-cli = "github:protonpass/pass-cli"`) plus `[tools]` (`pass-cli = "latest"`) in the project `mise.toml` — same dev-host-tooling pattern as `just`. `mise install` then provisions it automatically; no manual download step.

`usage lint` cannot parse plain bash task files without `#USAGE` annotations (it expects a KDL spec) — this is expected and not a lint failure; it applies equally to every existing task that has no `#USAGE` block (e.g. `symbols-nerd-font-update`).

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

## Fish vendor_conf.d load order

Fish loads files in `vendor_conf.d` (and `conf.d`) **alphabetically**. Tools that depend on mise being activated must come after mise's own activation script.

The mise fish integration installs as `vendor_conf.d/mise.fish`. Any conf file that needs mise on `$PATH` must sort **after** `mise.fish` alphabetically. Use a numeric prefix to guarantee order:

```
vendor_conf.d/01-mise.fish   ← mise activation
vendor_conf.d/some-tool.fish ← loads after, mise already active
```

`elements/core/mise.bst` installs mise's fish integration to `vendor_conf.d/01-mise.fish` so any tool conf sorting after `01-` sees a fully initialised mise environment.

**Known limitation:** fish [#8553](https://github.com/fish-shell/fish-shell/issues/8553) — `vendor_conf.d` load order is not guaranteed to be stable across all fish versions. The numeric prefix is a best-effort workaround; no complete fix available until upstream resolves this.

## ISO build task (`mise run build-iso`)

`mise/tasks/build-iso` shells out to `just iso-sd-boot krytis` in the `dakota-iso` fork (`kitten-lily/dakota-iso`). It expects the fork to be cloned as a sibling of the krytis repo (`../dakota-iso`). Override with `DAKOTA_ISO_DIR=/path/to/fork mise run build-iso`.

The task passes `--justfile` and `--working-directory` so `just` runs from the dakota-iso repo root regardless of the caller's cwd. All intermediate artifacts land in `OUTPUT_DIR` (default `output/`); the final ISO is `output/krytis-live.iso`.

### Payload tag must match `dakota-iso/krytis/payload_ref` exactly

`mise build` only tags the freshly built image as `localhost/krytis:latest`. dakota-iso's `iso-sd-boot.sh` reads `krytis/payload_ref` (`ghcr.io/starlit-os/krytis:latest`) and runs `podman save` on that **exact** ref to embed the offline payload — it does not know about `localhost/krytis:latest`, so without a matching tag the save either fails outright or, worse, silently picks up a stale `ghcr.io/starlit-os/krytis:latest` left over from an earlier `mise push`/`podman pull`, embedding an old image with no error.

`build-iso` now re-tags on every run, so the ISO always embeds whatever `mise build` most recently produced:

```bash
podman tag localhost/krytis:latest "$(cat "${DAKOTA_ISO_DIR}/krytis/payload_ref")"
```

It fails fast with a clear message if `localhost/krytis:latest` doesn't exist yet — run `mise build` first.

### Tool sourcing — designed to run on Krytis itself

Krytis is immutable with no package manager, so the build runs with only the tools baked into the image (dev-tools stack) or managed by mise — **plus one container**:

| Tool | Source |
|---|---|
| `just` | mise (`mise.toml [tools]`) |
| `podman`, `skopeo` | `stacks/bootc.bst` (already in image) |
| `mksquashfs`, `mtools`, `mkfs.fat`, `rsync` | `stacks/dev-tools.bst` (fdsdk components: squashfs-tools, mtools, dosfstools, rsync) |
| `buildah`, `xorriso` | **iso-tools container** (`live/iso-tools/Containerfile` in dakota-iso) |

`buildah` and `xorriso` have **no freedesktop-sdk component**, so the `build-iso` task builds a Fedora-based `iso-tools` container and sets `ISO_TOOLS_IMAGE`. `iso-sd-boot.sh` then routes only those two steps through `podman run`:

- **Payload prep** (multi-step `buildah from→copy→commit`) runs as one `podman run` of `live/iso-tools/payload-prep.sh` — a single invocation, or the buildah working container would not survive between commands.
- **ISO assembly** passes `XORRISO`/`IMPLANTISOMD5` as `podman run …` command overrides to `build-iso.sh`; mtools/dosfstools still run on the host.

`ISO_TOOLS_IMAGE` unset (dakota/bluefin CI on a mutable, rootful host) preserves the original host-binary path. Override the image tag with `ISO_TOOLS_IMAGE=… mise run build-iso`.

### Rootless gotchas (verified building on Krytis itself)

Krytis runs **rootless** podman. Three things this breaks vs dakota's rootful CI, all handled in the fork — keep them when touching the scripts:

1. **Don't bind-mount the host containers-storage into the tools container.** Rootless storage lives under `$HOME`, not `/var/lib/containers/storage`, and the nested userns can't take the storage lock (`storage.lock: permission denied`). Instead `iso-sd-boot.sh` does `podman save --format oci-archive` of the payload on the host first, and payload-prep reads it with `buildah from oci-archive:` — transport-clean, works rootless and rootful.
2. **Force `STORAGE_DRIVER=vfs` for the payload-prep container.** The container rootfs is on overlayfs; buildah's default overlay driver can't stack on overlayfs without fuse-overlayfs (`'overlay' is not supported over overlayfs`). vfs has no such constraint (costs disk, ~2× the payload).
3. **The squashfs assembly's overlay mount falls back to `cp -a`** when rootless overlay isn't available — slower but works; no action needed.

### Variant config gotcha

`live/Containerfile` builds `FROM ghcr.io/${REGISTRY}/${TARGET}` — it prepends `ghcr.io/` itself. So `krytis/registry` is the **org only** (`starlit-os`), matching dakota's `projectbluefin`. A `ghcr.io/`-prefixed value produces the malformed `ghcr.io/ghcr.io/...` ref and the payload export fails with "image not known".

**Kernel cmdline label must match the volume label.** `build-iso.sh` once hardcoded `root=live:LABEL=DAKOTA_LIVE` in every boot entry while the volume label comes from `--label` (`KRYTIS_LIVE`, from `krytis/live_label`). The mismatch made dmsquash-live search for a non-existent label and **hang to a black screen** — no error, in QEMU/Boxes and on bare metal. The cmdlines now use `${LABEL}`; if you add a variant, set `live_label` and confirm the boot entries reference it. The krytis cmdline also carries `console=tty0` (so boot renders on a display, not just serial) and `rd.shell rd.info loglevel=7` (verbose + emergency shell on initramfs failure instead of a silent hang).

### Live env embeds the offline store as **overlay**, not vfs (fixed, #248)

`iso-sd-boot.sh`'s `_ns_build_squashfs` embeds the payload OCI image into the squashfs at `/var/lib/containers/storage` for `composefs=true` (krytis) via `skopeo copy oci-archive:… containers-storage:…` inside a `podman run --privileged` container, writing to a plain bind-mounted host directory (`CS_STAGING`, on WORKDIR's real filesystem — recommend xfs/ext4/btrfs per the `findmnt` hint earlier in the script). This step used to force `driver = "vfs"`, which made `configure-live-krytis.sh`'s `/etc/containers/storage.conf` match with its own `driver = "vfs"` — but vfs stores layers uncompressed (~2× size) and made `bootc update` on the installed system warn (see below, now historical).

**Why vfs wasn't actually required here — this was a misdiagnosis carried over from a different step.** The *actual* rootless/overlay-on-overlayfs constraint lives one step earlier, in `payload-prep.sh` (buildah's own working-container storage on the iso-tools container's overlayfs rootfs — gotcha #2 above, still true, still vfs, unrelated to this step since it only emits an oci-archive). The squashfs-embed step above never had that constraint: it's already `--privileged`, and `/vfs-storage` is a bind mount, not the container's own overlayfs — proven by the `composefs=false` sibling branch in the same function, which has always used `driver = "overlay"` successfully in this exact setup. Ported that to the `composefs=true` branch:

```toml
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage-live"

[storage.options]
additionalimagestores = ["/var/lib/containers/storage"]
```

The squashfs-root copy also switched from `cp -a` to `rsync -a --no-specials --no-devices` (same reasoning as the `composefs=false` branch: overlay whiteout char-devices need privilege the rootless `podman unshare` copy step doesn't have; harmless to drop since `payload-prep.sh` squashes to a single layer first, so there's nothing for a whiteout to mark deleted). Verified end-to-end with `mise run build-iso`: log shows `Importing OCI image into squashfs overlay containers-storage...` and the build completes.

**The `graphroot` override is still not optional, regardless of driver — it avoids a self-reference lock trap.** fisherman installs via `pkexec` (**rootful**), whose *default* graphroot is exactly `/var/lib/containers/storage` — the same path as the embedded payload. containers/storage caches lockfiles by absolute path (`pkg/lockfile` `getLockfile`): the primary store opens its `layers.lock` **read-write**, then the additional store requests the **same** path **read-only** → cache hit on a read-write lock → fatal:

```
loading additional layer stores: lock /var/lib/containers/storage/vfs-layers/layers.lock is not a read-only lock
```

Pointing `graphroot` at a separate empty dir (`…/storage-live`) means the payload is only ever the read-only additional store, never the primary — the paths differ, so no cache collision. This also covers rootless (`liveuser`), where podman forces graphroot to `~/.local/share/containers/storage`; the payload is reachable only as an additional read-only store there too, and the distinct rootful graphroot keeps the pkexec path from colliding with it. See containers/podman#9852 for the original report of this failure mode.

**Not yet verified: a real `bootc install`/fisherman run against the overlay-embedded store**, confirming no `bootc update` "graph driver overwritten" warning end to end. The build produces the ISO correctly, but this host has no `qemu`/OVMF (see Status below) — boot/install-flow testing needs an external VM or the `run-iso`/`boot-iso-serial` just recipes in dakota-iso.

<details>
<summary>Historical: the vfs-era <code>bootc update</code> warning (before #248)</summary>

Before the fix above, `bootc update` on the installed system printed:

```
User-selected graph driver "overlay" overwritten by graph driver "vfs" from database
```

This was expected and non-fatal under the vfs embed — the update still succeeded and staged the image. It was inherent to *any* live-ISO composefs install using vfs, not krytis-specific: fisherman's `selectStorageDriver` (`tuna-os/fisherman` → moved to `projectbluefin/fisherman`, `internal/install/storage_driver.go`) rejects `overlayfs`/`tmpfs` scratch and falls back to vfs, and a live environment's scratch dir is always overlayfs/tmpfs — so bootc recorded vfs in the installed system's containers-storage database and containers/storage honoured that over the configured overlay. The overlay embed fix above removes the reason this ever needed to be vfs in the first place.
</details>

### Status

`mise run build-iso --debug` produces `output/krytis-live.iso` (~4 GB, volume label `KRYTIS_LIVE`, protective MBR + GPT) on rootless Krytis. **Boot test still pending** — Krytis ships no `qemu`; boot via dakota-iso's `run-iso` recipe (`ghcr.io/qemus/qemu` container) or external hardware/VM.

For a one-off build on a **mutable** dev host instead, install the tools directly (e.g. CachyOS: `sudo pacman -S --needed just mtools xorriso squashfs-tools isomd5sum buildah`) and `export ISO_TOOLS_IMAGE=` to opt out of the container path.
