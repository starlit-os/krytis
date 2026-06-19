# BuildStream Reference

Load when writing, editing, or reviewing `.bst` element files, debugging a build failure, or understanding how the OCI image is assembled.

## Quick Reference

| Goal | Command |
|------|---------|
| Validate full element graph (no build) | `mise validate` |
| Inspect element deps | `mise bst show elements/krytis/<name>.bst` |
| Build one element | `mise bst build elements/krytis/<name>.bst` |
| Enter build sandbox | `mise bst shell --build elements/krytis/<name>.bst` |
| Track a git/tarball ref | `mise bst source track elements/krytis/<name>.bst` |
| List built element contents | `mise bst artifact list-contents elements/krytis/<name>.bst` |
| View build log | `mise bst artifact log elements/krytis/<name>.bst` |
| Delete cached build | `mise bst artifact delete elements/krytis/<name>.bst` |
| Full image build | `mise build` |

## Variables

| Variable | Expands to | Notes |
|----------|-----------|-------|
| `%{install-root}` | Staging directory | Always prefix install paths with this |
| `%{prefix}` | `/usr` | |
| `%{bindir}` | `/usr/bin` | |
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

### Systemd service installation

Services need three things:

| What | Path | Notes |
|------|------|-------|
| Service file | `%{indep-libdir}/systemd/system/<name>.service` | Fix `/usr/sbin` → `/usr/bin`; remove `EnvironmentFile=/etc/default/` lines |
| Preset file | `%{indep-libdir}/systemd/system-preset/80-<name>.preset` | Content: `enable <name>.service` |
| Binaries | `%{bindir}` | Never `/usr/sbin` — freedesktop-sdk uses merged-usr |

Enable services via preset files. Never `systemctl enable` in install-commands.

### Common mistakes

| Mistake | Fix |
|---------|-----|
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

## Rust / Cargo Projects

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

Rust elements that link against C libraries (greetd → `pam-sys`, etc.) need the C library in both `build-depends` and `depends`:

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
