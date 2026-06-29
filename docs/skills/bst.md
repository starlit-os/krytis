# BuildStream Reference

Load when writing, editing, or reviewing `.bst` element files, debugging a build failure, or understanding how the OCI image is assembled.

## Running BST: Native vs Container

BST requires host system packages (`patch`, `lzip`, `bubblewrap`, `bzip2`, `xz`, `gzip`). Run natively where these are available — it's faster. On machines where they can't be installed (immutable/image-based systems, locked-down environments), use the `--container` flag:

```shell
mise validate --container
mise bst --container build elements/stacks/desktop.bst
mise load-image --container
```

The podman container fallback has no host dep requirements beyond podman itself. Without `--container` on a machine that lacks the native deps, BST fails immediately on element graph resolution with "Did not find 'patch' in PATH".

## Quick Reference

| Goal | Command |
|------|---------|
| Validate full element graph (no build) | `mise validate [--container]` |
| Inspect element deps | `mise bst [--container] show elements/krytis/<name>.bst` |
| Build one element | `mise bst [--container] build elements/krytis/<name>.bst` |
| Enter build sandbox | `mise bst [--container] shell --build elements/krytis/<name>.bst` |
| Track a git/tarball ref | `mise bst [--container] source track elements/krytis/<name>.bst` |
| List built element contents | `mise bst [--container] artifact list-contents elements/krytis/<name>.bst` |
| View build log | `mise bst [--container] artifact log elements/krytis/<name>.bst` |
| Delete cached build | `mise bst [--container] artifact delete elements/krytis/<name>.bst` |
| Full image build | `mise build` |

## Variables

| Variable | Expands to | Notes |
|----------|-----------|-------|
| `%{install-root}` | Staging directory | Always prefix install paths with this |
| `%{prefix}` | `/usr` | |
| `%{bindir}` | `/usr/bin` | |
| `%{libdir}` | `/usr/lib/x86_64-linux-gnu` | **Multiarch path** — not `/usr/lib`. Use for `.so` files and PAM modules |
| `%{indep-libdir}` | `/usr/lib` | Use for systemd units, presets, sysusers, tmpfiles |
| `%{datadir}` | `/usr/share` | |
| `%{sysconfdir}` | `/etc` | Avoid — prefer `/usr/lib` paths for image content |
| `%{install-extra}` | Empty hook | Convention: always end install-commands with this |
| `%{go-arch}` | `amd64`/`arm64` | Defined in project.conf per-arch |
| `%{arch}` | `x86_64`/`aarch64` | Raw architecture name |

## Element Kinds

| Kind | Use case |
|------|----------|
| `manual` | Custom build/install, config-only elements, pre-built binaries |
| `meson` | C/C++ projects with Meson build system |
| `make` | Makefile projects, Rust (with cargo2 sources) |
| `autotools` | Legacy C projects |
| `cmake` | CMake projects |
| `import` | Direct file placement, no build step |
| `stack` | Dependency aggregation — **produces zero filesystem output** |
| `compose` | Layer filtering (exclude debug/devel splits) |
| `script` | OCI image assembly |
| `collect_initial_scripts` | Collect systemd presets/sysusers/tmpfiles from the dep tree |

**Never type a layer element as `kind: stack`.** A stack builds successfully but the OCI layer is silently empty. Verify with `grep '^kind:' elements/oci/krytis/filesystem.bst` — must show `kind: compose`.

## Source Kinds

| Kind | Use case |
|------|---------|
| `git_repo` | Most elements |
| `tar` | Release tarballs. Use `base-dir: ""` if tarball has no wrapping dir. |
| `remote` | Single file download (not extracted). Use `directory:` to place it. |
| `local` | Files from the repo's `files/` directory |
| `cargo2` | Rust crate vendoring — always generated, never hand-written |
| `go_module` | Go module deps |
| `patch_queue` | Apply a patches directory. **Only add to an element when patches exist** — omit it when the directory would be empty. `git apply` is run on every file in the directory so any non-patch file (e.g. `.gitkeep`) causes a fatal error. |

## Command Hooks

| Syntax | Meaning |
|--------|---------|
| `(>):` | Append to the element kind's inherited command list |
| `(<):` | Prepend to the inherited command list |
| `(@):` | Include a YAML file |
| `(?):` | Conditional block (evaluates options like `arch`) |

Always end `install-commands` with `- "%{install-extra}"`.

## System-wide mise tasks via BST element

**File-task directory scanning only applies to project configs.** Mise does NOT scan `/etc/mise/tasks/` automatically even if `/etc/mise/config.toml` exists. Tasks must be declared explicitly in `/etc/mise/config.toml` using `[tasks.*]` TOML blocks pointing to the script files. Ship both: the scripts (for execution) and `config.toml` (for discovery).

Use quoted keys for namespace separators: `[tasks."fido2:enroll"]`.

Pattern (`elements/config/fido2-tasks.bst` + `files/fido2-tasks/config.toml`):

**BST element:**
```yaml
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- core/mise.bst  # runtime dep — mise must be on the image

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    for script in enroll enroll-luks status test-sudo; do
      install -Dm755 "fido2/${script}" \
        "%{install-root}%{sysconfdir}/mise/tasks/fido2/${script}"
    done
    install -Dm644 config.toml \
      "%{install-root}%{sysconfdir}/mise/config.toml"
  - '%{install-extra}'

sources:
- kind: local
  path: files/fido2-tasks
```

**`files/fido2-tasks/config.toml`:**
```toml
# Tasks must be declared here — file-task scanning only applies to project configs.

[tasks."fido2:enroll"]
run = "/etc/mise/tasks/fido2/enroll"
description = "Enroll a FIDO2 security key for sudo / login"
```

Key points:
- `depends: core/mise.bst` — scripts are useless without mise; declaring the dep makes it explicit
- Scripts must be executable (755) and have a `#MISE description="…"` header so `mise tasks` lists them
- The `local` source path must be relative to the project root (`files/my-tasks/`, not absolute)
- Use this pattern for user-facing ops tasks shipped in the OCI image (enrollment, diagnostics, etc.)

## Prebuilt Binary Elements — Sandbox Tool Availability

`runtime-minimal.bst` provides a shell and `install`, but **not** `find`, `grep`, `sed`, or other GNU coreutils/findutils. Prebuilt binary elements that use these tools in `install-commands` will fail with `command not found` (exitcode 127).

Fix: use direct paths. BST's `kind: tar` source **strips the single top-level directory by default** (same as `tar --strip-components=1`). Files from `name_ver_arch/{binary,completions/}` land directly at the staging root. So `binary` is at `./binary`, not `./name_ver_arch/binary`.

```yaml
install-commands:
- install -Dm755 binary "%{install-root}%{bindir}/binary"
- install -Dm644 completions/tool.bash "%{install-root}%{sysconfdir}/bash_completion.d/tool"
- install -Dm644 completions/tool.fish "%{install-root}%{datadir}/fish/vendor_completions.d/tool.fish"
- install -Dm644 completions/tool.zsh  "%{install-root}%{datadir}/zsh/vendor-completions/_tool"
- "%{install-extra}"
```

Arch-neutrality: handle via `(?)` source conditionals at the source level — the install commands don't need to vary by arch once the single top-level dir is stripped.

Exception: `base-dir: ""` opts out of the strip (files extract as-is with their original directory structure). See `symbols-nerd-font.bst` for an example where the tarball already has files at root level.

Do **not** add `findutils` as a workaround — it would pull unnecessary build-time deps into a minimal element.

### gum (charmbracelet) — known-working install pattern

gum releases multi-file tarballs (`gum_VER_Linux_ARCH.tar.gz`) that contain the binary, completions, man pages, and a licence. Arch-conditional source block + direct install paths:

```yaml
kind: manual
build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
variables:
  strip-binaries: ''
sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:charmbracelet/gum/releases/download/vVER/gum_VER_Linux_x86_64.tar.gz
      ref: <sha256>
  - arch == "aarch64":
      url: github_files:charmbracelet/gum/releases/download/vVER/gum_VER_Linux_arm64.tar.gz
      ref: <sha256>
config:
  strip-commands:
  - ':'
  install-commands:
  - install -Dm755 gum "%{install-root}%{bindir}/gum"
  - install -Dm644 completions/gum.bash "%{install-root}%{sysconfdir}/bash_completion.d/gum"
  - install -Dm644 completions/gum.fish "%{install-root}%{datadir}/fish/vendor_completions.d/gum.fish"
  - install -Dm644 completions/gum.zsh  "%{install-root}%{datadir}/zsh/vendor-completions/_gum"
  - "%{install-extra}"
```

`strip-binaries: ''` suppresses BST's default strip pass — gum is a pre-compiled Go binary, stripping it produces an unusable binary.

**`gum style` with flag-like arguments:** when the text argument starts with `-`, gum parses it as its own flag and errors. Use `--` to terminate flag parsing:

```bash
# ❌ fails when VAR expands to e.g. "-N"
gum style --foreground 212 "${VAR}"

# ✅
gum style --foreground 212 -- "${VAR}"
```

**`gum choose` margin flags** are per-item-type (`--header.margin`, `--item.margin`, `--cursor.margin`), not a single `--margin`. All three must be set to get consistent padding.

## Config-only Elements

Elements that only drop config files (no binaries to build) should use `kind: manual` and suppress the default strip step:

```yaml
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

config:
  strip-commands:
  - ":"
  install-commands:
  - install -Dm644 /dev/stdin "%{install-root}%{sysconfdir}/example/config.toml" <<'EOF'
    ...
    EOF
  - "%{install-extra}"
```

The `strip-commands: [":"]` is required — the default strip invokes `freedesktop-sdk-stripper` which is not present in `runtime-minimal`.

## PAM file routing in fdsdk

When overriding PAM config files, verify which file each service actually reads — not all services use the same include target:

| Service | PAM file used | Source |
|---------|--------------|--------|
| `sudo` | `/etc/pam.d/system-auth` | fdsdk `sudo.bst`: `auth include system-auth` |
| `sshd` | `/etc/pam.d/password-auth` | fdsdk `linux-pam.bst` default |
| `greetd` | `/etc/pam.d/greetd` | `config/greetd-config.bst` (self-contained) |

**`image.bst` strips factory copies, not runtime files.** It removes `/usr/share/factory/etc/pam.d/{other,system-auth}` — the deploy-time `/etc/pam.d/system-auth` is unaffected and present at runtime. Overriding it via an element with `overlap-whitelist` works.

To add a PAM module to sudo: override `system-auth`, not `password-auth`.
To add a PAM module to greetd: edit `config/greetd-config.bst` directly and add `core/pam-u2f.bst` (or the relevant module) to its `depends:`.

### pam_u2f pinverification: enrollment and PAM config must match

`pinverification` in the PAM config line (`pam_u2f.so cue pinverification`) only works if the credential was enrolled with the correct pamu2fcfg flags. The PAM config and enrollment flags are coupled:

| pamu2fcfg flag | Meaning | Credential flag in u2f_keys |
|---|---|---|
| `-N` / `--pin-verification` | Require PIN (CTAP2 clientPin) | `+pinverification` |
| `-V` / `--user-verification` | Require built-in UV (biometric) | `+userverification` |
| `-P` / `--no-user-presence` | **Allow without touch** — opposite of what you want |

**`-P` is a trap**: it means `--no-user-presence`, not pin. Using `-P` silently creates a weaker credential (no touch required) and the PIN prompt never appears.

Detect which flags to use from `fido2-token -I <device>`:
- `clientPin` in the `options:` line → use `-N`
- `uv retries:` is not `undefined` → device has biometric UV → also use `-V`

YubiKey 5 uses clientPin (PIN entered on host, not on device) → `-N` only. `-V` fails with "does not support built-in user verification" on these keys.

**`fido2-token -L` output has a trailing `:` on device paths** (e.g. `/dev/hidraw3:`). Strip it before passing to `-I`:

```bash
DEVICE=$(fido2-token -L | head -1 | tr -d ':')
fido2-token -I "$DEVICE"
```

Passing the raw `-L` output to `-I` fails silently — `$INFO` is empty, capability detection returns wrong results.

**`fido2-token -I` options format**: capabilities are on one line as a comma-separated list, not as individual `key: true` entries:

```
options: rk, up, noplat, noalwaysUv, credMgmt, authnrCfg, clientPin, largeBlobs
uv retries: undefined
```

Parse with:
```bash
INFO=$(fido2-token -I "$DEVICE" 2>/dev/null)
OPTIONS=$(echo "$INFO" | grep "^options:")
echo "$OPTIONS" | grep -qw "clientPin" && ENROLL_FLAGS+=(-N)
UV_RETRIES=$(echo "$INFO" | grep "^uv retries:" | awk '{print $NF}')
[[ "$UV_RETRIES" != "undefined" ]] && ENROLL_FLAGS+=(-V)
```

The `fido2:enroll` script detects capabilities automatically. If PAM config uses `pinverification`, enrollment must use `-N`. Users must re-enroll after changing flags; old credentials with empty flags won't prompt for PIN.

## OCI Assembly Pipeline

Krytis image assembly flows through three element kinds:

```
elements/krytis/deps.bst              kind: stack  (dep aggregator — zero filesystem output)
  └── lists all krytis/*.bst elements

elements/oci/krytis/filesystem.bst    kind: compose  (filters deps into /layer filesystem)
  └── depends on: deps.bst + freedesktop-sdk runtime

elements/oci/krytis/image.bst         kind: script  (final OCI image)
  └── runs: prepare-image.sh, systemd-sysusers, build-oci
```

### OCI script assembly order (strict)

The `image.bst` script must run steps in this order:

1. `prepare-image.sh` — sets up ostree-compatible filesystem layout, handles `/etc` → `/usr/etc` merging
2. `systemd-sysusers --root /layer` — create system users from sysusers.d
3. `glib-compile-schemas` (if any GLib schemas are installed)
4. `build-oci` — assemble the OCI image

Running `build-oci` before `systemd-sysusers` means the greeter user (`greeter`) won't exist in the image.

## Compose Element Structure

```yaml
kind: compose

build-depends:
  - oci/krytis/manifest.bst
  - oci/krytis/runtime.bst
  - freedesktop-sdk.bst:components/gcc.bst

config:
  exclude:
    - debug
    - extra
    - static-blocklist
```

The `exclude:` list strips developer splits. `gcc.bst` provides devel files the compose needs and is a `build-depends` (not `depends`) since it's not shipped in the runtime image.

## BST Weak-Key Caching Bug

**Symptom:** You added a package to `deps.bst`, the build succeeded, but the package is missing from the final image.

**Cause:** BST's non-strict mode computes weak keys for `kind: stack` elements from direct dependency names only — not their content. Adding an element to `deps.bst` doesn't change the stack's weak key, so the downstream compose is considered a cache hit and not rebuilt.

**Fix:**
```bash
mise run bst build --no-cache-buildtrees oci/krytis/image.bst
```

**When to expect this:** Any time a package is added to `deps.bst` and the build is run in default (non-strict) mode.

## Artifact Checkouts: Always Use `/tmp`

Large artifact checkouts expand to gigabytes and tens of thousands of files. Never place them under the repo directory:

```bash
# ❌ pollutes git status, bloats the agent's file index
mise run bst artifact checkout elements/krytis/something.bst --directory .build-out

# ✅ always use /tmp
OUTDIR=$(mktemp -d /tmp/krytis-checkout-XXXXXX)
mise run bst artifact checkout elements/krytis/something.bst --directory "$OUTDIR"
rm -rf "$OUTDIR"   # clean up when done
```

## Adding a Package

1. Create `elements/krytis/<name>.bst` (copy a similar existing element)
2. Add `krytis/<name>.bst` to `depends:` in `elements/krytis/deps.bst`
3. Add a URL alias to `include/aliases.yml` if the download domain is new
4. Run `mise validate` (validates the full element graph)
5. Run `mise bst build elements/krytis/<name>.bst`
6. Run `mise build` for a full image build
7. **Wire up an update path** — see § Element update path below

### Adding a gnome-build-meta junction element

If the package already exists in `gnome-build-meta.bst`, no new `.bst` file is needed — reference it directly in the stack:

```yaml
- gnome-build-meta.bst:core/nautilus.bst
```

**Update path is already covered** by the `track-core-junctions` CI job, which tracks both `gnome-build-meta.bst` and `freedesktop-sdk.bst` atomically. No separate mise task or CI job needed.

**Namespace layout in gnome-build-meta:**
- `core/` — end-user GNOME apps (nautilus, gnome-text-editor, etc.)
- `core-deps/` — libraries and runtime deps (xdg-desktop-portal-gtk, libportal, etc.)
- `sdk/` — developer/toolchain elements (xwayland-satellite, blueprint-compiler, etc.)
- `gnomeos-deps/` — OS-level config (flathub-config, etc.)

Check presence: `find .bst/staged-junctions/gnome-build-meta.bst/ -name "<name>.bst"`

## Element Update Path

Every element must have a defined update path. **`bst source track` is a no-op on `kind: tar` and `kind: remote` sources** — these source kinds don't have a tracking ref BST can follow. Without an explicit update path the element silently drifts out of the automated update loop.

| Source kind | Update mechanism |
|---|---|
| `git_repo` with `track:` glob | Add a matrix entry to the `track` job in `.github/workflows/track-bst-sources.yml` |
| `kind: tar` / `kind: remote` (tarball-pinned) | Add a `<name>-update` mise task **and** a dedicated CI job in `track-bst-sources.yml` following the `track-mise` pattern |

### track-mise pattern for tarball-pinned elements

The `track-mise` job in `track-bst-sources.yml` is the reference. Key steps:

1. Read the current version from the element file.
2. Run `mise run <name>-update` — the task fetches the latest release, downloads tarballs, computes SHA256, and rewrites the element in place.
3. Check `git diff` — skip the PR if nothing changed.
4. Read the new version.
5. Create or update the `auto/track-<name>` PR using `gh pr create`/`gh pr edit`.

The mise task itself must be idempotent — running it when already up to date must print "Already up to date" and exit 0 without modifying any files.

### Wiring the CI job

Add the element name to `workflow_dispatch.inputs.group.options` and add a new job alongside the existing `track-mise` / `track-linux-cachyos` jobs. Use `if: github.event.inputs.group == 'all' || github.event.inputs.group == '<name>' || github.event_name == 'schedule'` so it runs on the daily schedule and can be triggered manually.

### Verifying the CI job before merge

After adding the mise task and CI job on a feature branch, trigger the workflow on that branch to confirm end-to-end behaviour before the PR merges:

```shell
gh workflow run track-bst-sources.yml --ref <branch> --field group=<name>
gh run watch <run-id> --exit-status
```

The job should either create/update a PR (if a new release exists) or print "Already up to date" and exit 0. Offer this verification step to the user when opening a PR that adds a new tracking task.

**ghostty-specific:** `ghostty-org/ghostty` does not publish GitHub releases — `releases/latest` returns 404. Use `repos/ghostty-org/ghostty/tags` (paginated) and filter for semver tags in Python rather than jq, which avoids jq version incompatibilities in the CI runner.

### .deb extraction in BST sandbox

`.deb` files are `ar` archives containing `control.tar.xz` and `data.tar.xz`. BST has no native `.deb` source kind. Extract manually in `build-commands`:

```yaml
build-depends:
- freedesktop-sdk.bst:components/binutils.bst  # ar
- freedesktop-sdk.bst:components/tar.bst       # tar with xz

config:
  build-commands:
  - ar x proton-pass.deb data.tar.xz
  - tar -xJf data.tar.xz

  install-commands:
  - cp -a usr/lib/proton-pass "%{install-root}%{indep-libdir}/"
  - ln -s '%{indep-libdir}/proton-pass/Proton Pass' "%{install-root}%{bindir}/proton-pass"
  - install -Dm644 usr/share/applications/proton-pass.desktop "%{install-root}%{datadir}/applications/proton-pass.desktop"
  - "%{install-extra}"
```

- `ar x` goes in `build-commands` (has `build-depends`); `cp`/`ln`/`install` go in `install-commands` (has `depends` only — `runtime-minimal` provides `cp`/`ln`/`install`).
- **`%{install-root}` subdirs do NOT pre-exist.** `cp -a usr/lib/proton-pass "%{install-root}%{indep-libdir}/"` fails because `/buildstream-install/usr/lib/` was never created. Use `cp -a usr "%{install-root}/"` to copy the whole extracted tree at once (same pattern as `linux-cachyos.bst`).
- `strip-binaries: ''` required — pre-built ELFs must not be stripped.
- Update path: `kind: remote` + mise update task + CI job (same as other tarball-pinned elements).

**Bundled Electron apps (e.g. Proton Pass):** ship the `.deb`'s bundled Electron as-is — `resourcesPath` is already correct inside `usr/lib/<app>/`. No ASAR patching needed. System Electron is only needed when stripping the bundled one.

**Version discovery (Proton apps):** `https://proton.me/download/PassDesktop/linux/x64/version.json` returns `{"Releases": [{"CategoryName": "Stable", "Version": "X.Y.Z", ...}]}`. Parse with Python: `[r for r in data['Releases'] if r['CategoryName'] == 'Stable'][0]['Version']`.

### Raw binary elements (`kind: remote` + `filename`)

For pre-built raw binaries (not tarballs) use `kind: remote`. The `filename:` key controls the staged filename — place it at the source level, *outside* the arch-conditional block, so `install-commands` can reference a stable name regardless of arch:

```yaml
sources:
- kind: remote
  filename: pangolin-cli          # stable name used in install-commands
  (?):
  - arch == "x86_64":
      url: github_files:owner/repo/releases/download/0.10.2/tool_linux_amd64
      ref: <sha256>
  - arch == "aarch64":
      url: github_files:owner/repo/releases/download/0.10.2/tool_linux_arm64
      ref: <sha256>
```

Then in `config.install-commands`: `install -Dm755 pangolin-cli "%{install-root}%{bindir}/tool"`.

**`kind: remote` vs `kind: tar`**: use `remote` when the release asset is a raw ELF (e.g. `pangolin-cli_linux_amd64`), `tar` when it's a `.tar.gz`/`.tar.xz` (e.g. gum, mise). Both are no-ops for `bst source track`; both require a mise update task and CI job.

### Systemd service installation

**System services** need three things:

| What | Path | Notes |
|------|------|-------|
| Service file | `%{indep-libdir}/systemd/system/<name>.service` | Fix `/usr/sbin` → `/usr/bin`; remove `EnvironmentFile=/etc/default/` lines |
| Preset file | `%{indep-libdir}/systemd/system-preset/80-<name>.preset` | Content: `enable <name>.service` |
| Binaries | `%{bindir}` | Never `/usr/sbin` — freedesktop-sdk uses merged-usr |

#### Optional services gated on user-supplied credentials

For services that require runtime credentials (API keys, client secrets) that must **not** be baked into the OCI image, combine `ConditionPathExists=` with `EnvironmentFile=`:

```ini
[Unit]
ConditionPathExists=/etc/tool/credentials

[Service]
EnvironmentFile=/etc/tool/credentials
ExecStart=/usr/bin/tool --id ${TOOL_CLIENT_ID} --secret ${TOOL_SECRET}
```

This makes the service a no-op (no error) if the credentials file is absent, so the binary can be shipped unconditionally and the preset can enable the service unconditionally. Users drop their credentials file and rebase to activate the service.

The credentials file lives at `/etc/tool/credentials` (not `/etc/default/`) and is **not** installed by the BST element — it is provisioned at runtime, outside the OCI image.

**User services** (session-scoped, run as the logged-in user):

| What | Path |
|------|------|
| Service file | `%{indep-libdir}/systemd/user/<name>.service` |
| Preset file | `%{indep-libdir}/systemd/user-preset/80-<name>.preset` |

Enable services via preset files. Never `systemctl enable` in install-commands.

### gnome-build-meta `kind: cargo` only installs the binary

The gnome-build-meta `kind: cargo` element kind runs `cargo install --path . --root %{prefix}`. It installs **only the compiled binary** — it does not install any other upstream files (service files, man pages, data files in `resources/`, etc.).

If an upstream Rust project ships a service file or config alongside the binary, you must install those files in a separate `config/<name>.bst` element.

**Example:** `gnome-build-meta.bst:sdk/xwayland-satellite.bst` installs `/usr/bin/xwayland-satellite` only. The upstream `resources/xwayland-satellite.service` is NOT installed. Additionally, that upstream service file hardcodes `/usr/local/bin/xwayland-satellite` — wrong for fdsdk installs. The companion `config/xwayland-satellite.bst` ships a corrected copy pointing to `/usr/bin/xwayland-satellite`.

### udev rules elements

Install udev rules via a `kind: manual` element with a `local` source pointing to a `files/udev/` directory. Set `strip-binaries: ""` to suppress the stripper (no binaries to strip).

```yaml
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  install-commands:
  - install -Dm644 <name>.rules "%{install-root}/usr/lib/udev/rules.d/<name>.rules"

sources:
- kind: local
  path: files/udev
```

Rules go in `/usr/lib/udev/rules.d/` (not `/etc/udev/rules.d/` — the latter is for admin overrides). Wire the element into `stacks/base-system.bst`.

**Hiding composefs erofs loop devices from UDisks/Nautilus:** `core/composefs-loop-udisks-ignore.bst` installs `90-hide-composefs-loop.rules`. Matches `KERNEL=="loop*"` + `ENV{ID_FS_TYPE}=="erofs"` and sets `ENV{UDISKS_IGNORE}="1"`. The `ATTR{loop/backing_file}` glob approach is intentionally avoided — fnmatch `*` does not cross `/` separators, so `/composefs/objects/<2-char>/<hash>` paths would not match. Pattern sourced from dakota.

**Codeberg tarball sources:** Codeberg serves release tarballs at `https://codeberg.org/<user>/<repo>/archive/<tag>.tar.gz`. Add `codeberg_files: https://codeberg.org/` to `include/aliases.yml` file aliases (distinct from the `codeberg:` git alias which already exists) and use `codeberg_files:<user>/<repo>/archive/<tag>.tar.gz` in `kind: tar` sources. Update path via mise task + CI job (`track-mise` pattern) — `bst source track` is a no-op on `kind: tar`.

**Desktop performance config element pattern (`config/desktop-udev.bst`):** A single `kind: manual` element with a `kind: local` source can install across multiple `/usr/lib/` subdirectories (udev/rules.d, modprobe.d, modules-load.d, tmpfiles.d) using a glob loop in `install-commands`. Use `strip-binaries: ""` since no binaries. Keep files under `files/<element-name>/` mirroring the target subdirectory structure. CachyOS-Settings (`github.com/CachyOS/CachyOS-Settings`) is a reference for performance udev rules: IO schedulers, audio PM, SATA link power, THP tmpfiles, amdgpu modprobe, ntsync modules-load. Omit: `30-zram.rules` (conflicts with `zram-generator`), `85-iw-regulatory.rules` (needs extra service), `69-hdparm.rules` (hdparm not in fdsdk), NVIDIA rules.

### Vulkan ICD discovery with fdsdk mesa

fdsdk mesa installs Vulkan ICDs at `%{libdir}/GL/vulkan/icd.d/` (non-standard prefix). The Vulkan loader searches `$XDG_DATA_DIRS/vulkan/icd.d/` and `/usr/share/vulkan/icd.d/` — neither of which is the fdsdk path.

**Fix:** add `freedesktop-sdk.bst:components/compat-vulkan-link.bst` to the desktop stack. It is a `kind: stack` element with integration-commands that symlink `/usr/share/vulkan/icd.d` → the fdsdk path. Required for Zink (OpenGL-over-Vulkan), direct Vulkan apps, and Flatpak apps that use the host Vulkan driver (e.g. Steam, games, legacy GL apps via Zink).

### libfido2 libudev runtime dependency

libfido2 ≥ 1.10 has a hard `libudev` dependency that the fdsdk `components/libfido2.bst` element does **not** propagate. Any local element that `build-depends` on `libfido2` must add `components/systemd-libs.bst` to its runtime `depends:` explicitly, or the module will fail to load at runtime with a missing `libudev.so` error.

```yaml
build-depends:
- components/libfido2.bst

depends:
- components/systemd-libs.bst # libfido2 ≥1.10 hard libudev dep
```

This is the same pattern used by `freedesktop-sdk.bst:components/openssh.bst` (line 12). It applies to any element that links against libfido2 — `pam-u2f`, security key middleware, etc.

### Common mistakes

| Mistake | Fix |
|---------|-----|
| Missing `freedesktop-sdk.bst:` junction prefix | Every dep on a fdsdk element must be fully qualified: `freedesktop-sdk.bst:components/foo.bst`. Bare names like `components/foo.bst` silently resolve against the local `elements/` directory and fail at load time with "Could not find element". |
| Autotools project tries to build man pages (`a2x is missing`) | Add `--disable-man` to `conf-local`. `a2x` (asciidoc) is not in the BST build sandbox. |
| Missing `strip-binaries: ""` | Required for non-ELF content (fonts, configs, pre-built binaries) |
| Missing dynamic libs for build tools | If a build tool (e.g. `bsdtar`) links dynamically against compression libs (bzip2, xz, zstd, lz4), each must be an explicit `build-depends` — the sandbox only contains what you declare. Symptom: `error while loading shared libraries: libbz2.so.1` at build time. |
| Using `/usr/sbin` | Always `/usr/bin` — merged-usr |
| `EnvironmentFile=/etc/default/...` | Remove from upstream service files — not used here |
| Variable in source URL | BST doesn't expand variables in `url:` fields — use an alias from `include/aliases.yml` |
| Missing `%{install-extra}` | Must be the last install-command |
| Forgot to add element to `deps.bst` | Element builds but won't appear in the image |
| Preset at `/etc/systemd/system-preset/` | Ignored at boot — must be `%{indep-libdir}/systemd/system-preset/` |
| Adding `ostree-minimal.bst` when `ostree.bst` is already in the image | Causes non-whitelisted overlaps at `oci/krytis/runtime.bst` — `ostree.bst` (pulled in by `core/bootc.bst`) is a superset; omit `ostree-minimal.bst` entirely |
| `touch /etc/machine-id` doesn't trigger first boot | `ConditionFirstBoot=yes` (used by `systemd-firstboot.service`) requires `/etc/machine-id` to contain the literal string `uninitialized\n`, not an empty file. Use `printf 'uninitialized\n' > /etc/machine-id` in the OCI stack integration-commands. |

## Job Parallelism in `kind: manual`

`kind: manual` build sandboxes do NOT have the `JOBS` environment variable set. Only BST's meson/cmake buildsystem plugins inject `JOBS`. Use `$(nproc)` instead.

```yaml
build-commands:
- ninja -v -j$(nproc) -C _build   # correct
# ninja -v -j${JOBS} -C _build    # WRONG — ${JOBS} is empty, ninja exits with "invalid -j parameter"
```

Do NOT use `${JOBS}`, `%{max-jobs}`, or `$JOBS` in `kind: manual` elements.

## Rust / Cargo Projects

### Strategy A: cargo2 source (live Cargo.lock)

Use when you want BST to track the exact crate graph from upstream's Cargo.lock.

```yaml
kind: make    # not kind: cargo2 — cargo2 is a source kind, not an element kind

build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  cargo-home: '%{build-root}/.cargo'

config:
  build-commands:
  - |
    export CARGO_HOME="%{cargo-home}"
    cargo build --release --locked --workspace

  install-commands:
  - install -Dm755 target/release/<binary> "%{install-root}%{bindir}/<binary>"
  - "%{install-extra}"

sources:
- kind: tar
  url: alias:owner/<name>/archive/refs/tags/v%{version}.tar.gz
  ref: <sha256>
# cargo2 block below — GENERATED, never hand-written
- kind: cargo2
  url: crates:crates
  ref:
  - kind: registry
    name: ...
```

**cargo2 sources are generated from Cargo.lock**, not written by hand:

```bash
python3 files/scripts/generate_cargo_sources.py /path/to/Cargo.lock
```

To update after a version bump:
1. `mise bst source track elements/krytis/<name>.bst`
2. `mise bst shell --build elements/krytis/<name>.bst` — copy out the new Cargo.lock
3. Regenerate cargo2 sources and replace the block in the element

### Strategy B: upstream vendored-dependencies tarball

Use when the upstream project publishes an official vendored tarball alongside each release (e.g. niri). Avoids the cargo2 plugin entirely and keeps the element short.

```yaml
kind: make

build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  cargo-home: '%{build-root}/.cargo'

config:
  build-commands:
  - |
    mkdir -p .cargo
    cat > .cargo/config.toml <<'EOF'
    [source.crates-io]
    replace-with = "vendored-sources"

    # Add a stanza like this for each git dep that bypasses crates.io:
    [source."git+https://github.com/Example/repo.git?rev=<sha>"]
    git = "https://github.com/Example/repo.git"
    rev = "<sha>"
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor"
    EOF
  - |
    export CARGO_HOME="%{cargo-home}"
    export CARGO_NET_OFFLINE=true
    cargo build --release --frozen --locked

  install-commands:
  - install -Dm755 target/release/<binary> "%{install-root}%{bindir}/<binary>"
  - "%{install-extra}"

sources:
- kind: tar
  url: github_files:owner/repo/archive/refs/tags/v<ver>.tar.gz
  ref: <sha256>
- kind: tar
  url: github_files:owner/repo/releases/download/v<ver>/<name>-<ver>-vendored-dependencies.tar.xz
  base-dir: ""   # vendored tarball extracts directly to vendor/ with no wrapping dir
  ref: <sha256>
```

The vendored tarball extracts into `vendor/` inside the source directory. Check the upstream Cargo.lock for `git+` entries — each one needs its own `[source."git+..."]` stanza in `.cargo/config.toml`.

#### Git dep stanzas drift between releases (niri / Smithay)

When a project's `Cargo.lock` pins a dependency via `git+https://` (e.g. niri pinning Smithay at a specific rev), the rev appears **twice** in the BST element's `build-commands` heredoc — once in the TOML section key and once in the `rev =` value:

```toml
[source."git+https://github.com/Smithay/smithay.git?rev=<sha>"]
git = "https://github.com/Smithay/smithay.git"
rev = "<sha>"
replace-with = "vendored-sources"
```

This rev can change between upstream releases. If you bump the version manually (without using `mise run niri-update`), extract the new `Cargo.lock` from the source tarball and grep for the Smithay rev:

```bash
tar -xzf src.tar.gz --wildcards "*/Cargo.lock" -O | grep -oP '(?<=\?rev=)[^#]+'
```

Update both occurrences in the element. `mise run niri-update` does this automatically.

### `buildsystem-make.bst` is required for all Rust elements — missing it silently breaks linking

Symptom: build succeeds through `cargo build` but then fails with:

```
posix_spawn failed: No such file or directory
```

Cause: `buildsystem-make.bst` provides the system linker (`ld` / `lld`) that clang invokes after compiling. If only `runtime-minimal.bst` is in `build-depends`, the sandbox has no linker binary and the spawn fails. The skeleton above already includes `buildsystem-make.bst`; this bites when you omit it while simplifying `build-depends`.

Fix: ensure `freedesktop-sdk.bst:public-stacks/buildsystem-make.bst` is in `build-depends`, not just `depends`.

### C library deps and Mesa

C libraries needed at runtime go in `depends` — BST stages `depends` items at build time too, so headers and pkgconfig files are available to the compiler. Mesa is an exception: always list it in **both** `build-depends` and `depends`:

```yaml
build-depends:
- freedesktop-sdk.bst:extensions/mesa/mesa.bst   # GL headers + pkgconfig

depends:
- freedesktop-sdk.bst:extensions/mesa/mesa.bst   # GL libraries at runtime
```

Mesa installs pkgconfig files under a non-standard path. Add to the build env explicitly:

```yaml
variables:
  mesa-gl-dir: '%{libdir}/GL/default/lib'

config:
  build-commands:
  - |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
    cargo build ...
```

**Runtime: mesa libs are not findable by default.** Mesa installs under `%{libdir}/GL/default/lib/` — a path the dynamic linker does not search. Two things are required in the image:

1. Add `freedesktop-sdk.bst:vm/mesa-default.bst` to the desktop stack. This installs `/etc/ld.so.conf.d/00_mesa.conf` pointing at the GL/default path.

2. Run `ldconfig` in `oci/krytis/image.bst` after all packages are staged:

```yaml
- |
  ldconfig -r /layer -f /layer/etc/ld.so.conf
```

Without both, any binary linking against `libgbm`, `libEGL`, etc. fails at runtime with "cannot open shared object file". Mesa's DRI drivers and GBM backend modules have the GL/default prefix baked in at compile time, so `LIBGL_DRIVERS_PATH`/`GBM_BACKENDS_PATH` are not needed separately.

**Cargo features for systemd integration:** Rust binaries that integrate with systemd (socket notification, session management) must include `systemd` in the feature list:

```yaml
cargo build ... --features "dbus xdp-gnome-screencast systemd"
```

niri built without `--features systemd` warns at startup and cannot notify systemd of readiness.

Other Rust elements that link against C libraries need the library in both `build-depends` and `depends`:

```yaml
build-depends:
- freedesktop-sdk.bst:components/linux-pam.bst   # for the linker

depends:
- freedesktop-sdk.bst:components/linux-pam.bst   # for the runtime
```

## Kernel: CachyOS Pre-built Package

Krytis uses the CachyOS `linux-cachyos` kernel (BORE-EEVDF scheduler, x86_64_v3 optimised) sourced from the CachyOS v3 pacman repository. The package is a `.pkg.tar.zst` flat tarball; BST fetches it with `kind: remote` and extracts manually because BST2's Python 3.13 does not support zstd in `tarfile` (added in Python 3.14).

**Updating the kernel:**
```bash
mise run kernel-update    # parses cachyos-v3.db, rewrites version/pkgrel/ref in-place
mise run validate         # confirm graph still resolves
```

The `kernel-update` task downloads `cachyos-v3.db` (pacman package database), extracts `linux-cachyos*/desc`, and patches `elements/core/linux-cachyos.bst` with the new version, pkgrel, and SHA256.

**Package layout:** CachyOS packages install the kernel at `/usr/lib/modules/<kver>/vmlinuz` (already bootc-compatible; no path adjustment needed).

## Multiple Plugin Junction Contexts

When a project's `project.conf` declares plugins via `junction:` AND the same plugin project is also used internally by a sub-junction (e.g. fdsdk and gnome-build-meta both load `buildstream-plugins-community`), BST emits a fatal "loaded in multiple contexts" error.

**Fix:** add a `junctions: internal:` block to `project.conf` listing the junctions that are shared:

```yaml
junctions:
  internal:
  - plugins/buildstream-plugins.bst
  - plugins/buildstream-plugins-community.bst
```

This tells BST these junctions are intentionally shared/internal so the multiple-context check is suppressed. Every project that layers on top of fdsdk + gnome-build-meta needs this block.

## BST inside a composefs root

bubblewrap + user namespaces work inside a bootc composefs-mounted root without any sysctl override. Verified by running `mise load-image --container` inside a booted Krytis VM. No `kernel.unprivileged_userns_clone` drop-in is needed.

## Additive Rust replacements: overlap-whitelist

When a new element installs files to paths already owned by an upstream element (e.g. uutils-coreutils overwriting GNU coreutils bins), BST errors at assembly time unless every overlapping path appears in `overlap-whitelist`.

```yaml
public:
  bst:
    overlap-whitelist:
    - /usr/bin/[
    - /usr/bin/cat
    - /usr/bin/ls
    # ... one entry per file that overlaps
```

**Glob patterns work** in `overlap-whitelist` — `*` and `**` are both supported:
```yaml
overlap-whitelist:
  - '/usr/lib/x86_64-linux-gnu/GL/default/lib/dri/*_drv_video.so'  # all VA-API drivers
  - '**/*'  # used in oci/krytis/runtime.bst to whitelist all compose output
```

**uutils-coreutils pattern** (additive, not a junction override): fdsdk has no `components/coreutils.bst` — only a bootstrap-chain `bootstrap/coreutils.bst` that cannot be overridden. uutils is added as a new `elements/core/uutils-coreutils.bst` that layers on top.

- Multicall binary installed at `/usr/bin/uutils-coreutils`.
- Two symlinks per utility: `uutils-<prog>` (always) and `<prog>` (plain-name, for replacing the GNU bin) — except **cp, mv, rm** which stay on GNU due to unresolved TOCTOU issues (projectbluefin/common#290).
- `overlap-whitelist` must list every plain-name symlink that collides; cp/mv/rm are excluded from symlinks AND from the whitelist.
- Build flags: `--features feat_os_unix --no-default-features` (no `--locked`; uses `cargo2` source for offline crate registry).
- Update path: `kind: git_repo` with `track:` glob → option A (no mise update task or CI override needed beyond the `track:` matrix entry in `track-bst-sources.yml`).

## `kind: local` source becomes dangling when directory is emptied

Git does not track empty directories. If the last file inside a `files/<name>/` directory is deleted, the directory itself disappears from the working tree. Any element with `- kind: local / path: files/<name>` will then fail at element resolution with:

```
Specified path 'files/<name>' does not exist
```

BST validates `kind: local` paths at resolution time (before any build), so the failure blocks the entire pipeline — not just the affected element.

**Fix:** remove the `kind: local` source block from the element when you delete the last file it referenced. Don't leave the stale source entry expecting git to preserve an empty directory.

**How it happened (#198):** `ebfb813` deleted `files/pangolin-cli/pangolin-cli.service` (the only file in that directory). The `kind: local` source in `core/pangolin-cli.bst` was not cleaned up, breaking all full-image builds on `main` until #198 landed.

## System Tool Requirements for `bst source track`

`bst source track` initialises the full BST platform at startup — including `buildbox-run`, which checks for `bwrap` unconditionally even though source tracking never runs a build sandbox. Additionally, BST resolves the complete element graph before tracking, which validates all declared tool binaries (`lzip`, `xz-utils`, `bzip2`, `gzip`, `patch`, etc.) against `PATH`.

**All the same system packages needed for a build are required for source tracking:**

```yaml
# In mise.toml
[bootstrap.packages]
"apt:bubblewrap" = "latest"
"apt:lzip" = "latest"
"apt:xz-utils" = "latest"
"apt:bzip2" = "latest"
"apt:gzip" = "latest"
"apt:patch" = "latest"
```

In CI, run `mise bootstrap --yes` (with `experimental: true` on the action) before any `bst` invocation, not just build jobs.

## Meson Builds That Need Mesa (prepend-mesa-env Pattern)

mesa installs under `%{libdir}/GL/default` — a non-standard prefix that `pkg-config` and the linker don't search. bst runs each meson stage (`meson setup`, `ninja`, `meson install`) in a **separate `sh -c` process**, so env exports don't persist between stages. Override the three meson stage variables directly:

```yaml
variables:
  mesa-gl-dir: '%{libdir}/GL/default/lib'
  prepend-mesa-env: |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"; export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"; export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
  meson: '%{prepend-mesa-env}; meson setup %{conf-root} %{build-dir} %{meson-args}'
  meson-build: '%{prepend-mesa-env}; ninja -v -j ${JOBS} -C %{build-dir}'
  meson-install: '%{prepend-mesa-env}; env DESTDIR="%{install-root}" meson install -C %{build-dir} --no-rebuild'
```

Also list `freedesktop-sdk.bst:extensions/mesa/mesa.bst` in BOTH `build-depends` and `depends`. For elements that call `dependency('gbm')` or `dependency('libdrm')`, add `freedesktop-sdk.bst:extensions/mesa/libdrm.bst` to `build-depends` as well — the `.pc` file lives in libdrm's runtime split, and without the explicit dep bst won't stage it. Without libdrm.bst, meson falls through to `subprojects/libdrm.wrap` and fails with `Automatic wrap-based subproject downloading is disabled`.

## wlroots-0.20 Constraints

- `noctalia-greeter`'s `meson.build` uses `dependency('wlroots-0.20')` — an exact pcname match. wlroots 0.21+ would require patching the greeter.
- Valid meson options in 0.20.1 (from `meson.options`): `examples`, `backends` (choices: `drm`, `libinput`, `x11`, `auto`), `xwayland`, `xcb-errors`, `renderers`, `allocators`, `session`, `color-management`, `libliftoff`. **NOT valid:** `-Dtests` (removed since 0.18), `-Dlibcap-ng` (hard dep), `-Dbackends=wayland` (wayland is not a backend choice).
- `libxkbcommon.bst` must be in `build-depends` (not just `depends`) because wlroots' meson.build has a subproject wrap fallback for it that fires if the `.pc` isn't staged.
- Use `freedesktop-sdk.bst:components/libdisplay-info.bst` in `depends` — **not** `gnome-build-meta.bst:core-deps/libdisplay-info.bst`. Both ship the same files; the gnome-build-meta copy causes a non-whitelisted overlap because `niri.bst` already pulls the fdsdk version.
- For `hwdata`: wlroots' DRM backend needs `hwdata.pc` at configure time, but `gnome-build-meta.bst:core-deps/hwdata.bst` overlaps `pciutils` (which ships `pci.ids` and is already in `base-system.bst`) at runtime. Fix: put `gnome-build-meta.bst:core-deps/hwdata.bst` in **`build-depends` only** — available to meson configure, not staged into the final image.

## greetd: Rust Element Without Upstream Vendored Tarball

greetd does not publish a vendored-dependencies tarball. Use `kind: cargo2` as a source (not element kind) to pre-fetch the crate registry. The element kind is `manual`:

```yaml
kind: manual

build-depends:
- freedesktop-sdk.bst:components/rust.bst
...
sources:
- kind: tar
  url: github_files:kennylevinsen/greetd/archive/refs/tags/0.10.3.tar.gz
  ref: <sha256>
- kind: cargo2
  url: crates:crates
  ref:
  - kind: registry
    name: ...
```

The `kind: cargo2` source block lists every crate from `Cargo.lock`. After updating greetd, regenerate it with `python3 files/scripts/generate_cargo_sources.py /path/to/Cargo.lock`, then validate SHA lengths:

```bash
grep -E '^ *sha:' elements/desktop/greetd.bst | awk '{print length($2)}' | sort -u
# Must output: 64
```

greetd links libpam via `pam-sys`. Add `linux-pam.bst` to **both** `build-depends` AND `depends` — it transitively provides `linux-pam-base.bst` which supplies `libpam.so` + `libpam_misc.so`.

## Greeter Stack: greetd display-manager Alias

`greetd.service` ships with `Alias=display-manager.service`. Installing greetd creates the `display-manager.service` symlink automatically — no manual masking of other display managers is needed.

## greetd PAM Configuration (fdsdk)

fdsdk does **not** ship `system-local-login` (an Arch Linux convention). It does ship `system-auth` via `linux-pam-base.bst`, but `image.bst` removes it from `usr/share/factory/etc/pam.d/` — so at runtime, `/etc/pam.d/system-auth` won't exist either.

Use a **self-contained PAM config** that references modules directly:

```
#%PAM-1.0
# Self-contained: fdsdk does not ship system-local-login or system-auth at
# runtime (factory copies are stripped in image.bst). Use modules directly.

auth       required     pam_nologin.so
auth       required     pam_unix.so
auth       optional     pam_gnome_keyring.so

account    required     pam_nologin.so
account    required     pam_unix.so

password   required     pam_unix.so sha512 shadow
-password  optional     pam_gnome_keyring.so use_authtok

session    required     pam_loginuid.so
session    optional     pam_keyinit.so force revoke
session    required     pam_limits.so
session    required     pam_unix.so
-session   optional     pam_systemd.so
session    required     pam_env.so
session    optional     pam_gnome_keyring.so auto_start
```

`-session optional pam_systemd.so` is critical — this registers the session with logind, which is what grants the compositor DRM/GPU device access. Without it the greeter process can start but will fail to open `/dev/dri/card*`.

**greeter user groups:** The greeter sysuser must be in both `video` and `render` groups. `render` is required for `/dev/dri/renderD*` (the render node); libseat does not handle render nodes, so the group membership is the only path:

```
u greeter - "greetd greeter user" /var/lib/greetd -
m greeter video
m greeter render
```

**greeter home directory:** `systemd-sysusers` sets the home field in the user record but does NOT create the directory. Add a `tmpfiles.d` entry to create it at boot. Without this, gnome-keyring and anything else that writes to `$HOME` will fail silently:

```
d /var/lib/greetd 0750 greeter greeter -
d /var/lib/noctalia-greeter 0755 greeter greeter -
```

## Firmware Elements

`freedesktop-sdk.bst:components/linux-firmware.bst` exists and is directly usable as a junction dep. It sources `linux-firmware.git` from kernel.org, installs the full firmware tree xz-compressed and deduped to `/usr/lib/firmware`, and runs `make install-xz dedup`. No subsetting — ships everything.

**This is not visible in the fdsdk GitLab web search** (indexing gap). Confirm presence by checking the staged junction cache: `.bst/staged-junctions/freedesktop-sdk.bst/*/elements/components/linux-firmware.bst`.

`sof-firmware.bst` also exists alongside it (Intel HDA DSP audio firmware, sourced from thesofproject/sof-bin tarball releases).

Pattern (from zirconium-hawaii `stacks/base-system.bst`):
```yaml
# ── Firmware ───────────────────────────────────────────────────────
- freedesktop-sdk.bst:components/fwupd.bst
- freedesktop-sdk.bst:components/linux-firmware.bst     # full linux-firmware.git tree
- freedesktop-sdk.bst:components/sof-firmware.bst       # Intel HDA DSP — skip if AMD-only
- freedesktop-sdk.bst:components/wireless-regdb-bin.bst
```

`strip-binaries: ''` is not needed as a local override — the fdsdk element already sets it. Firmware blobs must not be stripped; the fdsdk element handles this.

## User Session: XDG_SESSION_TYPE Must Be Set Before pam_systemd.so

greetd calls `pam_open_session` before forking to exec the user's session command. `niri-session` sets `XDG_SESSION_TYPE=wayland`, but that happens *after* PAM runs — too late for `pam_systemd.so` to register the session as `type=wayland` with logind.

Without `XDG_SESSION_TYPE=wayland` visible to `pam_systemd.so`:
- logind registers the session as `tty` type
- libseat asks logind for the seat; logind refuses (tty session can't own DRM)
- the Wayland compositor blocks in `libseat_open_seat()` indefinitely
- symptom: screen clears, compositor prints startup warning, then hangs forever

**Fix:** ship `/etc/environment` and place `pam_env.so readenv=1` *before* `pam_systemd.so` in the PAM session stack:

```
# /etc/environment
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=niri
```

```
# /etc/pam.d/greetd (session phase, order matters)
session    required     pam_env.so readenv=1   ← must come before pam_systemd.so
session    required     pam_unix.so
-session   optional     pam_systemd.so         ← now sees XDG_SESSION_TYPE
```

Also ship `/usr/lib/environment.d/90-krytis-session.conf` with the same vars so `systemd --user` (and any process started via it) inherits them once the user session is running.

## Flatpak: Transitive Presence and Flathub Config

`freedesktop-sdk.bst:components/flatpak.bst` is **already in the image as a transitive dependency** — do not add it explicitly:

```
stacks/desktop.bst
  → gnome-build-meta.bst:core-deps/xdg-desktop-portal-gtk.bst (or -gnome)
    → freedesktop-sdk.bst:components/xdg-desktop-portal.bst
      → (runtime-depends) freedesktop-sdk.bst:components/flatpak.bst
```

To pre-configure the Flathub remote system-wide, add to `stacks/desktop.bst`:

```yaml
- gnome-build-meta.bst:gnomeos-deps/flathub-config.bst
```

This installs the `.flatpakrepo` file to `/usr/share/flatpak/remotes.d/` — the correct location for bootc (immutable `/usr` tree, not `/etc`). The alternative `freedesktop-sdk.bst:vm/config/flathub.bst` installs to `/etc/flatpak/remotes.d/` which is less appropriate for an immutable image.

## Upstream Project Renames (2026)

| Project | Old URL | Current URL |
|---|---|---|
| cage | `Hjdskes/cage` (sr.ht) | `github_files:cage-kiosk/cage` |
| wlr-randr | `sr.ht/~emersion/wlr-randr` | `freedesktop_files:emersion/wlr-randr` |
| noctalia-shell | `noctalia-dev/noctalia-shell` | `github_files:noctalia-dev/noctalia` |

Always verify the canonical URL when vendoring a source for the first time.

## Commit-SHA Source Pinning (Repos Without Release Tags)

GitHub's `archive/refs/heads/<branch>.tar.gz` regenerates on every push — the sha256 changes each time. Use a full commit SHA in the URL instead:

```yaml
sources:
- kind: tar
  url: github_files:org/repo/archive/<full-40-char-sha>.tar.gz
  ref: <sha256-of-the-tarball>
```

When the upstream repo is renamed (e.g. `noctalia-shell` → `noctalia`), GitHub will redirect the old URL but the alias expander won't follow it — update the URL to use the new repo name.

To get the tarball sha256 without BST:

```bash
curl -sL https://github.com/<org>/<repo>/archive/<sha>.tar.gz | sha256sum
```

## sdbus-cpp: Required CMake Flags

sdbus-cpp will build and vendor its own copy of libsystemd by default — this conflicts with fdsdk's systemd. Always pass `-DSDBUSCPP_BUILD_LIBSYSTEMD=OFF`:

```yaml
variables:
  cmake-local: >-
    -DSDBUSCPP_BUILD_CODEGEN=OFF
    -DSDBUSCPP_BUILD_DOCS=OFF
    -DSDBUSCPP_BUILD_TESTS=OFF
    -DSDBUSCPP_BUILD_EXAMPLES=OFF
    -DSDBUSCPP_BUILD_LIBSYSTEMD=OFF   # critical — prevents bundled libsystemd conflict
    -DBUILD_SHARED_LIBS=ON
```

## Journal Persistence Drop-in

Hard resets (power cut, test failure) lose journald's in-memory write buffer when `Storage=auto` (the default). If a journal directory already exists, `auto` IS persistent — but the unflushed buffer is still lost. Shipping a drop-in forces persistence AND frequent syncs so you capture logs from failing boots:

```yaml
- |
  install -Dm644 /dev/stdin \
    "%{install-root}%{sysconfdir}/systemd/journald.conf.d/10-persist.conf" <<'EOF'
  [Journal]
  Storage=persistent
  SyncIntervalSec=5s
  EOF
```

Install to `%{sysconfdir}` (→ `/etc/`) not `%{indep-libdir}` (→ `/usr/lib/`) so it applies at runtime without a factory overlay.

## BST Source Provenance API Warning

During element graph resolution, BST 2 may emit:

```
Dependency "<element>.bst" from project "freedesktop-sdk" doesn't use the source provenance API
```

This is **informational only — the build is not affected.** It means an element from the `freedesktop-sdk` junction predates BST 2's source provenance API (the mechanism that records upstream URL/commit/checksum for SBOM generation). As fdsdk updates those elements over time, the warnings disappear on the next junction track. No action needed on the Krytis side.

Relevance: when SBOM generation is implemented (#40), elements emitting this warning will appear as gaps in the SBOM — upstream source info won't be recorded for them. This is a known limitation scoped to junction dependencies.

## Font Installation Pattern

Fonts are non-ELF content — always set `strip-binaries: ""` and override `strip-commands: [":"]`.

Install paths:
- TTF/OTF files → `%{install-root}%{datadir}/fonts/<family-name>/`
- Fontconfig conf → `%{install-root}%{datadir}/fontconfig/conf.avail/` (fontconfig picks it up from there; no need to symlink into `conf.d/`)

**`base-dir: ""`** is required for tarballs that have no top-level wrapping directory (files extract directly into the source directory). Example: Nerd Fonts `NerdFontsSymbolsOnly.tar.xz` extracts `SymbolsNerdFont-Regular.ttf` at the root level rather than inside `NerdFontsSymbolsOnly/`. Without `base-dir: ""`, BST expects a single wrapping directory and errors if it doesn't find one.

```yaml
sources:
- kind: tar
  url: github_files:ryanoasis/nerd-fonts/releases/download/v3.4.0/NerdFontsSymbolsOnly.tar.xz
  base-dir: ""   # no wrapping dir in this tarball
  ref: <sha256>
```

## Option Names: Underscores Only

BST option names only allow alphanumeric characters and underscores. Hyphens silently fail:

```yaml
# ❌ silently broken
options:
  my-arch:
    type: arch

# ✅ correct
options:
  my_arch:
    type: arch
```

## Fontconfig Cache Must Be Baked into the Image

Fontconfig does not auto-generate its cache on a bootc image. After installing font elements, `fc-list` returns nothing and apps can't find fonts until `fc-cache` is run manually. Fix: run `fc-cache` in `integration-commands` on the OCI stack element, which executes in the fully-staged image context where `fc-cache` is available:

```yaml
# elements/oci/krytis/stack.bst
public:
  bst:
    integration-commands:
      - fc-cache -f /usr/share/fonts/
```

Discovered by symptom: font file present at `/usr/share/fonts/…` on booted image, but `fc-list | grep <family>` returned nothing until `sudo fc-cache -f` was run manually.

## XCursor Themes

XCursor theme tarballs strip the single top-level `<theme-name>/` directory (BST default `kind: tar` behavior), leaving `cursors/` and `index.theme` at the staging root. The original theme dir name is gone — recreate it explicitly at the install destination:

```yaml
install-commands:
- |
  install -d "%{install-root}%{datadir}/icons/<theme-name>/"
  cp -r cursors "%{install-root}%{datadir}/icons/<theme-name>/"
  install -Dm644 index.theme "%{install-root}%{datadir}/icons/<theme-name>/index.theme"
- "%{install-extra}"
```

`strip-binaries: ""` is required — cursor files are binary data and must not be stripped.

Set the active cursor theme in niri via the `cursor { }` block in `config.kdl`. Node names are `xcursor-theme` and `xcursor-size` — not `theme` and `size` (those cause `niri validate` to fail with "unexpected node"):

```kdl
cursor {
    xcursor-theme "<theme-name>"
    xcursor-size 24
}
```

## SVG Icon Themes (Makefile-based)

Icon themes that install via `make install DESTDIR=... PREFIX=/usr` use `kind: make` with `buildsystem-make.bst`. SVGs are non-ELF content — set `strip-binaries: ""` and `strip-commands: [":"]`. Source via `git_repo` with a `track:` glob so `bst source track` handles updates.

```yaml
kind: make

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  strip-commands:
  - ":"
  build-commands: []
  install-commands:
  - 'make install DESTDIR="%{install-root}" PREFIX="%{prefix}"'
  - "%{install-extra}"

sources:
- kind: git_repo
  url: github:<owner>/<repo>.git
  track: refs/tags/*
  ref: <tag>-0-g<full-commit-sha>
```

`build-commands: []` suppresses the default `make` invocation — icon themes have nothing to compile. The Makefile's `install:` target uses `cp -R` to copy theme directories to `$(DESTDIR)$(PREFIX)/share/icons/`. Multiple theme variants (e.g. Papirus, Papirus-Dark, Papirus-Light) are installed in a single pass. Add element to the `track` matrix in `track-bst-sources.yml` — `git_repo` sources are tracked by `bst source track` directly.

## Junction override: sudo-rs replacing fdsdk sudo

`components/sudo.bst` in fdsdk can be overridden to point at `core/sudo-rs.bst`. Add to `elements/freedesktop-sdk.bst` `config.overrides`:

```yaml
components/sudo.bst: core/sudo-rs.bst
```

Key patterns (matched from `dakota/elements/bluefin/sudo-rs.bst`):

- **`kind: make`** not `kind: manual`
- **No `--locked`** on `cargo build --release`
- **No `pkg-config`** in build-depends — PAM found without it
- **Setuid via `initial-script`** — BST strips setuid bits from artifacts; `install -Dm4755` in `install-commands` does NOT survive. Use `install -Dm755` to install the binary, then set `public.initial-script` to run `chmod 4755` on the assembled sysroot (see pattern below)
- **`sudoedit` is a symlink** to `sudo` (`ln -sr ... sudo sudoedit`)
- **`overlap-whitelist`**: `/usr/bin/sudo`, `/usr/bin/sudoedit`, `/usr/lib/debug/usr/bin/sudo.debug`
- **PAM linking**: `linux-pam.bst` must appear in BOTH `build-depends` (linker) AND `depends` (runtime)
- **`vm/config/sudo.bst` stays**: installs `sudoers.d/wheel`; no change to `base-system.bst` needed
- **Must install `/etc/sudoers`**: overriding `components/sudo.bst` drops the sudoers file that GNU sudo's `make install` creates. sudo-rs requires it to exist (no fallback). Install with `#includedir /etc/sudoers.d` content, mode 0440.
- **Must install `/etc/pam.d/sudo`**: same override drops fdsdk's `pam.conf`. Install with `include system-auth` (which `config/u2f-config.bst` provides via `pam_u2f` → `pam_unix` chain).
- **No visudo**: sudo-rs doesn't ship it; omit without replacement
- Upstream URL: `github:trifectatechfoundation/sudo-rs.git` (org was renamed from `memorysafety`)

Setuid pattern (applies to any element needing a setuid binary):

```yaml
public:
  initial-script:
    script: |
      #!/bin/bash
      chmod 4755 "${1}/usr/bin/sudo"
```

The `${1}` argument is the assembled sysroot path. `image.bst` runs `prepare-image.sh --initscripts /initial_scripts` which executes these scripts under `fakecap` LD_PRELOAD so the chmod is recorded in `/fakecap` and applied to the OCI layer.

> **Security Gate**: this overrides privilege escalation. Open as draft PR and flag for human review before merge.

## `kind: compose` Stages Build-Deps of Composed Elements

**Critical:** BST 2's `kind: compose` element stages ALL deps (`--deps all`) of the elements being composed — including transitive build-deps. This means: if any element in the composed stack has `build-depends: X`, then `X` is staged in the compose sandbox alongside runtime deps.

**Consequence for overlapping element pairs (e.g. `mesa.bst` + `mesa-extra.bst`):**

If element B has `build-depends: mesa-extra.bst`, and B is in the stack that `runtime.bst` composes, then `mesa-extra.bst` appears at compose time alongside `mesa.bst`. Both provide the full mesa tree → `fatal-warnings: overlaps` fires. No `overlap-whitelist` can resolve this because `mesa.bst` itself has no whitelist and it cannot be modified (upstream).

**Diagnosis:**
```shell
bst show --deps all oci/krytis/runtime.bst | grep mesa-extra
# If mesa-extra appears here while also being a build-dep of something else, the compose will fail
```

**Solution:** avoid `build-depends: mesa-extra.bst` entirely — use a junction override instead (see below).

## Junction Override Pattern (replacing a sub-project element)

When a junction element (e.g. `extensions/mesa/mesa.bst`) provides the wrong build variant (wrong flags), override it entirely in the junction config rather than adding a second dep that overlaps with it:

```yaml
# elements/freedesktop-sdk.bst
config:
  overrides:
    extensions/mesa/mesa.bst: desktop/my-variant.bst
```

`my-variant.bst` is a krytis-local element with identical sources, deps, and build config to the original — only the variable that differs is changed (`video_codecs: all` in the mesa case).

**Cache hit potential:** BST 2 computes artifact cache keys from the RESOLVED element state (variables, config, sources, dep cache keys) — not the raw YAML or element file path. If your local element resolves to the same configuration as the upstream element, BST reuses the remote-cached artifact without rebuilding.

Requirements for cache hit:
- Sources: same refs (git SHA, tarball SHA)
- Build-deps: resolve to the same artifacts (reference fdsdk deps through the junction)
- Variables: same resolved values (hardcode arch-specific values if needed)
- Config: same install-commands

**Applied in:** `elements/desktop/mesa-all-codecs.bst` overrides `extensions/mesa/mesa.bst` with `video_codecs: all`, providing H.264/H.265 VA-API support via a single mesa replacing the all_free base. Closes #158. See `docs/skills/desktop.md` § AMD VA-API H.264 Decode.

**Limitation:** The local override element CANNOT use `(@):` to include YAML files from the sub-project — includes are resolved within the current project only. All configuration must be inlined.

### fdsdk codecs-extra: linker path, not a rebuild

fdsdk's base ffmpeg (`components/ffmpeg.bst`) has H.264 decode disabled. The codecs-extra extension (`extensions/codecs-extra/ffmpeg.bst`) has it enabled, but installs to a non-standard prefix (`/usr/lib/%{gcc_triplet}/codecs-extra/lib/`). Without an explicit ldconfig entry, the dynamic linker finds only the base libavcodec (at the default search path) and `avdec_h264` is never registered.

**Do NOT try to rebuild gst-libav against codecs-extra/ffmpeg.** Rebuilding has two unsolved problems: the override element cannot use cross-junction `(@):` includes, and at runtime the linker still resolves libavcodec.so.61 to the base path (ldconfig wins over RPATH in stripped production builds).

**Correct approach**: add the codecs-extra lib path to ld.so.conf.d in a `config/` element. gst-libav discovers codecs at plugin-init time via `av_codec_iterate()`. When codecs-extra/libavcodec.so.61 loads instead of the base build, `avdec_h264` is registered without any gst-libav rebuild.

```yaml
# elements/config/codecs-extra-ldconfig.bst
kind: manual
config:
  install-commands:
  - |
    install -Dm644 /dev/stdin \
        "%{install-root}/etc/ld.so.conf.d/codecs-extra.conf" <<'EOF'
    /usr/lib/%{gcc_triplet}/codecs-extra/lib
    EOF
  - "%{install-extra}"
```

Add this element to `elements/stacks/codecs.bst`. ld.so.conf.d entries are processed before default search paths by ldconfig, so codecs-extra/libavcodec takes precedence over the base build. Applied in `elements/config/codecs-extra-ldconfig.bst`. Closes #184.

## fdsdk `stripdir-suffix` is Debug-Symbol-Only

`stripdir-suffix` in fdsdk elements (e.g. `extensions/mesa/mesa-extra.bst`) is passed to `freedesktop-sdk-stripper` — a custom ELF debug symbol stripper/organiser. It controls where per-element debug info is placed under `/usr/lib/debug/`. **It does NOT remove duplicate runtime files from BST artifacts.**

The comment "Allows file deduplication between the two extensions" refers to Flatpak RUNTIME behavior (where the extension overlay mechanism handles deduplication), not to anything BST does at build time. `mesa-extra.bst`'s artifact contains `radeonsi_drv_video.so` just like the base `mesa.bst` — both provide the full mesa tree. Including both as runtime deps in one bootc image triggers `fatal-warnings: overlaps` and fails the build.

## `mise trust` Required on New Worktrees

New worktrees created with `git worktree add` are not automatically trusted by mise. Running any `mise` task from a new worktree without first trusting will fail:

```
mise ERROR Config files in .../mise.toml are not trusted.
Trust them with `mise trust`.
```

Run `mise trust` once in the new worktree directory before any `mise validate`, `mise bst`, etc.
