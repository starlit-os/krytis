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

**On a machine that always needs `--container`, set it once instead of passing it on every invocation.** Add to `.mise.local.toml` (gitignored, per-developer):

```toml
[env]
BST_CONTAINER = "true"
```

The `bst`, `validate`, and `load-image` tasks fall back to `BST_CONTAINER` only when `--container` is not passed on the command line — an explicit flag always wins. See `docs/skills/mise.md` § Propagating flags through tasks that call other tasks.

**Agent guidance:** if a BST command fails with "Did not find 'patch' in PATH" (or another missing native-dep error), don't just retry with `--container` — recognise the pattern, explain the cause, and offer to write `BST_CONTAINER = "true"` to `.mise.local.toml` as a one-time fix for that workstation (issue #54).

## Quick Reference

| Goal | Command |
|------|---------|
| Validate full element graph (no build) | `mise validate [--container]` |
| Inspect element deps | `mise bst [--container] show desktop/<name>.bst` |
| Build one element | `mise bst [--container] build desktop/<name>.bst` |
| Enter build sandbox | `mise bst [--container] shell --build desktop/<name>.bst` |
| Track a git/tarball ref | `mise bst [--container] source track desktop/<name>.bst` |
| List built element contents | `mise bst [--container] artifact list-contents desktop/<name>.bst` |
| View build log | `mise bst [--container] artifact log desktop/<name>.bst` |
| Delete cached build | `mise bst [--container] artifact delete desktop/<name>.bst` |
| Full image build | `mise build` |

**Element names are relative to `element-path: elements` (project.conf), not to the repo
root.** `mise bst build elements/desktop/equibop.bst` fails with `Could not find element
… Did you mean 'desktop/equibop.bst'?` — pass `desktop/equibop.bst`. There is no
`elements/krytis/` directory; elements live in `core/`, `desktop/`, `config/`, `stacks/`,
`oci/`, `overrides/`, `deps/`, `dev/`, `plugins/`.

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

### Per-kind defaults go in `elements:`, not `variables:` — project variables lose to plugin defaults

To change a variable for *every* element of one kind, use project.conf's top-level `elements:`
block, keyed by plugin kind:

```yaml
elements:
  meson:
    variables:
      meson-global: >-
        --buildtype=debugoptimized
        -Db_ndebug=true
```

Putting the same key under the top-level `variables:` block **silently does nothing** when the
plugin declares its own default. The meson plugin ships `meson-global: ''` in its
`meson.yaml`, and that beats a project-level variable — so the value composes away with no
error, no warning, and a `bst show --deps none --format '%{vars}'` that still prints the key
empty. That empty print is the tell; check it after any project-wide variable change.

freedesktop-sdk does exactly this in its own `project.conf`:

```yaml
elements:
  autotools:
    (@): include/_private/autotools-conf.yml
  meson:
    (@): include/_private/meson-conf.yml
```

### fdsdk's `include/_private/` config is not inherited across the junction

krytis gets fdsdk's *elements* through the junction, but none of its `_private` build
configuration. Concretely (#604): fdsdk sets `--buildtype=plain` for its own meson elements in
`include/_private/meson-conf.yml`, krytis inherited nothing, and krytis's 13 meson elements
therefore used **meson's own default buildtype — `debug`** (`-O0`, and `b_ndebug=false`, so
`NDEBUG` never defined). The image shipped unoptimised, assert-enabled binaries for a year
without anyone noticing, because nothing warns about it.

It surfaced only because noctalia compiles a red `DEBUG` pill into its bar under
`#ifndef NDEBUG`. Generalise the detection, not the fix: `strings <binary> | grep -c` for a
symbol that upstream guards behind `NDEBUG` is a cheap way to prove which build type actually
reached the image.

**Do not fix this by copying fdsdk's line.** `--buildtype=plain` tells meson to emit no
`-O`/`-g` of its own and defer to `CFLAGS`/`CXXFLAGS` — which fdsdk sets for its own builds and
krytis does not (`bst show --format '%{environment}'` has neither). Copying it removes
optimisation *and* debug info. krytis uses `--buildtype=debugoptimized -Db_ndebug=true`:

- `debugoptimized` = `-O2 -g`. The `-g` keeps `%{strip-binaries}` splitting debug info into
  `%{debugdir}` via `freedesktop-sdk-stripper`; `--buildtype=release` drops `-g` and quietly
  empties that split. Scope it correctly, though: the **OCI image excludes the `debug` domain**
  (`elements/oci/krytis/filesystem.bst` and `runtime.bst` both `exclude: - debug`), so the
  shipped image carries no `.debug` files either way — one glibc `ld-linux` file aside. The `-g`
  is for the *artifacts*, i.e. `bst artifact checkout` and any future debuginfo work, not for
  image size. Don't verify it against the image and conclude it broke.
- `b_ndebug=true`, not `if-release`: `if-release` only fires for `release`/`plain` buildtypes,
  so it would do nothing under `debugoptimized`.

`b_ndebug=true` is not redundant with upstream's own defaults, and this is the subtle part.
noctalia's `meson.build` declares `default_options: ['b_ndebug=if-release', …]` — which reads
like the project already handles it, but `if-release` never fires under meson's default `debug`
buildtype, so asserts stayed on and its `#ifndef NDEBUG` bar pill kept shipping. A command-line
`-Db_ndebug=true` beats `default_options`; matching upstream's *spelling* would have changed
nothing.

Measured on `overrides/systemd-base.bst`, same element, same `ninja -v` verbosity, before and
after (the meson plugin runs `ninja -v`, so compile lines are in the build log):

| | `-O0` lines | `-DNDEBUG` lines |
|---|---|---|
| before | 1752 | 0 |
| after | 0 | 1752 |

So systemd — PID 1, udev, journald, logind — was compiling 1752 translation units at `-O0`
with asserts live. `desktop/mesa-all-codecs.bst` was already immune because it sets
`-Db_ndebug=true` in its own `meson-local` (now redundant with the global, but left in place:
removing it would change the resolved command line and force a mesa rebuild for no behavioural
gain).

Do not measure this from build logs alone across *different* elements — verbosity and vendored
sub-builds make the counts incomparable. Compare one element against itself, or read the
resolved command with `bst show --deps none --format '%{config}'`.

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
| `filter` | Pass through only a subset of one dep's output (e.g. the arch-specific paths of a cross-compiled element) |

**Never type a layer element as `kind: stack`.** A stack builds successfully but the OCI layer is silently empty. Verify with `grep '^kind:' elements/oci/krytis/filesystem.bst` — must show `kind: compose`.

**Every kind above is a core BuildStream plugin** (`buildstream/plugins/elements/`) — none needs a `plugins:` entry in `project.conf`. That includes `filter`, which reads like an add-on but is not. Only third-party kinds (`cargo2`, `git_repo`, … from `buildstream-plugins`/`-community`) require registration.

## Source Kinds

| Kind | Use case |
|------|---------|
| `git_repo` | Most elements |
| `git_module` | A dependency vendors its own deps as git submodules (`.gitmodules`). Use this for each submodule path — `git_repo` + a manual `directory:` checks the submodule out but does **not** register it with `bst source track`, so `bst source track` silently stops updating that submodule while the parent ref keeps tracking (the update-path-gate blind spot AGENTS.md calls out for `tar`/`remote` also applies here). See zirconium-hawaii's gamescope element for the fix. |
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

### `ldconfig -r <root>` in the BST sandbox needs a build-only config file

`/etc/ld.so.conf.d/*.conf` entries are worthless unless `image.bst`'s `ldconfig -r /layer`
actually reads them, and the obvious invocations do not. `image.bst` carried this bug from
the day the call was added: `00_mesa.conf` and `codecs-extra.conf` were both present in the
image and both absent from `/etc/ld.so.cache`, so `config/codecs-extra-ldconfig.bst` had
never once worked. Two glibc behaviours combine (`elf/ldconfig.c`):

1. **`-r` is only "virtual" when the real `chroot()` fails.** `main()` tries
   `chroot(opt_chroot)` first and, on success, sets `opt_chroot = NULL` — every later path
   is then plain. The unprivileged BST sandbox has no `CAP_SYS_CHROOT`, so the call fails
   and `opt_chroot` stays set, meaning **every** path — including `-f` — is run through
   `chroot_canon()`. `-f /layer/etc/ld.so.conf` therefore resolves to
   `/layer/layer/etc/ld.so.conf`, misses, and `parse_conf` returns **silently**: exit 0,
   nothing on stderr, cache holding only the default trusted dirs. This is why testing the
   command in a privileged `podman run` is misleading — there `chroot()` succeeds and the
   same line works.
2. **With `opt_chroot` set, a relative `include` is fatal.** `parse_conf_include()` starts
   with `if (opt_chroot != NULL && pattern[0] != '/') error (EXIT_FAILURE, …)` →
   `need absolute file name for configuration file when using -r`. fdsdk's
   `/etc/ld.so.conf` ships `include ld.so.conf.d/*.conf`, i.e. relative — so both
   `-f /etc/ld.so.conf` and omitting `-f` (which defaults to the same file) hard-fail.

Working form — a build-only config carrying the absolute include, deleted afterwards so the
shipped `/etc/ld.so.conf` (correct for the unchrooted ldconfig on a booted system) is
untouched:

```bash
printf 'include /etc/ld.so.conf.d/*.conf\n' > /layer/etc/ld.so.conf.build
ldconfig -r /layer -f /etc/ld.so.conf.build
rm /layer/etc/ld.so.conf.build
```

The standard search paths are always added on top (`add_system_dir (SLIBDIR/LIBDIR)` runs
unconditionally after `parse_conf`), so nothing is lost by not reading the shipped file.

Verify on the built image, never on the build succeeding — failure mode 1 is invisible:

```bash
podman run --rm --entrypoint= localhost/krytis:latest \
  sh -c 'ldconfig -p | grep -c GL/default'   # must be non-zero
```

To experiment with ldconfig under the same constraints the assembly script has, use
`mise run bst shell --build oci/krytis/image.bst -- sh -c '…'` — a privileged container is
not a valid stand-in.

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

## `install -Dm###` modes are clamped to 644/755

BuildStream's artifact storage only tracks two regular-file modes, like a git tree object: executable (755) or not (644). `install -Dm440`, `-Dm600`, etc. in `install-commands` are accepted without error but silently clamped to `0644` by the time the file lands in the artifact/image — there's no error or warning at build time. Verify actual perms with `bst artifact checkout --tar <element> --tar out.tar && tar tvf out.tar`; a plain `bst artifact checkout --directory` may also normalize/mangle modes on non-root checkout, so prefer `--tar` when checking this specifically.

If a stricter mode is a hard requirement (not just convention), it needs a boot-time `tmpfiles.d` `z` line (`z /path 0440 root root -`) to fix it up post-checkout — same category of workaround as the `setcap`-at-boot pattern above. Before reaching for that, check whether the looser mode is actually a functional problem: e.g. sudoers.d files at 0644 (vs. the conventional 0440) still load and are honored by both GNU sudo and sudo-rs — they only refuse world-*writable* includes, not world-readable ones (confirmed against sudo-rs's own compliance test suite, `sudo/sudoers/includedir.rs`, `ignores_and_warns_about_file_with_bad_perms`). Root-owned + non-writable is enough; readability weaker than 0440 may just be a minor hardening gap, not a break — evaluate before adding boot-time complexity for it.

## Overriding a Single freedesktop-sdk Component Element

`elements/freedesktop-sdk.bst`'s `config.overrides:` map (a junction-level mechanism) lets krytis substitute one specific upstream element for a local one, project-wide — every dependency reference to that path, from any element, gets transparently redirected, without needing to touch the depending elements themselves. Two existing precedents: `components/sudo.bst: core/sudo-rs.bst` (full reimplementation) and `components/systemd.bst: gnome-build-meta.bst:core-deps/systemd.bst` (redirect to a different upstream project's already-patched version).

**When freedesktop-sdk's own element has a real bug** (not just "we want different software") and gnome-build-meta already carries an upstream patch for it but doesn't expose the *result* as a referenceable override element (gnome-build-meta's patches are applied to its own internal freedesktop-sdk checkout during its own CI, not published as a standalone element krytis's junction can point at) — the fix is a **local duplicate-with-one-change** element:

1. Copy the upstream `.bst` file verbatim into `elements/core/<name>.bst` (or wherever fits).
2. Prefix every `depends:`/`build-depends:`/`runtime-depends:` entry that referenced a sibling freedesktop-sdk element with `freedesktop-sdk.bst:` (they're no longer in that project's namespace).
3. Drop any conditionals keyed on junction-internal option variables (e.g. `target_arch`, set via `freedesktop-sdk.bst`'s own `config.options:` block) that don't apply to krytis's own build — they'll fail with `'target_arch' is undefined` since that variable doesn't exist outside the junction's option-resolution scope.
4. Add the fixed value/behavior.
5. Wire it in: `components/<name>.bst: core/<name>.bst` under `elements/freedesktop-sdk.bst`'s `overrides:`.

Verify the override actually resolves (not silently ignored) with `mise bst show freedesktop-sdk.bst:components/<name>.bst` — the dependency graph should list `core/<name>.bst`, not the upstream one, and it should show as `fetch needed`/uncached the first time.

**Concrete case: openssh's missing `sysconfdir`.** freedesktop-sdk's `components/openssh.bst` never sets `sysconfdir` (autotools defaults to `/etc`). *Every* compiled-in openssh path derives from that one variable, so `sshd_config`, `moduli` and the `ssh_host_*` keys all land directly in `/etc/` instead of `/etc/ssh/`. `sshd` still works — it looks exactly where it was built to look — so the damage is that `/etc/ssh/sshd_config` is silently ignored, `ssh-keygen -A` writes `/etc/ssh_host_*`, and anything expecting the standard layout (admins, backup tooling, config-management) is wrong. Confirm the paths are compile-time, not runtime, with `strings /usr/bin/sshd | grep -E '^/etc/(ssh/)?(sshd_config|moduli|ssh_host)'`. gnome-build-meta already has `patches/freedesktop-sdk/0003-openssh-Use-etc-ssh-as-sysconfdir.patch` for this, so the local duplicate-with-one-change element above is the way to get it.

> **Retracted claim.** This fix was first committed with the story that it repaired `kex_exchange_identification: read: Connection reset by peer` "under socket activation (`sshd@.service`)". Both halves were false: the image ships **no** `sshd.socket`/`sshd@.service` (only `sshd.service` with `ExecStart=/usr/bin/sshd -D`), and that reset was QEMU SLIRP `hostfwd` reporting a **closed guest port** — the real cause was the read-only `/etc` from #396 stopping `ssh-keygen -A`. Do not use "connection reset" as evidence for a config-path bug; see docs/skills/bootc-vm.md § `kex_exchange_identification: Connection reset` means nothing is listening.
>
> Separate gap found while retracting it, **fixed in #408**: neither `sshd_config` nor `ssh_config` had an `Include` line — not even a commented one — so `/etc/ssh/{sshd_config.d,ssh_config.d}` existed but was never read. Upstream OpenSSH ships no `Include`; Fedora, Debian and Arch each patch one in, and freedesktop-sdk ships systemd's drop-in *mechanism* (the tmpfiles symlinks) without it. Both systemd drop-ins were therefore dead weight: `sshd -T` reported `authorizedkeyscommand none`, and `ssh vsock/…`/`ssh machine/…` did not resolve because the ssh-proxy `ProxyCommand` never loaded.
>
> `core/openssh.bst` now **prepends** `Include %{sysconfdir}/{sshd,ssh}_config.d/*.conf` to both files. Prepending is load-bearing: OpenSSH keeps the **first** value obtained for most keywords, and the shipped `sshd_config` sets `AuthorizedKeysFile` further down, so an appended `Include` could never be overridden by a drop-in. `ssh_config`'s own header states the same rule ("host-specific definitions should be at the beginning"), and the systemd ssh-proxy drop-in is exactly such a set of `Host` blocks. Verify with `head -5 /etc/ssh/sshd_config` and `sshd -T | grep authorizedkeyscommand`.

**Gotcha while verifying this class of fix:** `mise lint` alone (per its own `#MISE description`) assumes `mise run load-image` already ran — it just does `podman build` against the *existing* `localhost/krytis-input:latest` tag. If that tag predates your element change, `mise lint` will pass while still testing the *old* content, silently. Use `mise run build [--force]` (which chains `generate-image-version` → `load-image` → `lint`) to force a real `oci/krytis/image.bst` rebuild before trusting lint output for an element-level change — `mise bst build <element>` in isolation only proves the element itself builds, not that the full image picked it up.

### Mirroring a junction element to patch its *source*

The duplicate-with-one-change recipe above also covers the case where the upstream element is correct but the release it pins needs a patch that isn't in that release yet — e.g. `#417`, where systemd v260.2 fails `systemd-update-utmp.service` on every boot and the fix (`b8968c49`) only landed after the tag. `elements/overrides/systemd-base.bst` + `patches/systemd/update-utmp-shorten-comm.patch` is the worked example.

**Don't try to avoid copying the body with a cross-junction include.** `(@): gnome-build-meta.bst:elements/core-deps/systemd-base.bst` plus a `sources: (>):` patch entry looks like the DRY version, but an element used as an *override target* for a junction cannot include a file from that same junction — the junction's declaration would have to be resolved to load the element that the declaration points at. BuildStream documents this as circular ("files included across a junction cannot be used to inform the declaration of a junction element"), and the failure is opaque: the include is silently not composited and you get

```
overrides/systemd-base.bst [line 15 column 0]: Dictionary did not contain expected key 'kind'
```

pointing at the `(@)` line itself. Copy the body.

**Override at the freedesktop-sdk junction even when the element lives in gnome-build-meta.** `components/systemd-base.bst` is already redirected to `gnome-build-meta.bst:core-deps/systemd-base.bst`; repoint that one entry at the local mirror instead of adding an override to `elements/gnome-build-meta.bst`. gnome-build-meta's own `core-deps/systemd.bst` and `core-deps/systemd-libs.bst` are `kind: filter` elements over `freedesktop-sdk.bst:components/systemd-base.bst`, and gnome-build-meta resolves that through *krytis's* fdsdk junction (`overrides: freedesktop-sdk.bst: freedesktop-sdk.bst`), so a single entry redirects the whole graph. Verify:

```shell
mise bst show --deps all --format '%{name}' stacks/base-system.bst | grep systemd
# overrides/systemd-base.bst          ← ours
# gnome-build-meta.bst:core-deps/systemd.bst, …/systemd-libs.bst   ← filters, unchanged
# (no gnome-build-meta.bst:core-deps/systemd-base.bst)
```

**Moving an element between projects moves its licence tree, which breaks whitelists.** `project_licensedir` is `%{licensedir}/%{project-name}` (fdsdk `include/install-dirs.yml`), so a mirror built in krytis harvests licences to `/usr/share/licenses/krytis/<name>/` instead of the upstream project's directory — gnome-build-meta's project name is `gnome`, not `gnome-build-meta`. That alone is a fatal build break whenever the mirrored element is filtered: gnome-build-meta's `core-deps/systemd.bst` and `core-deps/systemd-libs.bst` both carry the licence files and rely on an `overlap-whitelist` of `%{project_licensedir}/systemd/**`, expanded in *their* project's scope. At the moved path nothing matches, and every element that stages both filters dies with

```
/usr/share/licenses/krytis/systemd/LICENSE.GPL2: gnome-build-meta.bst:core-deps/systemd.bst is not permitted to overlap other elements …
[overlaps]: Non-whitelisted overlaps detected
```

reported against an innocent bystander (`components/polkit-base.bst` — the first element to stage both). Pin the variable in the mirror rather than chasing whitelists: `project_licensedir: "%{licensedir}/gnome"`. Keeping the artifact's layout identical to the element being mirrored is the general rule — the whole point of a mirror is that only the patched bits differ.

Note that `mise validate` and a standalone `mise bst build <element>` both pass with the licence tree at the wrong path: nothing stages two filters of the same element until the image graph is assembled, so this class of break only shows up in `mise run build`. Budget for a full image build before calling a junction mirror verified.

**A mirrored element rots silently.** It carries its own copy of upstream's `ref:` and build config, so a junction bump moves upstream while the mirror keeps building the old release — and, like `desktop/mesa-all-codecs.bst`, it is deliberately *not* in the `track-bst-sources.yml` matrix (its ref is tied to the junction, not tracked independently; running `bst source track` on it would actively break the mirror). Ship a drift check with it: `mise run systemd-base-check` fetches the junction-pinned upstream file at the SHA in `elements/gnome-build-meta.bst` and diffs it against the mirror, ignoring comments, blank lines and the added `kind: patch` source. Run it after every junction bump; there is no PR-triggered CI in this repo to run it for you.

**Patch hygiene:** patches live in `patches/<project>/`, and the file starts with a prose header naming the upstream SHA and why the backport exists (the `patch` source kind ignores everything before the first `diff`/`---` line). Confirm it applies to the pinned tag before building — much faster than discovering it in a build sandbox an hour in. **Every `kind: patch` source added or removed gets a row update in [issue #483](https://github.com/starlit-os/krytis/issues/483)'s inventory table, in the same PR** — that issue is the single place listing every patch krytis carries against a non-krytis-owned source, own bugfix or upstream backport alike, and it silently rots the moment a patch lands without a matching row.

```shell
mkdir -p /tmp/chk/src/update-utmp
curl -sS -o /tmp/chk/src/update-utmp/update-utmp.c \
  https://raw.githubusercontent.com/systemd/systemd/v260.2/src/update-utmp/update-utmp.c
patch -p1 --dry-run -d /tmp/chk < patches/systemd/update-utmp-shorten-comm.patch
```

Delete the mirror, its patch, the check task and the overrides entry as soon as the junction ships a release containing the fix — every one of these is a temporary hold on an upstream bug, not a permanent fork.

**Second worked example, mirroring the junction's *own* namespace instead of a cross-project one:** `elements/overrides/rust-bindgen.bst` + `patches/rust-bindgen/` (#498) mirrors freedesktop-sdk's own `components/rust-bindgen.bst` (not a gnome-build-meta redirect) to drop bindgen's unused `bindgen-tests/tests/quickchecking` workspace member and regenerate its `cargo2` vendoring, eliminating a `rand` 0.8.5 CVE the same way greetd dropped `agreety` (see "Dropping an unused workspace member" below) — except the vulnerable crate lives in an upstream-owned build tool, not a krytis-owned element, so the fix has to go through the mirror-and-override mechanism instead of a direct patch. **Gotcha specific to same-namespace mirrors:** step 2 of the duplicate-with-one-change recipe (prefixing sibling `components/*.bst` refs with `freedesktop-sdk.bst:`) means a naive drift check diffs every `depends:`/`build-depends:` line as "changed" even when nothing actually drifted — gnome-build-meta-sourced mirrors like `systemd-base.bst` don't hit this because gnome-build-meta's own elements already reference freedesktop-sdk components with the full `freedesktop-sdk.bst:` prefix (cross-project from the start). `mise run rust-bindgen-check` strips the prefix back off (`sed 's/freedesktop-sdk\.bst:components\//components\//'`) before diffing against the raw upstream file — copy that normalization step for any future same-namespace mirror.

## Adding a Package

1. Create `elements/desktop/<name>.bst` (or `elements/deps/`, `elements/config/`, etc. depending on what it is — copy a similar existing element)
2. Add `desktop/<name>.bst` (or matching path) to `depends:` in the relevant `elements/stacks/*.bst` aggregator (e.g. `desktop.bst`)
3. Add a URL alias to `include/aliases.yml` if the download domain is new
4. Run `mise validate` (validates the full element graph)
5. Run `mise bst build elements/desktop/<name>.bst`
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

### Survey the reverse-dep set before assuming a junction library is "already there"

A junction element is only free if something krytis already ships pulls it in. Presence in
`gnome-build-meta.bst` says nothing about presence in *our* graph. Check before you write
the `depends:` line, because a single prebuilt app can drag a multi-hour build into the image.

Worked example — `#550` (limux, closed unmerged): `grep -rn webkit elements/` was empty, and
none of the ~50 gnome-build-meta elements krytis consumes pulls `sdk/webkitgtk-6.0.bst`
transitively (its only reverse-deps there are `epiphany`, `gnome-builder`,
`gnome-initial-setup`, `evolution-data-server`, `foundry`, `yelp`,
`NetworkManager-openconnect`, `manuals`, `sdk-platform` — krytis depends on none of them).
One 19 MB prebuilt tarball would therefore have added WebKitGTK 2.52 to the image. Measured
on a 16-thread builder before the app was dropped: **1 h 30 m** of webkit compile, **13**
elements new to the graph, **+186.9 MiB** installed. Those are the standing numbers for
adding any WebKitGTK-linked app — reuse them instead of re-estimating
(`docs/plans/done/2026-08-09-add-limux-element.md`).

Recipe — set-difference the candidate's closure against the current image closure:

```bash
mise run bst show --deps all --format '%{name}' <junction>.bst:<path>.bst \
  | grep '\.bst' | sort -u > /tmp/cand.txt
mise run bst show --deps all --format '%{name}' oci/krytis/image.bst \
  | grep '\.bst' | sort -u > /tmp/image.txt
comm -23 /tmp/cand.txt /tmp/image.txt        # elements the image does not already have
```

Run the image side from a checkout that does **not** yet contain your new element, or the
diff comes back empty. Per `AGENTS.md`, this measures the *graph*, not a live system — a
static answer about what an installed image contains still needs `/usr/manifest.json`.

### Meson `find_program()` calling a tool by the wrong name

Some upstream meson projects call `find_program('<tool>')` expecting a specific CLI (e.g. Dart Sass's `sass`), but freedesktop-sdk/gnome-build-meta only vendor a different implementation of that tool under a different binary name with an incompatible CLI (e.g. `sassc`, the libsass C implementation — same *purpose*, different flags and positional-arg conventions). There's no BST-level program-name remapping for this.

Fix: add a tiny `kind: manual` element that installs a shim script under the expected binary name into `%{bindir}`, translating the call into the available tool's actual CLI, and list it under the consuming element's `build-depends:` (not `depends:` — it's a build-time-only tool, not part of the runtime image). See `elements/deps/sass-shim.bst` (adw-gtk3.bst's build-dep) for a worked example: it strips the one incompatible flag (`--no-source-map`, which is already sassc's default behavior) and execs `sassc "$@"`.

Keep the shim narrowly scoped to the one call site that needs it — don't generalize it into a "compat layer" for the tool in general; that's speculative work the actual usage doesn't need.

### Porting a whole element directory verbatim from a sibling project

A directory-wide `cp` of `elements/<upstream-dir>/*.bst` into a
differently-named local directory gets every **external** reference right —
krytis, zirconium-hawaii and dakota all use identical
`freedesktop-sdk.bst:`/`gnome-build-meta.bst:`/`deps/*.bst` paths — and every
**internal same-directory** reference wrong. `cp` does not know the directory
is being renamed, so a `build-depends: - sysext/jackrabbit/lib32.bst` inside
the copied `lib32-filter.bst` still names the *upstream* directory after
landing at `sysext/gaming/lib32-filter.bst`. It is still valid YAML pointing
at a path that does not exist locally.

After any multi-file port, grep the new directory for the **old** directory
name before trusting it:

```shell
grep -rn '<upstream-dir>' elements/<local-dir>/
```

**Then resolve the graph, don't just parse it.** `mise run validate` runs
`bst show --deps all`, which resolves sources and evaluates
`fatal-warnings:` — that is the cheapest check that catches a dangling element
reference or an `unaliased-url` in a ported `cargo2` block (see § Rust / Cargo
Projects). A YAML- or reference-only audit passes clean on both. If a port adds
a new top-level target that no existing stack pulls in, add it to
`mise/tasks/validate` so the cheap check actually covers it.

## Element Update Path

Every element must have a defined update path. **`bst source track` is a no-op on `kind: tar` and `kind: remote` sources** — these source kinds don't have a tracking ref BST can follow. Without an explicit update path the element silently drifts out of the automated update loop.

| Source kind | Update mechanism |
|---|---|
| `git_repo` with `track:` glob | Add a matrix entry to the `track` job in `.github/workflows/track-bst-sources.yml` |
| `kind: tar` / `kind: remote` (tarball-pinned) | Add a row to `TARGETS` in `mise/tasks/tarball-update` and the name to the `track-tarball` matrix. Write a bespoke `<name>-update` task only when the element genuinely does not fit a provider — `ghostty-update` (33 Zig deps) and `falcond-update` are the standing examples |

### One shared updater, not one script per element (#648)

`mise/tasks/tarball-update` covers nine elements through four providers, because they differ
only in where the version comes from and how the URL is spelled. `--list` prints the table;
`tarball-update all` walks every entry and is the audit run — it keeps going past a failing
upstream and reports at the end, since stopping at the first would hide the state of
everything after it.

Two things that bit while writing it, both worth knowing before adding a provider:

- **Use tags, not releases, for GitHub tag archives.** `repos/<repo>/releases/latest` 404s on
  projects that tag but never publish a Release. `greetd` is the case here — a sourcehut
  project whose GitHub side is a mirror.
- **Never bump a version with a blanket `sed s|$old|$new|g`.** PyPI renamed sdists from
  hyphens to underscores under PEP 625, so substituting `2.5.0` → `2.8.0` in
  `buildstream-plugins-2.5.0.tar.gz` produced a **404 URL carrying a correct sha256** — a
  dead link that no checksum check catches and that only surfaces on a cold fetch. Rewrite
  the whole `url:` line from what the upstream API actually returned, and take PyPI's hashed
  path verbatim rather than reconstructing one. A blanket substitution also rewrites any
  other occurrence of the version string in the element.

**Series-pinned elements need a constrained tracker, not the latest release.**
`desktop/zig-0.16.bst` exists because falcond declares `minimum_zig_version = "0.16.0"` while
ghostty is still on 0.15.2. Tracking "latest Zig" would silently move it to 0.17 and break
falcond, so its provider is `zig-series` with the series as the locator. Any element that is
pinned to a major/minor on purpose wants the same treatment — check *why* a version is pinned
before writing its updater.

### Auditing the whole tree for elements with no update path (#640)

The gate is per-PR, so it only catches elements as they are *added*. Nothing re-checks the
existing tree, and a `kind: tar` element with no task fails silently and permanently — the
symptom is not an error, it is the absence of update PRs, which nobody notices.
`desktop/libqalculate.bst` sat two releases stale that way and was only spotted because it
failed to build for an unrelated reason during the fdsdk 26.08 bump (#305).

Audit the whole tree instead of trusting the gate. The check is: an element is covered iff
some `mise/tasks/*` file references its path **and** the workflow runs that task.

```bash
# untrackable elements: a tar/remote source and no `track:` anywhere in the file
for f in $(grep -rlE '^\s*-?\s*kind:\s*(tar|remote)' elements/); do
    grep -qE '^\s*track:' "$f" || echo "$f"
done
```

Then, for each hit, grep `mise/tasks/` for the element path and
`.github/workflows/track-bst-sources.yml` for the task name.

**Match on the element path, not the task name.** Several updaters are not named after their
element and a name-based check reports them as false gaps: `core/linux-cachyos.bst` is updated
by `kernel-update`, and `desktop/zig.bst` by `ghostty-update` (which bumps Zig when ghostty's
`minimum_zig_version` moves). A naive name match over-reported 12 gaps where there were 9.

### An auto-track `ref:` bump never builds the element — upstream dep additions land broken

The `track` job in `track-bst-sources.yml` runs `bst source track` and opens a PR with the new
`ref:`. It does **not** build the element. So when an upstream release adds a new
`dependency()` to its `meson.build`/`CMakeLists.txt`, the bump merges green and `mise build`
is broken on `main` from that moment — for *every* branch, since `mise lint` and
`mise boot-test` both go through a full build. #400 (`noctalia-greeter` v1.0.0 → v1.1.0) and
#401 (`noctalia` → v5.0.0-beta.7) did exactly this, costing three new deps across two
elements (#412).

**When reviewing or merging an auto-track PR on a source-built element, diff the upstream
build file, not just the ref.** One command answers it:

```bash
curl -sL https://raw.githubusercontent.com/<owner>/<repo>/<new-tag>/meson.build \
  | grep -nE "dependency\(|has_header\(|find_program\("
```

Compare that list against the element's `build-depends`/`depends`. Iterating one
`bst build` failure at a time costs ~12 minutes per round trip on a warm cache, because meson
aborts at the *first* missing dependency — reading the upstream build file finds all of them
at once. Beware the non-`dependency()` forms: noctalia-greeter v1.1.0 also gained a bare
`cc.has_header('stb/stb_image_resize2.h')` check, which no `dependency(` grep would surface.

Deps satisfied transitively do not need declaring — `libinput`, `egl`, `glesv2` and
`wayland-server` all resolve for noctalia-greeter through `desktop/wlroots.bst`,
`extensions/mesa/mesa.bst` and `components/wayland.bst`. Only genuinely new top-level
dependencies need an entry. Placement follows § C library deps and Mesa: a shared library
goes in `depends:` (BST stages `depends` at build time too, so headers and `.pc` files are
there), a genuinely header-only package goes in `build-depends:`. Verify which it is rather
than guessing — fdsdk builds `tomlplusplus` as `libtomlplusplus.so.3`, so it is a `depends:`
despite the upstream project being header-only by default.

### The track job's PR title/version comes from parsing the git-describe `ref:`

`git_repo` refs are git-describe strings — `v5.0.0-beta.6-0-g<sha40>` — and the `track`
job derives both the PR title (`… v5.0.0-beta.6 -> v5.0.0-beta.7`) and the **Version** row
of the body by string-slicing that ref. There is no separate version field to read, so the
parse has to be anchored on the describe suffix, not on what a version "looks like":

```bash
# strips "-<offset>-g<sha>"; empty for plain-SHA refs so the row is omitted
printf '%s\n' "$REF" | grep -oP '^.+(?=-\d+-g[0-9a-f]{7,40}$)' | grep -P '\d'
```

A "digits, dots and dashes" pattern (`^v?\d+[\d\.\-]+`) looks equivalent and is not — it
stops at the first letter, so every pre-release tag collapses to its base version
(`v5.0.0-beta.6` → `v5.0.0`, giving useless `v5.0.0 -> v5.0.0` titles), and it keeps the
describe offset on stable tags (`v1.15.2-0`). Both symptoms shipped in real PRs
(starlit-os/krytis#401).

Two constraints on any change here:

- **Plain-SHA refs must yield an empty version.** Branch-tracked elements with no reachable
  tag (`desktop/stb.bst`, `track: refs/heads/master`) get a bare 40-char SHA as their ref;
  matching them would print a SHA in the Version row and in the PR title.
- **Diff-marker greps must bracket the marker** (`grep '^[+].*ref:'`, not `'^+.*ref:'`).
  A bare `+` after `^` is a literal plus only in GNU BRE; uutils-style greps read it as a
  quantifier on `^` and match *every* diff line, so `NEW_REF` silently picks up the old ref
  too. GitHub runners ship GNU grep, so this only bites when reproducing the step locally.

### Verify a track: glob only matches the intended release channel

A `track:` glob that's too loose, or that names a branch instead of a tag pattern, silently
drifts an element onto untagged/edge commits — `bst source track` succeeds either way, so
nothing flags the mistake at build time. zirconium-hawaii hit this on `linux-ogc.bst`:
`track: "ogc-*"` also matched pre-release tags from the same project, and a second source
in the same element used `track: "main"` (a branch) when it meant to follow tags. Both
were corrected to `track: "v*-ogc*"`, which matches only the intended stable-release tag
shape. When adding or reviewing a `track:` glob, check it against the upstream's actual tag
list (`git ls-remote --tags <url>`) rather than assuming the glob is selective enough, and
never point `track:` at a branch name when tag-pinned stability is the goal.

### Commit-pinned archive checksums can drift even though the commit is immutable — verify via `git clone`, don't blind-repin

A `kind: tar`/`kind: remote` source pinned to a git-forge-generated `/archive/<sha>.tar.gz`
URL (GitHub, Gitea, Codeberg) can start failing its `ref:` sha256 check even when the URL's
commit SHA has never changed and the upstream repo hasn't force-pushed anything. The forge
regenerates that tarball on every request rather than serving an immutable blob, and can
change the resulting bytes (gzip compression level/metadata, archive format version) across
a server upgrade — the commit's actual tree contents are unaffected. Hit on `falcond.bst`'s
`translate-c` zig-dep and `game-devices-udev.bst`'s source, both pinned to Codeberg commit
archives, both failing with a `ref:` mismatch against a checksum that had built cleanly for
months.

**Don't just re-run `sha256sum` on the new download and re-pin it — that only proves the
download is reproducible right now, not that its contents match what the commit SHA is
supposed to contain** (a compromised or mis-configured forge could serve different content
for the same nominal ref). Verify independently instead: clone the repo, checkout the exact
pinned commit SHA, extract the downloaded tarball, and diff the trees:

```bash
git clone <repo-url> check && cd check && git checkout <pinned-sha>
mkdir ../extracted && tar xzf <downloaded>.tar.gz -C ../extracted --strip-components=1
diff -rq . ../extracted --exclude=.git
```

Empty diff confirms it's pure archive-regeneration drift (safe to re-pin `ref:` to the new
sha256) rather than a supply-chain integrity problem (stop and investigate/escalate if the
trees don't match). This is a repin-only fix — no `track:`/update-path change needed, since
the commit SHA in the URL is unchanged.

### tar → git_repo switch when releases appear

A `kind: tar` element pinned to a commit SHA (because the upstream had no release
tags) should be switched to `kind: git_repo` with `track: v*` once the upstream
starts tagging releases. This moves the element from option B (mise task + CI job)
to option A (matrix entry only) and closes the silent-drift gap — `bst source track`
becomes a no-op on `tar`, so tarball-pinned elements without a mise task drift until
someone manually bumps them. The noctalia and noctalia-greeter elements were 99 and 5
commits behind respectively when this was discovered.

The switch is mechanical: replace the `tar` source with a `git_repo` source using
`url: github:<org>/<repo>.git`, `track: v*`, and a git-describe `ref:` (e.g.
`v1.0.0-0-g<sha>`). Add a matrix entry to the `track` job. Delete any stale mise
task if one existed. Drop the "no release tags exist" / "archive regenerates on
every push" comments — they're no longer true.

**The source stanza is mechanical; the dependency surface is not.** A re-pin that
jumps many commits (noctalia: 99) can change what the upstream build requires.
Before building, diff the upstream build file between old and new refs:

```shell
gh api repos/<org>/<repo>/contents/meson.build?ref=<old-sha> --jq .content | base64 -d > old.build
gh api repos/<org>/<repo>/contents/meson.build?ref=<new-sha> --jq .content | base64 -d > new.build
PAT="dependency\('[^']+'|has_header\('[^']+'|find_library\('[^']+'"
diff <(grep -oP "$PAT" old.build | sort -u) <(grep -oP "$PAT" new.build | sort -u)
```

Two failure shapes, only the first of which the textual diff catches:
- **New `dependency()` calls** — e.g. noctalia v5.0.0-beta2 added `nlohmann_json`
  and `has_header('stb/...')` checks.
- **Un-vendoring** — the call already existed at the old ref but was gated behind a
  `system_*` option with a vendored `third_party/` fallback; the new ref makes it
  unconditional. noctalia did this to `md4c` and `tomlplusplus`. Grep the old build
  file for the "new" dep name before concluding it's new — if it's there under an
  `if get_option(...)` branch, the upstream un-vendored it.

Also expect meson to report missing deps **one at a time** (it stops at the first
failure) — resolve the full list from the diff up front instead of iterating builds.

To check whether a junction already ships a component, probe directly (a miss names
the junction, a hit echoes the element):

```shell
bst show --format '%{name}' freedesktop-sdk.bst:components/<name>.bst
```

fdsdk ships `components/nlohmann-json.bst` and `components/tomlplusplus.bst`;
neither junction ships md4c or stb (in-repo `desktop/md4c.bst`, `desktop/stb.bst`).

**Finding a component does not tell you `build-depends` vs `depends`.** Don't infer
that from whether the upstream project is "usually" header-only — check what the
*junction's element* actually built:

```shell
bst artifact list-contents freedesktop-sdk.bst:components/<name>.bst | grep '\.so'
```

toml++ is header-only by upstream design, but fdsdk's `tomlplusplus.bst` builds it
as `libtomlplusplus.so.3` anyway. Classifying it as `build-depends` (like the
genuinely header-only `nlohmann-json`) builds and links fine — the `.so` is in the
sandbox at link time — and only breaks at runtime, once the image is composed:
`error while loading shared libraries: lib<name>.so.N`, because `build-depends`
never enters the final image's runtime closure. Verifying against the standalone
element's own artifact checkout will not catch this either — it has no `depends`
closure staged, so every runtime dependency looks "not found" whether or not the
graph is actually correct. The only check that reflects reality is `ldd` against
the composed `oci/krytis/filesystem.bst` checkout.

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

### Temporary fork pins for tarball-pinned elements

When a `kind: tar` element needs a fix that isn't upstream yet, point the source at a fork branch's archive tarball instead of waiting on a PR merge — same `github_files:<owner>/<repo>/archive/<sha>.tar.gz` shape, just a different owner:

```yaml
# TEMPORARY FORK PIN — <fork-owner>/<repo> branch <branch-name>, carrying a
# fix for <symptom>. File upstream once confirmed fixed on real hardware,
# then revert this pin to <upstream-owner>/<repo> once merged there.
sources:
- kind: tar
  url: github_files:<fork-owner>/<repo>/archive/<full-commit-sha>.tar.gz
  ref: <sha256-of-tarball>
```

Put the "why forked / what to revert to" context **in the element's own comment**, not just the commit message — a future agent bumping this element via `git blame` or a routine update task needs to see the deviation without digging through PR history. Compute the tarball's sha256 the same way as any other tar-pinned bump: `curl -sSfL <url> -o /tmp/x.tar.gz && sha256sum /tmp/x.tar.gz`.

**Rooting the fork branch: prefer the fork's latest upstream `main` once any new dep gap is confirmed satisfiable, not reflexively the old pinned commit.** A fork branch rooted on stale main avoids upstream drift short-term, but it accumulates as a second thing to unwind later (rebase forward *and* revert the fork pin, instead of just reverting the pin). If rebasing onto latest main produces a meson/pkg-config dependency error, don't assume krytis genuinely lacks that dependency — check whether it's already available elsewhere in the dep graph (`grep -rn <pkg-name> elements/`) first. freedesktop-sdk components pulled in by a sibling stack element (e.g. `stacks/desktop.bst`) aren't automatically visible to *this* element's build sandbox; BST elements only see their own explicit `depends:`/`build-depends:`. Often the real fix is just adding the already-pinned freedesktop-sdk component to this element's own `depends:` list, not a broader krytis-wide version upgrade — cheaper than carrying the stale-base workaround forward.

**Squash trial-and-error into one clean commit before pinning.** If arriving at the fix took an abandoned or insufficient-alone intermediate attempt (e.g. a narrower mitigation that turned out not to fix the root cause on its own), don't cherry-pick/rebase the whole exploratory commit sequence into the fork branch you pin krytis to. Diff the final working tree against the fix's pre-attempt base (`git diff <before-sha> <final-sha> -- <path>`), apply that as one patch on the clean rebase target, and commit once with a message describing the actual mechanism of the final fix — not the narrative of what didn't work first. Verify the squashed tree is byte-identical to the original multi-commit tip (`git diff <old-tip> <new-branch> -- <path>` should be empty) before trusting it. Keeps the eventual upstream PR (and krytis's pin history) reviewable as "here's the fix," not "here's how we got here."

This is a stopgap, not a new steady state — track reverting to the upstream owner/commit once the fork's fix lands upstream (open the upstream issue/PR only once the fork branch is confirmed working, so the report includes verified evidence).

**Retiring the pin: don't assume a rebase check is the right test.** Before mechanically rebasing the fork branch onto the latest upstream `main`, diff upstream's own commits since the fork point against the fix's target file (`git log <fork-point>..upstream/main -- <path>`) — an unrelated upstream refactor can independently reimplement the same fix (e.g. an async-dispatch rewrite that happens to cover the exact call our fork made async), which makes the fork moot even if a literal rebase would conflict. Conversely, absence of conflict doesn't mean the fork is still needed either way — check the semantics, not just whether `git rebase` exits clean. If upstream's reimplementation drops a detail the fork fix depended on (e.g. our fork used an explicit 120s `withTimeout` for a slow polkit prompt, upstream's version left the sdbus-c++ default ~25s), note that gap in the re-pin comment instead of silently dropping it — it may resurface as a narrower version of the same bug.

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

### Vendor apt/yum repos as a pinnable prebuilt-binary source (e.g. Warp)

Before concluding "no pinnable binary exists, must build from source": check whether the vendor runs their own apt/yum repo, not just GitHub Releases or a client-rendered `/download` redirect page. Warp (`warpdotdev/warp` — closes #315) was initially assessed as source-only because:

- GitHub Releases ship source tarballs only (`assets: []`).
- `app.warp.dev/get_warp?package=deb` returns `200` HTML with no static `Location` header — not pinnable.

Both true, but irrelevant — Warp publishes its own apt repo at `https://releases.warp.dev/linux/deb/dists/stable/main/binary-{amd64,arm64}/Packages`, a plain-text RFC822 Packages index with versioned `Filename`, `Size`, and `SHA256` per package, refreshed on every stable release. **Always check for a vendor-run apt/yum repo before accepting a from-source build as the only option** — search `releases.<vendor>.dev`, `apt.<vendor>.com`, `<vendor>.com/linux/{deb,rpm}`, or grep the vendor's own install docs for `add-apt-repository` / `.repo` file instructions.

- **`Filename` in a Packages/Release file is root-relative, not directory-relative.** The apt client resolves it against the repo root configured in `sources.list` (here `linux/deb/`), not against the `dists/stable/main/binary-amd64/` path the Packages file itself lives at. Warp's `Filename: ../../stable/vX.Y.stable_NN/pkg_amd64.deb` resolves to `https://releases.warp.dev/stable/vX.Y.stable_NN/pkg_amd64.deb` (two `../` cancel `linux/deb/` entirely) — **not** `.../linux/deb/dists/stable/stable/...` as naive relative-path math from the Packages file's own directory would suggest. Verify by fetching the resolved URL before hand-deriving a mise update task's URL construction.
- **`postinst` symlinks are not present in `data.tar.xz`.** Some `.deb`s (Warp included) rely on `postinst` to create `/usr/bin/<name>` pointing at a binary installed elsewhere (e.g. `/opt/vendor/app/bin`), rather than shipping the symlink in the tarball itself. BST never runs maintainer scripts. Check `control.tar.xz`'s `postinst`/`postrm` for `ln -s` before assuming `cp -a usr "%{install-root}/"` alone gives you a working `$PATH` entry — recreate the symlink manually in `install-commands` if so, mirroring exactly what `postinst` does (source path, target path, symlink vs hardlink).
- **`ar` isn't guaranteed in ad-hoc investigation shells** — only in the BST build sandbox (`freedesktop-sdk.bst:components/binutils.bst`). If parsing a `.deb`'s ar-archive layout outside BST (e.g. to inspect `postinst` before writing the element), the `ar` format is trivial to hand-parse: `!<arch>\n` magic, then repeating 60-byte member headers (name at offset 0 len 16, size as ASCII decimal at offset 48 len 10), member data padded to an even byte boundary.

### Bundled-app tarballs with RPATH structure (e.g. Zed)

Some apps ship a self-contained tarball (`app.tar.gz → app.app/`) with an internal layout that encodes RPATH. For example, Zed's `bin/zed` has `RPATH: $ORIGIN/../lib` — it expects bundled `.so` files at `../lib` relative to the binary. If you install `bin/zed` to `/usr/bin/zed`, `$ORIGIN/../lib` resolves to `/usr/lib/`, which is the **system** lib directory, not the bundled libs.

**Fix:** install the app to a private directory (`/usr/lib/<app>/`) that preserves the relative structure, then symlink the launcher:

```yaml
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -d "%{install-root}/usr/lib/zed"
    cp -a bin libexec lib "%{install-root}/usr/lib/zed/"
    install -d "%{install-root}/usr/bin"
    ln -s /usr/lib/zed/bin/zed "%{install-root}/usr/bin/zed"
    cp -a share "%{install-root}/usr/"

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:zed-industries/zed/releases/download/vVER/zed-linux-x86_64.tar.gz
      ref: <sha256>
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/vVER/zed-linux-aarch64.tar.gz
      ref: <sha256>
```

- BST strips the single top-level dir (`zed.app/`) so `bin/`, `libexec/`, `lib/`, `share/` are at the staging root.
- `cp -a bin libexec lib` copies the entire internal app tree — preserving the `bin/→../lib` relationship.
- `cp -a share "%{install-root}/usr/"` installs icons/`.desktop` files to the standard XDG paths.
- `strip-binaries: ''` and `strip-commands: [':']` required — pre-built ELFs must not be stripped.
- Check RPATH with `readelf -d <binary> | grep RPATH` before deciding on the install layout.

### Electron self-updaters on a read-only image — pick the artifact, not a patch

*Source: `elements/desktop/equibop.bst` (#609).*

Every `electron-builder` app that depends on `electron-updater` ships a live self-updater,
and on a bootc image every install path it knows is wrong. **Which** updater it instantiates
is decided by one file in the payload, so the artifact you choose settles the problem before
it exists. From `electron-updater/out/main.js`:

```js
_autoUpdater = new AppImageUpdater()
const identity = path.join(process.resourcesPath, "package-type")
if (!existsSync(identity)) return _autoUpdater      // ← nothing else runs
switch (readFileSync(identity).toString().trim()) {
  case "deb": _autoUpdater = new DebUpdater(); break
  case "rpm": _autoUpdater = new RpmUpdater(); break
  case "pacman": _autoUpdater = new PacmanUpdater(); break
}
```

- The **`.deb`/`.rpm` artifacts write `resources/package-type`**, selecting `DebUpdater` /
  `RpmUpdater`. Those are fully active: they poll GitHub on launch, prompt, download the
  package (~190 MB for Equibop), then fail in `doInstall` on `hasCommand("dpkg")` /
  `hasCommand("apt")` — neither exists here. The user sees this on every upstream release.
- The **portable `tar.gz` ships no `package-type`**, so it falls through to
  `AppImageUpdater`, whose `isUpdaterActive()` returns `false` when `$APPIMAGE` is unset.
  `AppUpdater.checkForUpdates()` short-circuits to `null`: no request, no prompt, nothing to
  fail. This is the Electron equivalent of `zen-browser.bst`'s `DisableAppUpdate` policy.
- **Verify at runtime, one command, no display needed:**
  `env -u WAYLAND_DISPLAY -u DISPLAY HOME=$(mktemp -d) ./equibop` prints
  `APPIMAGE env is not defined, current application is not an AppImage` — that is
  electron-updater's own `isUpdaterActive()` log, and its presence *is* the proof the
  updater is off. Reading the source is not enough; check for this line. If it is missing
  and the app instead fetches `latest-linux.yml`, the updater is armed.

So **prefer the portable tarball over the `.deb` for any `electron-updater` app**, and check
`resources/package-type` in the payload before assuming otherwise. Don't reach for the
`.deb` because it looks better integrated — see the cost table below. Deleting
`resources/package-type` in `install-commands` reaches the same end state, but it is a
hand-maintained deletion that fails *silently* if a version bump drops it.

Do not assume the app guards the updater behind a setting or an env var: Equibop's
`src/main/startup.ts` begins `import "./updater"`, and `updater.ts` calls
`autoUpdater.checkForUpdates()` at module load. There is nothing to switch off.

**What the `.deb` actually buys you, for an app whose two artifacts are byte-identical**
(verify: compare `app.asar`, the main binary and any sidecars by size/md5 across both):

| | `.deb` | portable `tar.gz` |
|---|---|---|
| updater | armed and broken | inert by construction |
| build-deps | `binutils` (`ar`) + `tar` | none beyond `runtime-minimal` |
| relocation | payload under `/opt/<App>/`, dead on bootc — must move | strips to staging root |
| `/usr/bin` entry | `postinst` only, never in `data.tar.xz` — recreate by hand | hand-written either way |
| `.desktop` | shipped, but `Exec=/opt/…` — **unusable as-is** | absent |
| icon | shipped | absent |

The `.desktop` line is the one that decides it: rewriting `Exec=` needs `sed`, which
`runtime-minimal` does not have (§ Prebuilt Binary Elements), so you hand-author the entry
under either artifact and the `.deb`'s only remaining gift is the icon file.

**Getting the icon without the `.deb`:** take upstream's own source icon as a second
`kind: remote` source, pinned at a **commit**, not at the release tag — then version bumps
leave it alone:

```yaml
sources:
# directory: bundle keeps the app tree out of the staging root so the icon can
# sit beside it and `cp -a bundle/.` stays version-proof.
- kind: tar
  directory: bundle
  url: github_files:Equicord/Equibop/releases/download/vVER/equibop-VER.tar.gz
  ref: <sha256>
- kind: remote
  filename: equibop.svg
  url: github_raw:Equicord/Equibop/<commit-sha>/build/icon.svg
  ref: <sha256>
```

- `github_raw` (`https://raw.githubusercontent.com/`) exists in `include/aliases.yml` for
  exactly this. `github_files` reaches raw blobs only via a redirect — pin the real host.
- Equibop's `build/icon.svg` is byte-identical to the SVG `electron-builder` generates into
  the `.deb`, so nothing is lost. Check this before assuming the source icon is equivalent.
- A commit pin can silently go stale when upstream redraws the icon. Have the update task
  compare the tag's `build/icon.svg` hash against the pinned `ref` and warn — see
  `mise/tasks/equibop-update`.
- Upstream's `linux.desktop.entry` block in `package.json` is the authoritative source for
  the hand-written `.desktop` (it is richer than the generated one — Equibop's `.deb` entry
  loses `Categories=…;InstantMessaging;Chat;`).

**`chrome-sandbox` needs no setuid here.** It ships `0755`; upstream's `postinst` chmods it
`4755` *only* when user namespaces are unavailable. krytis re-enables
`kernel.unprivileged_userns_clone` (`files/desktop-tweaks/sysctl.d/99-userns.conf`), so
Chromium takes the namespace sandbox. Do not add setuid handling for an Electron app.

**Runtime deps: read the ELF, then add back the dlopens.** `readelf -d <app-binary>` gives
the direct set (for Equibop: gtk3, nss, at-spi2-core, libxkbcommon, alsa-lib, cups, dbus,
systemd/libudev — plus `RPATH: $ORIGIN`, which is what forces the private-directory layout
above). It will *not* show `libsecret` (`safeStorage`), `libnotify`, `pipewire`
(screen share, `@vencord/venmic`), `libXtst`/`libXss`. Cross-check against the `.deb`'s
`control` `Depends:` line even when shipping the tarball — that list is free metadata and
catches the dlopened libraries. `libgbm.so.1` is the exception: leave it undeclared, since
`freedesktop-sdk.bst:vm/mesa-default.bst` in `stacks/desktop.bst` installs the
`ld.so.conf.d` entry that resolves mesa image-wide.

### A prebuilt binary's RUNPATH into `/usr/local` is dead on bootc

Same trap as `/opt` below, reached through `RUNPATH` instead of through payload paths.
bootc's `/usr/lib/tmpfiles.d/10-bootc.conf` makes `/usr/local` a symlink to `/var/usrlocal`
— runtime state, empty on every fresh boot — so a baked `RUNPATH: /usr/local/lib/<app>`
can never resolve in a krytis image. The binary builds, composes, and lints cleanly; it
fails at exec time with a missing `.so`.

Upstream installers that default to `--prefix=/usr/local` bake this in routinely. limux
(`#550`, investigated then dropped) is the worked example: both `/usr/bin/limux` and
`/usr/libexec/limux/limux-host` carried `RUNPATH: /usr/local/lib/limux` for their bundled
`libghostty.so`, and `ldd` reported `libghostty.so => not found` in the built image.

Fix pattern — private libdir plus an `ld.so.conf.d` entry, **not** a dump into the shared
`%{libdir}` (a vendored 29 MB `.so` does not belong on every binary's default search path):

```yaml
# elements/desktop/<app>.bst
- install -Dm755 lib/lib<x>.so "%{install-root}%{indep-libdir}/<app>/lib<x>.so"

# elements/config/<app>-ldconfig.bst — mirrors config/codecs-extra-ldconfig.bst
- |
  install -Dm644 /dev/stdin \
      "%{install-root}/etc/ld.so.conf.d/<app>.conf" <<'EOF'
  %{indep-libdir}/<app>
  EOF
```

`oci/krytis/image.bst` already runs `ldconfig -r /layer -f /layer/etc/ld.so.conf` at assembly
time, so the cache is baked into the image and nothing runs at boot. Existing instance:
`config/codecs-extra-ldconfig.bst`.

Always `readelf -d <payload> | grep -E 'RPATH|RUNPATH|NEEDED'` before writing the element —
a plausible-looking RUNPATH is not a working one.

### Never install payload content under `/opt` — it's silently discarded

bootc's `/usr/lib/tmpfiles.d/10-bootc.conf` makes `/opt` a symlink to `/var/opt` (the traditional ostree convention: `/usr/local -> /var/usrlocal`, `/opt -> /var/opt`), and `/var` is runtime state, not part of the immutable composefs image — it's empty on every fresh boot. A `.bst` element that does `cp -a opt "%{install-root}/"` builds and composes cleanly, and the license-harvest step even preserves a copy of the tree under `/usr/share/licenses/krytis/<element>/opt/...` (making it look installed at a glance) — but the actual payload never reaches the booted rootfs. `/usr/bin/<app>` ends up a symlink pointing at a target under `/opt/...` that doesn't exist. This is invisible until you actually run the binary; `bst build` and `mise lint` don't catch it.

Some `.deb`s (e.g. Warp — see § Vendor apt/yum repos above) ship their payload under `opt/<vendor>/<app>/` because that's the Debian FHS convention for vendor-bundled apps. Don't `cp -a opt` verbatim — relocate to `%{indep-libdir}/<app>/` (`/usr/lib/<app>/`) instead, same as the Zed pattern above:

```yaml
install-commands:
- install -d "%{install-root}%{indep-libdir}/<app>"
- cp -a opt/<vendor>/<app>/. "%{install-root}%{indep-libdir}/<app>/"
- cp -a usr "%{install-root}/"   # usr/ is fine — it's part of the image
- install -d "%{install-root}%{bindir}"
- ln -s "%{indep-libdir}/<app>/<binary>" "%{install-root}%{bindir}/<app>"
```

Before relocating, verify the binary doesn't hardcode the `/opt/...` path: `readelf -d <binary> | grep -i rpath` (should be empty for a self-relative app) and `strings <binary> | grep '/opt/<vendor>'` (should be empty). If either finds hits, the app can't be relocated without patching and the safer fix is a `postinst`-style symlink under `/var/opt` accepted as ephemeral (regenerated by a systemd unit at boot) rather than assuming `%{indep-libdir}` works unconditionally.

**Diagnosing this on a live system:** `stat /opt` shows `-> var/opt`; `ls -la /opt/<vendor>/` reports "No such file or directory" even though the element is listed in `/usr/manifest.json`; the payload is recoverable for inspection via `/usr/share/licenses/krytis/<element>/opt/...` (license-harvest copy) or by re-extracting the pinned `.deb`/`.tar` directly — the live rootfs itself no longer has it.

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

### File capabilities (`setcap`) can't be set at build time

`setcap` in `install-commands` always fails, even under BuildStream's fakeroot sandbox:

```
unable to set CAP_SETFCAP effective capability: Operation not permitted
```

The sandbox doesn't grant `CAP_SETFCAP` regardless of build-time fakeroot/pseudo-root status — there's no build-time workaround. If a binary needs a file capability, apply it at boot instead: ship a oneshot systemd unit that runs the real `setcap` as real root, enabled via a `system-preset`. The binary providing `setcap` (`libcap.bst`) must be a runtime `depends:`, not just `build-depends:` — the setcap CLI isn't pulled into the runtime-minimal stack by anything else. Tradeoff: the capability is absent for the brief window between boot and the oneshot unit running.

**Before reaching for this, check whether the client actually uses file capabilities at all.** `core/pangolin-cli.bst` originally shipped exactly this pattern (`cap_net_admin+ep` on the pangolin binary, oneshot unit + preset) to let a non-root user bring up its tun interface. It had no effect: `pangolin up` (fosrl/cli) never checks the binary's capabilities — `cmd/up/client/client.go` unconditionally re-execs itself via `sudo sh -c "..."` whenever `os.Geteuid() != 0`, every invocation, with no flag to skip it. The setcap unit was dead weight and was reverted; see "Passwordless sudo for a client that self-elevates" below instead.

### sudo-rs Cmnd Args matching has no substring/glob support inside a single arg

`sudoers.d` `Cmnd` specs in sudo-rs are matched against the real process argv **array, element-for-element** (`sudoers/mod.rs::match_command`: `Args::Prefix(vec) => args.starts_with(vec)`, `Args::Exact(vec) => args == vec`). The only wildcard forms are a bare trailing `*` token (Prefix: match these N whole args, allow any further whole args) or a bare trailing `""` token (Exact: no further args allowed) — a glob **inside** one arg string (e.g. `"foo"*` glued onto a quoted token) is rejected at parse time with `wildcards are not allowed in command arguments`. There is no fnmatch-style substring match like GNU sudo has. Also: only `\`, `,`, `:`, `=`, `#`, and space are escapable inside a Cmnd token (`tokens.rs::SimpleCommand::escaped`) — `\"` is not, and errors with `illegal escape sequence`.

**Practical consequence:** you cannot sudoers-scope a client that self-elevates via `sudo sh -c "<dynamic string>"` to anything tighter than the whole `sh -c` invocation (`Args::Prefix(["-c"])`, i.e. `/usr/bin/sh -c *`) — there is no way to prefix-match *inside* the dynamic string argv element. A design that assumes GNU-sudo-style embedded wildcards will not parse. See below for the fix actually used for this case.

### Passwordless sudo for a client that self-elevates: elevate the outer call instead, don't try to scope the inner `sh -c`

Some prebuilt clients call `sudo` on themselves internally instead of relying on file capabilities or polkit (e.g. `pangolin up` — see above). Given the Args-matching limitation above, don't try to sudoers-scope the client's internal `sh -c "<dynamic string>"` re-exec at all. Instead check whether the client has an `if already root, skip the internal sudo` branch — `fosrl/cli`'s `cmd/up/client/client.go` does (`if os.Geteuid() == 0 { ...no sudo... } else { ...sudo sh -c... }`). If so, grant sudo on the client's own **outer**, stable CLI surface instead, and require callers to invoke it pre-elevated:

```
%pangolin ALL=(root) NOPASSWD: %{bindir}/pangolin up *
```

("up" and the bare trailing `*` are separate whitespace-tokenized args in the sudoers line → `Args::Prefix(["up"])`, a legal wildcard form.) Callers must run `sudo pangolin up ...` themselves — not bare `pangolin up`. Once euid is already 0 inside the client process, its own internal re-exec branch never triggers, so there's no nested sudo call and no dependency on the internal shell-wrapper string at all.

This also fixes invoking a self-elevating client from a **GUI app with no controlling TTY** (e.g. a noctalia plugin shelling out to `pangolin up`): the client's internal sudo call typically wires `Stdin`/`Stderr` to the parent's for interactive password entry, which cannot work headlessly. Pre-elevating via a sudoers rule on the outer invocation means that code path is never reached — the caller's own `sudo pangolin up` is what's NOPASSWD-authorized, and no password prompt occurs so no TTY is needed either.

- **Dedicated group, not `wheel`**: create an empty system group via `sysusers.d` (`g pangolin - -`, installed to `%{indep-libdir}/sysusers.d/`). Nobody is a member by default — scopes *who* gets the rule. Users opt in with `usermod -aG pangolin <user>`.
- **Why this is tighter than it looks despite being a `Prefix` wildcard**: the wildcard is scoped to `pangolin up`, a small, public, versioned CLI subcommand — not `sh -c *` (arbitrary shell) and not the client's private internal string format. Renaming/removing `up` would be a documented breaking change upstream, not the kind of silent formatting drift a shell-wrapper string is prone to.
- sudoers file mode must be `0440` by convention, filename must not contain a `.` — see `install -Dm644 ... /etc/sudoers.d/zz-pangolin-cli` and the mode-clamping note above (0644 is what actually ships on this platform and is still safe/honored).

### `#includedir` ordering: last-matching-rule-wins can silently override a narrower NOPASSWD grant

sudo's `#includedir /etc/sudoers.d` (installed by `core/sudo-rs.bst`) reads files in **filename sort order**, and sudoers resolves conflicting entries by **last matching rule wins** — not most-specific-wins. `base-system.bst` depends on freedesktop-sdk's `vm/config/sudo.bst`, which installs `/etc/sudoers.d/wheel` containing `%wheel ALL=(ALL) ALL` (password required, and `ALL` matches every command). Any user who is in both `wheel` and a narrower NOPASSWD group (the pangolin case above, and the common case for a real desktop user account) will have the narrow rule silently overridden if its filename sorts *before* `"wheel"` alphabetically — e.g. `pangolin-cli` < `wheel`. `sudo -l` is misleading here: it lists every matching entry, not just the effective one, so the NOPASSWD rule appears to be present and correct even though it's dead.

**Symptom:** `sudo -n <cmd>` (or an interactive prompt appearing where NOPASSWD was expected) fails with `sudo: interactive authentication is required` (or, non-interactively, `sudo: a password is required`) despite `sudo -l` showing the NOPASSWD entry.

**Fix:** name any narrow NOPASSWD carve-out file so it sorts *after* `wheel` — e.g. `zz-pangolin-cli` instead of `pangolin-cli`. Check this any time a new sudoers.d drop-in grants a permission narrower than an existing group-wide rule; a `zz-` prefix is the cheapest way to guarantee last-match without tracking every other file that might land in `/etc/sudoers.d`.

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

## Unit tests needing a D-Bus session cannot run in a BST sandbox

`dbus-daemon` refuses to start in any BST sandbox, so upstream test suites that spawn a private
session bus (`dbus-run-session`) cannot be run there — not in `bst shell --build`, and not from
an element's `build-commands`. Confirmed 2026-08-17 while trying to run noctalia's
`secret_prompter` test after a fork rebase.

The error is actively misleading:

```
dbus[2389]: Could not get password database information for UID of current process:
            Looking up user ID 0: No such file or directory
dbus[2389]: Failed to start message bus: Memory allocation failure in message bus
dbus-run-session: EOF reading address from bus daemon
```

It is not memory. **The sandbox has no passwd database at all**, and `dbus-daemon` resolves its
own uid at startup before anything else. Note it fails for *root* too: `id -u` in a build sandbox
returns `0`, and even uid 0 has no `/etc/passwd` entry to find.

Routes that do not work, so nobody spends another four build cycles on them:

| Attempt | Result |
|---|---|
| Append an entry to `/etc/passwd` in `bst shell --build` | `/etc/passwd: Read-only file system` |
| Same from an element's `build-commands` | Also read-only — a build sandbox root is *not* writable, only the build dir and `/tmp` are |
| Add `components/dbus-base.bst` + `dbus-tools.bst` to get a daemon | Non-whitelisted overlaps against `libdbus.bst`/`dbus.bst`, which are already in any closure pulling `sdbus-cpp`. `dbus-run-session` is already present; the daemon was never the missing piece |
| Run as root instead of the build user | Already root; changes nothing |

`dbus-run-session` and `meson` *are* available in the sandbox, so the test **builds and starts** —
which makes this look like a real test failure in CI-style output. Read the stderr before
believing it.

**What to do instead.** Verify the parts the sandbox can prove — that it compiles, and that the
D-Bus surface is in the binary:

```shell
strings usr/bin/noctalia | grep -c org.gnome.keyring.SystemPrompter   # 1
strings usr/bin/noctalia | grep -oE 'libgcr-4\.so[0-9.]*' | sort -u   # libgcr-4.so.4
```

…then get behavioural coverage from a booted image or the live session, and for a rebase, prove
the code did not change (`docs/skills/workflow.md` § *Rebasing a carried fork branch*). A literal
string absent from the binary is not automatically a regression: `sx-aes-1` lives in
`libgcr-4.so.4`, not in noctalia, because `GcrSecretExchange` builds that header — check which
library owns a string before treating `grep -c` → `0` as a finding.

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

**`url: crates:crates` is mandatory, and its absence is legal upstream.** The
cargo2 plugin defaults to `https://static.crates.io/crates/` when `url:` is
omitted, and `generate_cargo_sources.py` does not emit the line. krytis lists
`unaliased-url` under `project.conf` `fatal-warnings:`, so a cargo2 block
without it is fatal here while being perfectly valid in a sibling project (both
zirconium-hawaii Rust elements omit it). It fails at `bst show`'s **resolve**
stage, not at load — a YAML-parse or reference-only check passes clean:

```
[unaliased-url]: cargo2 source at gaming/inputplumber.bst [line 8 column 2]:
  Use of unaliased source download URL: https://static.crates.io/crates/
```

Precedents to copy: `core/bootc.bst`, `desktop/greetd.bst`.

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

**Never install a real directory at a `GL/` extension path from a layer.** Several paths
under `%{libdir}/GL/` are symlinks into Mesa's own extension tree (e.g.
`GL/glvnd/egl_vendor.d -> ../default/glvnd/egl_vendor.d`). A layer that installs a real
directory at one of those paths shadows the symlink at OCI compose/merge time and evicts
the files behind it — dakota lost `50_mesa.json` (and with it the llvmpipe fallback) this
way by installing a vendor EGL ICD to `%{libdir}/GL/glvnd/egl_vendor.d/`. Vendor ICDs
belong in `/etc/glvnd/egl_vendor.d` instead — fdsdk's libglvnd only searches `/etc/glvnd`
and the GL extension dir, never `/usr/share/glvnd`. The same shadowing hazard applies to
any path under `GL/`: check with `ls -ld` on a composed image before choosing an install
location there.

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

## Auditing a fdsdk major-version bump for silently-broken element refs (#305, 2026-08-12)

`bst source track`/`bst show` only fail on the FIRST unresolvable reference — fixing errors one `mise validate` run at a time against a major fdsdk bump (25.08 → 26.08beta.3) means dozens of round-trips. Faster: extract every `freedesktop-sdk.bst:<path>.bst` reference repo-wide with `grep -rohP 'freedesktop-sdk\.bst:\K[a-zA-Z0-9_./-]+\.bst' elements/ include/ | sort -u`, then batch-check each path's existence at the target tag via the GitLab API (`.../repository/files/<url-encoded-path>/raw?ref=<tag>`, parallelized) — turns N sequential validate/fix cycles into one grep + one batch check. Applies to any junction, not just fdsdk.

**Five distinct failure shapes found this way, each needing a different fix — don't assume "moved to `_private/`" covers everything:**

1. **Moved to `components/_private/<name>.bst`.** fdsdk's own changelog names most of these ("These elements are now private: ..."), but the list is truncated in some renderings (GitLab's release page; even the raw changelog text can run past a tool's paging limit) — always fetch the full untruncated text via the GitLab releases API (`GET /projects/<id>/releases/<tag>`), not the web page. Two adjacent-looking names that changelog-search misses: `geoclue-base` (in the list) and `cryptsetup-lvm2-stage1` (NOT explicitly listed by name but moved anyway — check every reference, don't trust the announced list as exhaustive).
2. **Renamed outright.** `pyelftools.bst` → `python3-pyelftools.bst` (fdsdk's changelog says "pyelftool" singular, but the actual removed filename was "pyelftools" plural — changelog prose and actual filenames can disagree by one character; verify the literal path, not the changelog wording).
3. **Genuinely dropped, no replacement.** `unzip.bst` (info-zip 6.0/2009, 10 accumulated CVE patches — fdsdk declined to keep maintaining it) and `nlohmann-json.bst` (header-only lib, apparently just deemed out of scope). Neither renamed nor privatized — confirmed absent from the full `components/` and `components/_private/` trees. For a build-time header dependency still needed downstream (nlohmann-json), vendor it locally with the exact same source/config fdsdk carried (see `desktop/nlohmann-json.bst`, same pattern as the pre-existing `desktop/stb.bst`). For a runtime CLI convenience tool nobody else in the tree needs (unzip), just drop it and document substitutes — resurrecting abandonware upstream just dropped is going against their own signal, not "fixing" anything.

   **A pre-release series is not one bump — re-audit at every tag.** `efitools.bst` survived `26.08beta.3` intact and was deleted in `26.08rc.1` (fdsdk commit `b39e7194`, "Remove EFI elements", taking `efitools-bin`, `efitools-bin-maybe`, `efitools-efi`, `include/efitools.yml` and `components/perl-slurp.bst` with it — that last one existed only to build efitools' man pages). Auditing once at beta.3 and treating 26.08 as "done" would have shipped a `mise run seal-uki` that cannot sign `.auth` files. Re-run the grep-and-batch-check on every re-track, not just the first.

   **Vendoring is not always mirroring.** `desktop/nlohmann-json.bst` copies fdsdk's recipe verbatim because that recipe is one `cmake` invocation. `core/efitools.bst` deliberately does not: fdsdk's element built the whole upstream `all` target — nine signed EFI images, PK/KEK/DB key material, man pages — and then deleted the EFI half again in `install-commands`, which is what dragged in `gnu-efi`, `help2man`, generated boot keys and perl `File::Slurp`, two of which no longer exist at rc.1. krytis calls exactly one binary (`sign-efi-sig-list`), so the vendored element runs `make sign-efi-sig-list` and installs that. Copy upstream's *inputs* (source ref, patches that matter); copy their *build* only when it is already minimal. Two of fdsdk's four efitools patches touch only the `%.efi` objcopy path and were dropped rather than carried as dead weight.

   Watch for headers hiding behind a "host tool" label while trimming: `sign-efi-sig-list` is an ordinary ELF binary but `#include`s `<efi.h>` for the `EFI_SIGNATURE_LIST`/`EFI_TIME` layouts it writes, so `gnu-efi` stays a build-dep even with every EFI target removed. The failure is a plain `fatal error: efi.h: No such file or directory` 47 minutes into a cold build — check the includes of what you are keeping before deciding a dependency is EFI-only.
4. **Cross-junction element swap, not a path change at all.** `gnome-build-meta.bst:core/gnome-keyring.bst` didn't move or rename — GNOME replaced it with a different project entirely (`oo7`, Rust) partway through the 26.08 cycle. Nothing in fdsdk's own changelog mentions this (it's a gnome-build-meta-side change, not fdsdk's). Found via `.../repository/commits?path=<old-path>&ref_name=master` on the gnome-build-meta project — GitLab's commits-by-path endpoint still returns history for a path that no longer exists at the target ref, and the commit titled "Replace gnome-keyring with oo7" names the replacement directly. When a `core/`-level (not `core-deps/`) element vanishes with no rename, check the *other* junction's own commit history by path before assuming it's a straightforward fdsdk-side rename.

   Knowing the replacement's *name* is not the same as adopting the junction's packaging of it. krytis took neither `gnome-build-meta.bst:core-deps/oo7-daemon.bst` nor its siblings: `main` had already vendored `elements/desktop/oo7.bst` (built from upstream `linux-credentials/oo7` with krytis's own prompter patch) for reasons independent of this bump, so the fdsdk 26.08 branch inherits that on rebase and the swap costs nothing here. See `docs/design/secrets-service.md`.
5. **A mirrored element drifts without breaking anything (found on the 2026-08-18 rebase onto `main`).** `elements/overrides/*.bst` are hand-copies of an upstream element — `overrides/rust-bindgen.bst` mirrors fdsdk's `components/rust-bindgen.bst`, `overrides/systemd-base.bst` mirrors gnome-build-meta's `core-deps/systemd-base.bst`. Every path inside them still resolves after a bump, so the grep-and-batch-check above finds nothing and `mise run validate` passes clean; the copy just keeps building the *old* recipe. The `runtime-minimal` split is exactly the trap: upstream's own `rust-bindgen.bst` gained `bootstrap/bash.bst` + `bootstrap/coreutils.bst` in the 26.08 bump (they used to arrive implicitly via `runtime-minimal`) and the mirror inherited neither. **After any junction bump, run every `*-check` drift task** — `mise run rust-bindgen-check`, `mise run systemd-base-check`. They are the only thing that sees this class. Baseline them against `main` first: `systemd-base-check` already fails there (gnome-build-meta ships systemd v261.2, the mirror pins v260.2), so a failure on a bump branch is not automatically the bump's fault.

   The drift checks strip krytis's `freedesktop-sdk.bst:` dependency prefix before diffing against upstream, and `rust-bindgen-check` wrote that strip as `s/freedesktop-sdk\.bst:components\///` — narrow enough that the first `bootstrap/` dependency to appear reported a false mismatch on top of the real one. Strip the junction prefix, not one path under it: `s/^- freedesktop-sdk\.bst:/- /`.

   It drifts *again*, and fast. `overrides/rust-bindgen.bst` was resynced at beta.3 to the explicit `bash`/`coreutils`/`gcc`/`rust`/`stripper` list upstream had just written, and one tag later rc.1 collapsed all five into a single `public-stacks/buildsystem-rust.bst`. Two resyncs of the same mirror inside one pre-release series. Treat `mise run rust-bindgen-check` / `mise run systemd-base-check` as part of the re-track ritual, alongside `mise run validate` — not as a one-off done when the bump first landed.
6. **Code that only krytis compiles, because krytis builds `x86_64_v3` (found in Phase 3 of #305, 2026-08-26).** Reference-checking and `mise run validate` cannot see this class at all — every path resolves, the graph is fine, and the failure is a compiler error hundreds of elements into a real build. krytis passes `-o x86_64_v3 true` on every `bst` invocation, so `-march=x86-64-v3` is in effect for the whole tree, and that defines `__BMI2__`, `__AVX2__`, `__FMA__` and friends. freedesktop-sdk's own CI builds baseline `x86_64` and never defines them. Any upstream `#ifdef __BMI2__` block is therefore dead code for them and live code for us — **krytis is the first consumer to compile it, and upstream's green pipeline says nothing about whether it builds.**

   The instance: abseil `20260526.0`, which fdsdk `26.08rc.1` pins, opens `absl/container/internal/raw_hash_set.h` with `#ifdef __BMI2__` / `#include <bmi2intrin.h>`. GCC refuses that header directly — `#error "Never use <bmi2intrin.h> directly; include <x86gprintrin.h> instead."`, guarded on `_X86GPRINTRIN_H_INCLUDED` — so the build dies at `[203/344]` in abseil. Fixed by `overrides/abseil-cpp.bst` + a one-line patch to `<immintrin.h>`, which is the portable umbrella providing the same `_bzhi_u32`/`_bzhi_u64` the header goes on to call. Deleting the include does *not* work; the BMI2 branch is live code, not vestigial.

   Two things worth internalising from it. **Check whether the defect is a window before forking.** abseil upstream had already removed the whole `__BMI2__` block (commit `09a054bc6`, 2026-06-08); the bad include exists only in the `20260526.*` series, with `20260107.*` before it and `20260817.0` after it clean. That turns "we now maintain an abseil fork" into "we carry a patch until the junction's next abseil bump", and it is the difference between a one-line patch and a three-month version jump — resist bumping the mirror to the fixed release just because one exists, since that drags unvalidated upstream change into a graph where everything links it. **And expect this class on every ISA-gated construct**, not just BMI2: when a from-source build of an upstream component fails on something that looks impossible ("surely someone would have noticed"), check whether the failing code is behind an ISA macro before assuming the pin is wrong.

   Convention: every `elements/overrides/*.bst` gets a matching `mise run <name>-check` task. A mirror without a check is a mirror that will rot silently. There are two shapes of check, and picking the wrong one makes it useless:

   - **Drift checks**, for mirrors that are meant to equal upstream apart from a patch — `rust-bindgen-check`, `systemd-base-check`, `abseil-cpp-check`. They diff the copy against the junction's version and re-apply the patches. They fail when upstream moves.
   - **Exit-condition checks**, for overrides that are *deliberately* different — `libdisplay-info-check`, which holds 0.3.0 while the junction ships 0.4.0. Diffing that against upstream would be red forever and tell nobody anything, so it instead watches for the condition that makes the override droppable (here: a `libdisplay-info-sys` release that can consume 0.4) and fails when the block *lifts*. A red run is good news.

   Note that `overrides/abseil-cpp.bst` deliberately keeps `public-stacks/runtime-minimal.bst` rather than the `runtime-gnu` the 26.08 rename applied everywhere else, because mirror fidelity is what a drift check enforces and upstream uses the stripped-down runtime there.

   **A mirror that cannot be byte-faithful needs a declared divergence list, not a looser diff.** `overrides/systemd-base.bst` copies a *gnome-build-meta* element, and three of upstream's constructs simply do not resolve in krytis: the `(?) channel == …` source conditional (krytis defines no `channel` project option), `(@): include/{gcc,clang}-for-recc.yml` (their remote-execution plumbing, carrying `digest-environment: RECC_REMOTE_PLATFORM_chrootRootDigest`), and `buildsystems/meson.bst` (a gbm-internal element). Each is replaced by a freedesktop-sdk equivalent. `systemd-base-check` therefore carries **two** lists — `LOCAL_ADDITIONS` for lines krytis adds and `UPSTREAM_IGNORES` for lines krytis deliberately drops — each commented with why. Every other line still has to match exactly, so a genuine upstream change is still caught. Relaxing the diff instead would have made the check useless in precisely the way it had already become: red for months, for reasons nobody could distinguish from real drift.

   **Do not delete a block with a `sed` range.** `sed '/^  (?):$/,/^      - .\*-rc\*.$/d'` looks right and is not: sed *restarts* the range. Once the first block closes it keeps scanning, hits the second `  (?):` (an unrelated `arch in […]` conditional further down the same file), finds no second end anchor, and deletes to EOF — 90 lines instead of 7. The upstream side of the comparison is silently truncated and the entire tail then shows up as local drift, which is a very convincing wrong answer. Use a one-shot `awk` with a `done` flag. The same hazard applies to `grep -vxF` on a short line: it drops *every* occurrence, which is why the ignore lists here hold only strings that appear exactly once.
7. **The rest of the toolchain moved too, and only a real build says so (Phase 3 of #305, 2026-08-26).** A major fdsdk bump is not just elements appearing and disappearing — it re-bases the compiler, the C library and every system library version underneath. Three of the four Phase 3 build failures were this, and none was visible to reference-checking, `mise run validate`, or any drift check:

   - **A system library crossed a version bound a vendored Rust crate refuses.** libdisplay-info 0.3.0 -> 0.4.0; niri's vendored `libdisplay-info-sys` declares `< 0.4.0` and pkg-config rejects it outright. **Do not just widen the bound.** Check first whether the `-sys` crate bindgens at build time or ships hand-written bindings: this one has per-version modules (`src/v0_1`, `v0_2`, `v0_3`) and no `v0_4`, so widening selects v0_3 bindings against a 0.4 library whose `struct di_edid_*` lost two fields — wrong offsets, no build error, garbage at runtime. Held the library back instead, which was cheap because only two elements consume it.
   - **A C++ library started requiring a newer language standard.** ICU 77.1 -> 78.3, and ICU 78's `unicode/localpointer.h` uses an `auto` non-type template parameter (C++17). Anything whose configure still selects `-std=gnu++11` now fails on merely *including* an ICU header. When fixing, put the standard in `CXX` rather than `CXXFLAGS` — autoconf appends its `-std=gnu++11` to `CXX` ahead of every `CXXFLAGS` entry, so naming the standard in `CXX` makes the probe answer "none needed" instead of relying on GCC's last-`-std`-wins ordering, and leaves fdsdk's hardening flags alone.
   - **glibc outran a bundled toolchain's ABI knowledge.** fdsdk ships glibc 2.44; Zig 0.15.2's abilists stop at 2.42, so Zig's synthesised stub libc lacks the `@GLIBC_2.43` symbols that GCC-built system libraries reference, and `ld.lld` rejects the link with `--no-allow-shlib-undefined`. This is specific to toolchains that synthesise their own libc (Zig, and anything cross-compiling) — the symbols do exist in the real glibc at load time, so `linker_allow_shlib_undefined` is a legitimate answer rather than a suppression. Field name gotcha: it is `linker_allow_shlib_undefined` on `std.Build.Step.Compile` in Zig 0.15.2, not `allow_shlib_undefined`.

   The common lesson: **before reaching for a version bump as the fix, check that a newer version exists and would actually help.** All three had a tempting "just update it" that was wrong — libqalculate's `configure.ac` sets no C++ standard on any version including master, niri v26.04 *is* the newest release and the crate has no 0.4-capable version at all, and ghostty v1.3.1 is the newest tag with a Zig floor of exactly the version that fails. Confirming that took minutes each and saved three pointless bumps.
8. **An upstream element grew a file yours already owned, and nothing notices until compose (Phase 3 of #305, 2026-08-26).** The last failure of the bump, and the only one where every element *built* successfully. fdsdk 26.08's ncurses added a `ghostty` entry to its own terminfo database, so `/usr/share/terminfo/g/ghostty` was suddenly installed by two elements and `oci/krytis/runtime.bst` refused to stage:

   ```
   /usr/share/terminfo/g/ghostty: desktop/ghostty.bst is not permitted to overlap
   other elements, order desktop/ghostty.bst above freedesktop-sdk.bst:bootstrap/ncurses.bst
   [overlaps]: Non-whitelisted overlaps detected
   ```

   `mise run validate` cannot see this — it resolves the graph, it never composes it. Neither can any drift or reference check. **It arrives last, after everything compiles**, which means a bump is not clear of this class until the image itself assembles, and fixing an earlier element can be what exposes it.

   Resolve with a one-entry `overlap-whitelist` on the element that should win (see § Additive Rust replacements). Decide *which* should win on provenance: ghostty's terminfo is compiled from the source shipped with that exact release, ncurses carries a database snapshot that lags whatever the terminal implements, so ghostty's copy is the correct one. **Scope the whitelist from evidence, not from the error message** — `bst artifact list-contents` on both artifacts showed exactly one colliding path, since ghostty's `/usr/share/terminfo/x/xterm-ghostty` is unique to it. One line, not a glob over the terminfo tree. A glob here would silently absorb the *next* collision too, which is precisely the warning you want to keep.

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

`files/scripts/generate_cargo_sources.py` didn't actually exist in this repo until #496, despite being documented here since the greetd element was added — the doc referenced a script that was never vendored (only the sibling `dakota` fork had a project-specific version). Fixed by adding a generic one (reads `Cargo.lock` via stdlib `tomllib`, emits the `ref:` list body only — paste under an existing `kind: cargo2` source's `ref:` key, not as a whole replacement source block, since elements may carry extra keys like `url:`/`git-mirrors:`/`build-args:`).

### `cargo update -p X` does not cascade to transitively-satisfied dependencies

Bumping a direct dependency does **not** bump its own dependencies unless the new version strictly requires a newer one. Confirmed while fixing greetd's `tokio`/`bytes` CVEs (#496): `cargo update -p tokio` alone moved `tokio` 1.37.0→1.42.1 but left `bytes` at 1.6.0 — tokio's manifest only declares `bytes = "1"`, and 1.6.0 still satisfies that caret range, so cargo's conservative resolver had no reason to touch it. `bytes`' own CVE (GHSA-434x-w66g-qw3r, fixed at 1.11.1) needed its own explicit `cargo update -p bytes`. **Don't assume a vulnerable transitive dependency "comes along for the ride"** when bumping the crate that pulls it in — check the resulting `Cargo.lock` for the actual version and `-p` it directly if it didn't move.

### Dropping an unused workspace member to eliminate an unpatchable-semver-range CVE

When a vulnerable crate's fix is a major-version bump outside the range the workspace's `Cargo.toml` declares (`cargo update -p <crate>` can't cross it) and that crate turns out to be needed by only one, genuinely-unused workspace member — dropping the member is often cleaner and lower-risk than bumping the constraint and hoping nothing broke. Done for `rpassword` (5.0.1→7.5.0 needed, a two-major jump) via dropping `agreety` — greetd's own unused reference text-greeter binary (krytis ships `noctalia-greeter-session`, confirmed via `greetd-config.bst`'s `[default_session]`, not `agreety`) — from `[workspace] members` in a `kind: patch` source (`patches/greetd/drop-agreety-workspace-member.patch`), then regenerating `Cargo.lock`/the `cargo2` block from the now-narrower dependency graph.

Two things this doesn't automatically clean up:
- **Install-commands still reference the now-unbuilt binary** — `install -Dm755 -t ... target/release/agreety` fails outright once the crate isn't compiled; remove it from the install line.
- **Makefiles/build scripts that install docs unconditionally** — greetd's `man/Makefile` `install` target installs `agreety.1` regardless of which binaries were actually built (it's driven by `scdoc` source files, not the Cargo workspace). Dropping the crate without also dropping its man page leaves a doc page for a command that doesn't exist. Fixed with a targeted `rm -f "%{install-root}%{mandir}/man1/agreety.1"` after the `make install` step, rather than patching the Makefile itself.

**Same technique also applies to a mirrored (not krytis-owned) element.** `elements/overrides/rust-bindgen.bst` (#498) drops freedesktop-sdk's `bindgen-tests/tests/quickchecking` workspace member the identical way — the difference is *where* the patch lives: since `components/rust-bindgen.bst` belongs to the freedesktop-sdk junction, the fix goes through "Mirroring a junction element to patch its source" (above) rather than patching a krytis-owned element directly. `quickchecking` was never in the workspace's `default-members`, so — like `agreety` — it was already dead weight in the built binary; only `Cargo.lock`'s full-workspace resolution (which ignores `default-members`) pulled its `quickcheck -> rand` 0.8.5 pin into the SBOM.

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
```

**Name the file after krytis, not after the upstream it configures.** This one is `/usr/lib/tmpfiles.d/krytis-greetd.conf`. It used to be `noctalia-greeter.conf` and also carried `d /var/lib/noctalia-greeter 0755 greeter greeter -` — then noctalia-greeter v1.1.0 started shipping its own `data/tmpfiles.d/noctalia-greeter.conf` with `d /var/lib/noctalia-greeter 0750 greeter greeter -`, and the identical install path became a non-whitelisted overlap that fails `oci/krytis/runtime.bst` at *staging*, not at build. Upstream now owns that directory; krytis declares only `/var/lib/greetd`. Colliding on an upstream-shaped filename is a latent trap for every config element here: whitelisting the overlap would have papered over a genuine mode conflict (0755 vs the tighter 0750) instead of resolving who owns the line.

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

## Flatpak Pre-install Service Pattern

To install initial system Flatpak apps on first boot use a systemd oneshot service gated on a marker file rather than `ConditionFirstBoot=yes`. The marker approach retries if the network was unavailable on the first boot, while `ConditionFirstBoot=yes` only ever fires once.

Key points:
- Gate with `ConditionPathExists=!/var/lib/flatpak/.krytis-preinstall-done`; write the marker at the end of the script (only if `flatpak install` succeeded).
- Declare `Wants=flatpak-system-helper.service` and `After=flatpak-system-helper.service` so the D-Bus helper is running before the install attempt.
- The `flatpak` binary is already in the image transitively (see § above); no explicit dep needed.
- The bootc-installer flatpak (`org.bootcinstaller.Installer`) lives only in the live ISO overlay — it is not part of the OCI image — so no firstboot removal service is needed. Dakota's `bluefin-remove-installer.service` exists because their image includes it; krytis's does not.
- **Bazaar is `io.github.kolunmi.Bazaar`**, a standalone flatpak app-store frontend — not GNOME Software. It is installed as a flatpak (via the preinstall service), not as a BST element.
- Bazaar's curated-recommends config lives in `/etc/bazaar/bazaar.yaml` + `/etc/bazaar/curated.yaml`, not in `/usr/share/gnome-software/`. Accessing `/etc` from a flatpak requires a permission override delivered via a tmpfiles symlink (see issue #245 for full porting notes). This config belongs in a dedicated BST element, not in the preinstall service.

## Flatpak sandboxing: Discord RPC and game detection

*Source: live diagnosis 2026-08-14 — issues #591 (RPC socket path) and #595
(game detection). Read those before touching either.*

Two separate mechanisms, two separate verdicts. Do not conflate them.

**Resolved for Equibop by leaving the sandbox.** `elements/desktop/equibop.bst`
(#609) installs Equibop natively, so it holds `discord-ipc-0` in the real
`$XDG_RUNTIME_DIR` and shares the host PID namespace — both mechanisms below
work with no bridging and no overrides. Everything that follows still applies to
every Discord client that stays a flatpak, and to any future consumer probing
for a socket. Prefer a native element over bridging when the choice is open.

**`$XDG_RUNTIME_DIR/discord-ipc-N` is namespaced per app.** Inside any sandbox
that path is backed by `$XDG_RUNTIME_DIR/.flatpak/<app-id>/xdg-run/discord-ipc-N`
on the host — never by a shared location. A client's socket is host-visible, but
only under **its own** app ID, so a consumer probing the canonical path finds its
own empty slot. The `$TMPDIR`/`/tmp` fallbacks every RPC library also tries are
private per sandbox and never bridge either.

Consequences that cost real time to rediscover:

- **`--filesystem=xdg-run/discord-ipc-0` is a no-op.** flatpak can only bind a
  path that already exists on the host, and this one never does. Granting it —
  globally or per app — changes nothing. `xdg-run/app/com.discordapp.Discord`
  *does* work, because Discord's wrapper relays its socket there with `socat`.
- **A host symlink at the canonical path breaks clients that claim it.** Discord
  and Vesktop each create a real socket at `$XDG_RUNTIME_DIR/discord-ipc-0`
  inside their sandbox; a host-side object bound over it makes launch fail with
  `bwrap: Can't make symlink at …: destination exists and is not a symlink`.
  Equibop does not claim the path and is unaffected. So the obvious
  user-tmpfiles `L %t/discord-ipc-0 → …` fix is not safe by itself.
- **flatpak persists whatever occupied a granted path** into
  `.flatpak/<app-id>/xdg-run/`, and it outlives deletion of the host original.
  Clear the stubs between experiments or results are stale:
  `for f in $XDG_RUNTIME_DIR/.flatpak/*/xdg-run/discord-ipc-0; do [ -L "$f" ] && rm -f "$f"; done`
- **`rpc-bridge` already encodes the correct search order.** Wine/Proton games
  under Faugus get RPC via `c:\windows\system32\discord\bridge.exe --service`,
  which probes canonical → `app/com.discordapp.Discord/` →
  `.flatpak/dev.vencord.Vesktop/xdg-run/` →
  `.flatpak/com.discordapp.Discord/xdg-run/` → the two `snap.discord*` paths.
  Copy that list rather than inventing one. It has **no Equibop entry** and does
  not need one: the native element puts Equibop's socket at the canonical path,
  which is the first entry `rpc-bridge` probes.

**Game detection can never work in flatpak.** Discord matches running processes
against a known-executable list, and a flatpak app is in its own PID namespace:
`NSpid: 8712 7`, 18 visible PIDs against 485 on the host, the game's PID simply
absent. There is no override — `--share` accepts only `network` and `ipc`,
`--allow` only `devel`/`multiarch`/`bluetooth`/`canbus`/`per-app-dev-shm`.
Binding host `/proc` does not help; the namespace hides the PIDs, not the mount.

So a title with no RPC support of its own (World of Warcraft holds zero Discord
sockets) shows **no presence at all** under a flatpak Discord, and the same
combination works natively. That is expected behaviour, not a regression to
chase — reach for #595's options list instead.

### Debugging without false negatives

Four traps, each of which produced a wrong conclusion during the original
diagnosis:

| Symptom | Reality |
|---|---|
| `strings … \| grep …` inside a sandbox returns nothing | `strings` is **not in the freedesktop runtime**; scan `/var/lib/flatpak/app/<id>/current/active/files/` from the host |
| grep for `discord-ipc-0` in a consumer binary finds nothing | the digit is appended at runtime — search for `/discord-ipc-` |
| `find $XDG_RUNTIME_DIR -name 'discord-ipc-*'` finds nothing | it silently misses these; `ls` the specific paths |
| repeated handshakes to a live socket mostly time out | reproduces at ~1/8 on Discord's own socket *and* through its `socat` relay, so it is not the relay; may be an artifact of probing with an invalid `client_id` — do not conclude "relay is broken" |

A handshake probe is the cheapest liveness test: connect, send op `0` with
`{"v":1,"client_id":"…"}`, read one frame. `op=2 {"code":4000}` means a real
Discord answered and rejected the ID — the transport is fine. arRPC answers
`op=1 … READY` and accepts any ID.

## NetworkManager Is Present and Running, Despite the networkd-Only Stack

krytis's own elements only ever configure `freedesktop-sdk.bst:vm/config/networkd.bst` + `vm/config/resolved.bst` — there is no `depends:` on `core-deps/NetworkManager.bst` anywhere in `elements/`. Despite that, `NetworkManager.service` is active and enabled on a real deployed image (confirmed via `systemctl is-active NetworkManager`, `busctl list` showing `org.freedesktop.NetworkManager`, and `/usr/manifest.json` listing `core-deps/NetworkManager.bst`). A plain `grep -rl NetworkManager elements/` (or even a manual BFS over the two staged-junction trees starting from the wrong set of seed files) will wrongly conclude it isn't there — do not trust that conclusion without checking a live system.

The actual chain:

```
stacks/desktop.bst
  → gnome-build-meta.bst:core/nautilus.bst
    → gnome-build-meta.bst:core-deps/localsearch.bst   (Tracker Miners successor, file-content indexing)
      → (runtime depends) gnome-build-meta.bst:core-deps/NetworkManager.bst
```

`core-deps/upower.bst` arrives the same way, via a different, shorter path already used directly: `stacks/desktop.bst → gnome-build-meta.bst:core-deps/power-profiles-daemon.bst → core-deps/upower.bst`.

Practical upshot: it is safe for other elements (e.g. a systemd `ExecCondition=` hardware gate) to assume `org.freedesktop.NetworkManager` and `org.freedesktop.UPower` are present on the D-Bus system bus at runtime, without adding an explicit new dependency for either.

**How to check what's really on a live krytis image** (more reliable than grepping this repo): read `/usr/manifest.json` on the booted system. It's produced by `elements/oci/krytis/manifest.bst` (`kind: collect_manifest`) and lists every module in the actual build closure with its `x-cpe` product/version:

```python
import json
mods = json.load(open('/usr/manifest.json'))['modules']
names = {m['name'] for m in mods}
'core-deps/NetworkManager.bst' in names  # True
```

This is ground truth for "is X in the image" — the source-tree dependency graph is not, since transitive `depends:` chains inside `freedesktop-sdk`/`gnome-build-meta` junctions are not always obvious from krytis's own files.

## resolv.conf and /etc/hosts Are Already Covered — No network.bst Needed

dakota ships `elements/bluefin/network.bst`, doing two things: (1) a tmpfiles.d rule symlinking `/etc/resolv.conf` to systemd-resolved's stub resolver, (2) a static `/etc/hosts` with `localhost` entries. Porting this to krytis (#176) looked plausible but both are already transitively covered — verified via `grep`ping the staged fdsdk junction (`.bst/staged-junctions/freedesktop-sdk.bst/<hash>/`) and confirming live on a booted image:

1. `/etc/resolv.conf` symlink: systemd itself ships `/usr/lib/tmpfiles.d/systemd-resolve.conf` (`L! /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf`) as part of the systemd package — this arrives for free once anything depends on `freedesktop-sdk.bst:vm/config/resolved.bst` (already the case via `elements/stacks/base-system.bst`). Dakota's version is redundant, not a gap-filler.
2. `/etc/hosts`: fdsdk's `components/hosts.bst` ships the identical two-line file, pulled in transitively as a runtime-minimal dep — no krytis element needed.

**Caveat — "covered" is not "unimportant".** Because the image's `nsswitch.conf` hosts line
is `mymachines resolve [!UNAVAIL=return] files myhostname dns`, no glibc program ever reads
`/etc/resolv.conf`; the trailing `dns` module is unreachable. That file is load-bearing for
exactly one class of program: statically linked binaries with no NSS, of which
`core/mise.bst` (musl static-pie) is the one shipped in the image. A missing or stale
`/etc/resolv.conf` therefore presents as "`mise` gets DNS errors, everything else on the
machine is fine." See [`mise.md`](mise.md) § The shipped `mise` is musl-static — it is the
one binary that needs `/etc/resolv.conf`.

Lesson: before porting a dakota element to krytis, check the target files against what fdsdk/gnome-build-meta already ship (staged junction tree under `.bst/staged-junctions/`, or ground-truth via `/usr/manifest.json` + reading the live file on a booted image per the NetworkManager section above) — "dakota has an element for X" does not imply "krytis needs an element for X."

## Upstream Project Renames (2026)

| Project | Old URL | Current URL |
|---|---|---|
| cage | `Hjdskes/cage` (sr.ht) | `github_files:cage-kiosk/cage` |
| wlr-randr | `sr.ht/~emersion/wlr-randr` | `freedesktop_files:emersion/wlr-randr` |
| noctalia-shell | `noctalia-dev/noctalia-shell` | `github:noctalia-dev/noctalia` (`git_repo`) |
| kmscon | `Aetf/kmscon` (personal fork) | `github:kmscon/kmscon` (`git_repo`) |
| libtsm | `Aetf/libtsm` (personal fork) | `github:kmscon/libtsm` (`git_repo`) |

Always verify the canonical URL when vendoring a source for the first time.

## fdsdk mesa doesn't expose `egl.pc` / `glesv2.pc` via pkg-config

Even with mesa built `-Degl=enabled -Dgles2=enabled`, a plain `dependency('egl')` or `dependency('glesv2')` in a consuming project's meson.build will fail to resolve, regardless of `PKG_CONFIG_PATH` pointing at mesa's `GL/default/lib/pkgconfig` (see the prepend-mesa-env pattern above). `freedesktop-sdk.bst:components/libglvnd.bst` deliberately `rm`s `egl.pc`, `gl.pc`, `glesv2.pc`, and `glesv1_cm.pc` from its own install output, and mesa's own `GL/default` split only ships `gbm.pc`/`libdrm*.pc` — no EGL/GLES2 `.pc` files exist anywhere in the dependency graph. Projects that need actual GPU-accelerated GL/EGL (wlroots, niri) sidestep this by using `libepoxy` (dlopen-based GL/EGL loading, no `.pc` needed at compile time) instead of linking `libEGL`/`libGLESv2` directly.

If a new element's meson.build has a hard `dependency('egl')`/`dependency('glesv2')` requirement with no libepoxy option, the pragmatic fix is to disable the feature that pulls it in (e.g. kmscon's `video_drm3d`/`renderer_gltex`) and fall back to a software/DRM2D path instead, rather than trying to manufacture the missing `.pc` files. See `elements/desktop/kmscon.bst`.

## Enabling one instance of a templated getty-replacement unit, never the bare template

Some VT console emulators (kmscon's `kmsconvt@.service`, similarly `agetty@.service`) ship an `[Install]` section with `Alias=autovt@.service` and `DefaultInstance=tty1` — enabling the bare template (`systemctl enable kmsconvt@`) makes systemd-logind spawn it in place of `getty@tty1`, i.e. VT1. If VT1 is already owned by another service (greetd, in krytis), do **not** enable the bare template. Enable only the specific instances you want, so each instance's `Conflicts=getty@%i.service` only conflicts with that VT's getty, leaving VT1 untouched.

**Do not do that with `enable kmsconvt@tty2.service` lines in a system-preset file.** `systemctl preset-all` iterates unit *files*, and a template instance is not a file, so it never acts on an instance named only in a preset file — the lines are silently inert. And once no rule matches the *bare* template, preset-all falls through to its default `enable` policy and enables `DefaultInstance=tty1`, which is precisely the VT1 preemption you were avoiding. This shipped in krytis and started kmscon on greetd's VT on every boot (#503).

Instead, enable the instances with static `.wants` symlinks in the vendor unit path, and add a `disable` rule for the bare template to close the fall-through:

```yaml
  install-commands:
  - |
    wants_dir="%{install-root}%{indep-libdir}/systemd/system/getty.target.wants"
    mkdir -p "${wants_dir}"
    for vt in tty2 tty3 tty4; do
        ln -s "../kmsconvt@.service" "${wants_dir}/kmsconvt@${vt}.service"
    done

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/80-kmscon.preset" <<'EOF'
    disable kmsconvt@.service
    EOF
```

`preset-all` only writes to `/etc`, so it can neither create nor remove the `%{indep-libdir}` symlinks. Two gotchas when checking the result:

- `systemctl is-enabled kmsconvt@tty2.service` reports **`static`**, not `enabled` — that is the expected label for a unit enabled from the vendor unit path. The dependency is still real; systemd ships `sysinit.target.wants/systemd-firstboot.service` the same way. Assert `systemctl show -p Wants --value getty.target` instead.
- Never `systemctl enable` the instances, in an image or by hand: that materialises the `Alias=autovt@.service` symlink, after which `autovt@ttyN.service` resolves to kmscon rather than `getty@.service` and logind spawns kmscon on any VT switch.

### Keep `NAutoVTs` aligned with the VT layout — but never set `ReserveVT=0`

krytis's console map, once every owner is accounted for:

| VT | Owner | Set by |
|---|---|---|
| 1 | greetd | `greetd-config.bst` (`vt = 1`) |
| 2–4 | kmscon | `config/kmscon.bst` `getty.target.wants` symlinks |
| 5 | first-boot wizard (first boot only) | `krytis-firstboot.service` `TTYPath=/dev/tty5` |
| 6 | reserved rescue getty | logind's `ReserveVT` default |

`NAutoVTs` defaults to **6**, so logind will spawn an on-demand getty anywhere in
VT2–6 that isn't busy. VT2–4 are busy (kmscon starts them at boot), but once the
wizard releases tty5, `Ctrl+Alt+F5` gets a plain getty on the wizard's own VT.
`config/kmscon.bst` therefore ships `logind.conf.d/10-krytis-vts.conf` with
`NAutoVTs=4`, capping the on-demand range to kmscon's.

**Do not set `ReserveVT=0` to "tidy away" VT6.** logind starts a getty on the
reserved VT *unconditionally*, skipping the `vt_is_busy()` check
(`src/login/logind-core.c`, `manager_spawn_autovt()`); that same check order is
why VT6 keeps its getty even though `6 > NAutoVTs`. `logind.conf(5)` states the
intent: the reserved VT "will be marked busy unconditionally, so that no other
subsystem will allocate it … one login getty is always" available. On krytis it is
the *only* in-band way into a box whose greeter has wedged — root is locked
(`root:!unprovisioned`) and sshd ships `disable`d by preset — and after the
first-boot change the sole account is homed-managed with an encrypted home, which
adds a failure mode (`docs/skills/pam.md`) rather than removing one. It costs
nothing while unused: the getty unit is not even loaded until someone switches to
VT6.

Verify a change here without booting:

```console
$ systemd-analyze cat-config --root=<tree> systemd/logind.conf | grep -E 'NAutoVTs|ReserveVT'
#NAutoVTs=6
#ReserveVT=6
NAutoVTs=4          # from 10-krytis-vts.conf
```

See `elements/config/kmscon.bst`.

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

Relevance: SBOM generation is implemented (#40, `mise run sbom`) — elements emitting this warning appear as gaps in the SBOM (no upstream source info recorded). This is a known limitation scoped to junction dependencies. See `docs/skills/sbom.md` for the generation/attach flow.

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

## Junction override: hiding gvim's desktop entry

fdsdk's `components/vim.bst` builds vim with an unpatched autotools `./configure` — no `--disable-gui` flag is set, so `configure` autodetects X11/GTK in the build sandbox and builds both `vim` and `gvim`, installing **two** desktop files: `runtime/vim.desktop` and `runtime/gvim.desktop`. fdsdk already carries a local patch (`patches/vim/vim-not-show-in-gnome.patch`) that sets `NoDisplay=true` on `vim.desktop` (the terminal one) — but leaves `gvim.desktop` untouched, so gvim shows up as a stray app-menu entry.

Fix: override `components/vim.bst` (same `overrides/<name>.bst` pattern as `frei0r.bst`/`sudo-rs.bst`) with an element identical to upstream's, plus one extra `kind: patch` source that sets `NoDisplay=true` on `gvim.desktop` the same way. The original `vim-not-show-in-gnome.patch` must also be copied into `patches/vim/` locally — a `kind: patch` source path is resolved within the current project, it cannot reach into the fdsdk junction's `patches/` directory.

```yaml
# elements/freedesktop-sdk.bst
config:
  overrides:
    components/vim.bst: overrides/vim.bst
```

Insertion point in both `vim.desktop` and `gvim.desktop` is identical: add `NoDisplay=true` on the line before `Type=Application`.

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

## `systemd-stage1` belongs in `build-depends`, not `depends`; path is FDSDK-version-specific

*Source: zirconium-hawaii `3ae47dd`, `28656b2`*

`systemd-stage1` is a build-time tool — it belongs in `build-depends`, not `depends` (runtime). Putting it in `depends` silently breaks the build because the element isn't available at build time where it's actually needed.

The path is also FDSDK-version-specific. zirconium-hawaii hit a silent break from using a `26.08beta` path when the junction was actually `25.08`. Always verify the path against the current junction ref — don't copy a path from another project or branch without confirming the version segment matches.

## lynx fails to build on FDSDK 25.08.13 — use w3m instead

*Source: zirconium-hawaii `92b9cae` — `fix(fdSDK 25.08.13): switch from lynx to w3m`*

lynx completely fails to build on FDSDK 25.08.13 (no diagnostics, just a build failure). zirconium-hawaii switched to `w3m` as the text browser. Krytis currently uses lynx transitively via `elements/desktop/xdg-utils.bst` (the `xmlto`/docbook text-browser toolchain). When krytis bumps to FDSDK 25.08.13+, this may need the same switch — watch for a lynx build failure on the next junction bump.

**Does not apply to krytis.** `elements/desktop/xdg-utils.bst` (krytis's only transitive consumer of lynx-style doc tooling) never invokes `xmlto`/`docbook-xml`/`docbook-xsl`/`lynx` — its `build-commands` generate stub `.txt` synopsis files directly instead of running a real text-browser doc pipeline, and its `build-depends`/`depends` list has no lynx dependency. Confirmed 2026-07-21 while auditing issue #305's migration concerns. No w3m swap needed here (contrast with zirconium-hawaii, where this issue is real).

## Don't hardcode `mesa.bst` as a runtime dep for apps

*Source: zirconium-hawaii `517ff98` — `chore: remove mesa as runtime dependency for apps`*

Convention: don't list `mesa.bst` as an explicit runtime dep for apps. Hardcoding it prevents swapping in `extensions/mesa/mesa-extra.bst` (or krytis's `desktop/mesa-all-codecs.bst` override — see `desktop.md` § AMD VA-API). Let mesa enter the runtime closure transitively via the stack instead. zirconium-hawaii removed it from app elements for this reason.

## Set both OCI annotations and labels

*Source: zirconium-hawaii `d418742` — `fix: set both annotations and labels`*

OCI images need both annotations **and** labels set — not just one or the other. Some tooling reads annotations, some reads labels; setting only one means metadata is invisible to the other set of tools. When assembling the OCI image, set the same metadata in both fields.

## Reserved EFI System Partition Directory Name: `krytis`

Any element whose build requires a distro's reserved ESP subdirectory name (efibootmgr's `EFIDIR`, and similarly for shim/grub-style bootloaders) must use `krytis` — matching `ID` in `elements/core/os-release.bst`. Example (`elements/core/efibootmgr.bst`):

```yaml
variables:
  make-args: EFIDIR=krytis sbindir=%{bindir}
```

efibootmgr bakes this into the binary as the default `--loader` path (`\EFI\krytis\grub.efi`, verify with `--help`). Krytis boots via UKI (see `docs/design/secure-boot-uki.md`), not grub, so this default loader path is currently unused at boot time — but keep it consistent for any future element that needs a reserved ESP dirname, so they don't disagree with each other.

## Building a headless QEMU + OVMF + virt-firmware toolchain for `mise run boot-test`/`boot-vm`

`elements/dev/{qemu,ovmf,virt-firmware}.bst` provide the host-side VM testing
tooling `mise/tasks/{boot-vm,boot-test,generate-ovmf-vars}` expect
(`qemu-system-x86_64`, secure-boot-capable OVMF firmware, `virt-fw-vars`).
Three non-obvious build issues surfaced writing them:

**Don't depend on `gnome-build-meta.bst:core-deps/qemu.bst`.** It's GNOME's
own interactive-desktop-VM recipe — GTK+SDL+spice+virglrenderer+usbredir+
smartcard+pipewire, none of which `-nographic`/monitor-socket/user-netdev
headless testing uses. Build against freedesktop-sdk's own components
directly (`glib`, `pixman`, `libslirp`, `liburing`, `dtc`) instead of pulling
that whole GUI stack in for a CI-style testing tool.

**`dtc` (device tree compiler) is required unconditionally, not just for
ARM/FDT targets.** QEMU's meson.build checks the `dtc` subproject regardless
of `--target-list`; omitting `freedesktop-sdk.bst:components/dtc.bst` from
`depends` fails with `ERROR: Subproject dtc is buildable: NO` followed by a
git-fetch attempt against the sandbox's offline network.

**Pin QEMU to a version that predates the `qemu.qmp` PyPI build dependency.**
Some QEMU 11.x releases' configure/meson step tries to `pip install
qemu.qmp==0.0.5` at configure time for QAPI codegen tooling, which fails
outright in BST's offline sandbox (`Could not provide build dependency
'qemu.qmp==0.0.5'`) — no `python3-qemu-qmp` freedesktop-sdk component exists
to satisfy it locally. `10.1.3` (the exact version
`gnome-build-meta.bst:core-deps/qemu.bst` already pins) predates this and
builds cleanly. The `qemu-update` mise task deliberately restricts its
version-track glob to the `10.x` series for this reason — widening it will
silently reintroduce the build failure. Revisit once a freedesktop-sdk
`python3-qemu-qmp` component exists.

**QEMU's `Makefile` doesn't inherit the autotools plugin's `MAKEFLAGS`
parallelism.** The `autotools` BST plugin sets `MAKEFLAGS: -j%{max-jobs}` in
`environment:` by default, but QEMU's generated `Makefile` just wraps a
single `ninja -C build` recipe — ninja doesn't participate in GNU make's
jobserver protocol, so the build silently runs single-threaded (one `cc1`
process, ~10-20x slower than available cores). Fix: override the `make-args`
variable explicitly with `-j$(nproc)` (shell-evaluated at command-execution
time inside the sandbox, not a BST variable substitution) — check `ps aux |
grep cc1` mid-build to confirm parallelism actually kicked in rather than
trusting the default.

**`freedesktop-sdk.bst:components/ovmf-maybe.bst` always builds with
`-D SECURE_BOOT_ENABLE`.** Unlike Fedora's `edk2-ovmf` package, which ships
separate secboot/non-secboot `OVMF_CODE.fd` variants, freedesktop-sdk's
`ovmf.bst` has exactly one build output regardless of filename — its `opts`
variable hardcodes `SECURE_BOOT_ENABLE` unconditionally. A thin repackaging
wrapper (`kind: manual`, `build-depends: [ovmf-maybe.bst]`, no `sources:`)
can safely alias that single build under both the plain (`OVMF_CODE.fd`) and
secboot (`OVMF_CODE_4M.secboot.fd`) filenames a downstream task searches
for — whether Secure Boot is actually enrolled/enforced at runtime is
entirely determined by the vars file `virt-fw-vars` bakes, not by which
CODE.fd name you point QEMU at.

**`kind: manual` doesn't automatically wire up `freedesktop-sdk-stripper`.**
Unlike `kind: autotools`/`kind: pyproject` (which template in the standard
strip-and-integrate pipeline), a hand-written `kind: manual` element that
only repackages pre-built files (no compilation of its own) fails post-build
with `freedesktop-sdk-stripper: command not found` (exit 127) unless you
either add `components/stripper.bst` as a build-dependency or — the correct
fix when there's genuinely nothing to strip (firmware `.fd` volumes aren't
ELF binaries) — set `strip-binaries: ''` in `variables:` and
`strip-commands: [':']` in `config:` to no-op it, same pattern already used
for pre-built `.deb`/tarball apps (see § .deb extraction in BST sandbox).

## Reclaiming disk when a build hits "Insufficient storage quota"

```
Error capturing "." in ".../cas/staging/cas-tmpdir...":
  Out of space error in merklize() for path ".":
  OutOfSpaceException ... errMsg = "Insufficient storage quota"
```

**This usually is not BST's cache.** BuildStream derives its CAS quota from the
*filesystem* (`buildbox-casd --quota-low=80% --reserved=46.5G`), so a nearly-full disk
makes it refuse to stage regardless of how small its own cache is. When this first bit,
`~/.cache/buildstream` was **27 GB** while `/var` sat at 94% — pruning BST would have
achieved nothing. Check `df -h /var` before `du ~/.cache/buildstream`.

Run **`mise run clean-cache`** (`--dry-run` to look first). It reclaims the two things
that actually accumulate:

| Source | Typical | Why it accumulates |
|---|---|---|
| `/var/tmp/buildah*`, `/var/tmp/container_images_oci*` | tens of GB | Per-build scratch from interrupted `podman build` runs. Nothing reaps it; dirs three weeks old are normal. |
| Dangling (untagged) images | ~7 GB per cycle | Every `mise run build` + `mise run seal-uki` supersedes the previous `krytis:latest`/`:sealed`/`:sealed-base`, orphaning the old layers. |

**Never prune the podman volumes.** `systemd-buildbarn-storage-{cas,ac,fsac}` and
`systemd-buildbarn-asset-cache` (~70 GB) are the Buildbarn cache `mise bst --pull` and
`cache-warm.yml` depend on — pruning them is a self-inflicted cache miss for the whole
project. `clean-cache` never touches volumes or tagged images.

`clean-cache` refuses to run while any `buildah`/`bst` process is live, because
`/var/tmp/buildah*` belongs to an *in-flight* build while it exists. Deleting it
mid-build corrupts that build — the same class of mistake as removing a running
`boot-test`'s WORKDIR (docs/skills/bootc-vm.md § Reading a stalled guest without root).

### Two traps that made `clean-cache` fail exactly when it was needed

**Orphaned `buildbox-fuse` mounts block the safety guard.** A build that dies mid-stage
(including one killed by this very out-of-space error) leaves `buildbox-fuse` processes
holding `~/.cache/buildstream/cas/staging/cas-tmpdir*`. `clean-cache` sees them, decides
a build is in flight, and refuses — but they will never finish. Confirm no driver is
behind them (`pgrep -af 'bst |buildstream.*__main__'` shows only `buildbox-casd`), then
unmount rather than kill; the processes exit on their own once unmounted, and that alone
returned ~8 GB:

```shell
findmnt -rno TARGET | grep buildstream/cas/staging | xargs -r -n1 fusermount -u
rmdir ~/.cache/buildstream/cas/staging/cas-tmpdir* 2>/dev/null
```

**buildah leaves a directory you own but cannot read.** Its per-build `mnt` is mode
`d--x------` — traverse, no read — and `lily:lily`, not root, so **no sudo is needed**:

```console
$ ls -ld /var/tmp/buildah316782609/mnt
d--x------ 1 lily lily 12 /var/tmp/buildah316782609/mnt
```

Both `du` and `rm -rf` fail on it. That used to kill `clean-cache` outright: `du` exits
1, `pipefail` propagates, and `set -e` aborts *after* the assignment is traced — so the
run ended at `==> Disk before:` with **no error message and exit 1**, in the one
situation the task exists for. Fixed by measuring tolerantly and `chmod -R u+rwX`-ing
the scratch immediately before deletion (kept out of `--dry-run`, which must not
mutate). If you hit an older copy of the task, the manual equivalent is:

```shell
chmod -R u+rwX /var/tmp/buildah* /var/tmp/container_images_oci*
```

General lesson for these tasks: under `set -euo pipefail`, `VAR=$(cmd | tail -1)` aborts
the script when `cmd` fails, and because bash traces the assignment first, the failure
looks like it happened on the *next* line. Wrap size probes in `if ! VAR=$(...)`.

One consumer it cannot reclaim: the **root** podman store. `bootc install` copies every
image there via `generate-disk`, and it is invisible to rootless `podman system df`.
Check it with `sudo podman system df`.
