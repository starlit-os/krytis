---
name: packaging-zig
description: Packages a Zig build system project in BST. Covers zig fetch cache population (HTTP and git deps), DESTDIR pattern, -Dcpu=baseline, and version-split strategy. ghostty.bst is the reference.
---

# Packaging Zig Projects

## Overview

Zig builds are network-isolated in BST. Dependencies declared in `build.zig.zon` must be
pre-fetched and provided as source entries. The pattern uses `kind: remote` sources staged
under `zig-deps/`, followed by a two-stage build that populates the Zig cache before calling
`zig build`. See `elements/desktop/ghostty.bst` for the reference implementation.

## Element skeleton

```yaml
kind: manual

variables:
  strip-binaries: ""

build-depends:
  - desktop/zig.bst
  - freedesktop-sdk.bst:components/pkg-config.bst

depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
  # Main source
  - kind: tar
    url: example_releases:1.0.0/project-1.0.0.tar.gz
    ref: sha256hex...

  # Each zig.zon HTTP dep: one kind: remote per dep, all staged under zig-deps/
  - kind: remote
    url: example_deps:libfoo-abc123.tar.gz
    ref: sha256hex...
    directory: zig-deps

  # Git deps go under zig-deps-git/ and are populated via zig fetch (see lesson below)
  - kind: remote
    url: github_files:owner/repo/archive/sha.tar.gz
    ref: sha256hex...
    directory: zig-deps-git
```

## Build config

```yaml
config:
  build-commands:
    # Stage 1: Set up Zig cache
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"

    # Stage 2: Populate cache from HTTP deps
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      for dep in zig-deps/*; do
        zig fetch --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" "$dep" || true
      done

    # Stage 3: Populate git deps from local Gitea commit tarballs via zig fetch.
    # zig fetch requires a build.zig in cwd. If sources extract to a subdir (e.g.
    # falcond/), use a throwaway sandbox to avoid modifying the real build.zig.zon.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      SOURCE_DIR="$(pwd)"
      mkdir -p /tmp/zig-fetch-sandbox
      touch /tmp/zig-fetch-sandbox/build.zig
      cd /tmp/zig-fetch-sandbox
      for dep in "$SOURCE_DIR"/zig-deps-git/*.tar.gz; do
        zig fetch --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" "$dep"
      done

  install-commands:
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      DESTDIR="%{install-root}" \
      zig build \
        --prefix /usr \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline
```

## Key flags

| Flag | Why |
|---|---|
| `--global-cache-dir` | Override Zig global cache — required for reproducibility |
| `-Dcpu=baseline` | Don't use host-CPU extensions; produces portable binaries |
| `-Doptimize=ReleaseFast` | Max optimization; use `ReleaseSafe` for safety-critical code |
| `-Dpie=true` | PIE — only if `build.zig` defines this option (see lesson below) |
| `DESTDIR="%{install-root}"` with `--prefix /usr` | See lesson below |

## Lessons

### git deps: use `zig fetch <local-tarball>`, not manual cache placement

**Zig 0.16.0**: For `git+https://` deps, Zig 0.16.0 ignores content placed manually in
`p/<hash>/` and attempts a live network fetch regardless. Only entries written by `zig fetch`
itself are recognised. Use `zig fetch --global-cache-dir <dir> <local-tarball>` to populate
the cache — `zig fetch` handles the correct 0.16.0 cache format and metadata internally.

If the Gitea commit archive contains the same content as a `git clone` of that commit (it
should, since Gitea uses `git archive` internally), the content hash `zig fetch` computes will
match the hash in `build.zig.zon` for the corresponding `git+https://` dep and `zig build`
will resolve the dependency from cache.

**Symptom if hashes DO mismatch**: `zig build` will report a hash mismatch (not
NameServerFailure). That means the Gitea archive content differs from what `zig fetch
git+https://` would produce. In that case, patch `build.zig.zon` to use `https://` URLs
pointing at the Gitea archive, with the hash that `zig fetch` output.

**`zig fetch` requires a `build.zig` in the current directory (or a parent).** If the sources
extract to a subdirectory (e.g. `falcond/build.zig` lives under `falcond/` but build-commands
run from the parent), `zig fetch` fails with `error: no build.zig file found`. Use a throwaway
sandbox to satisfy this requirement without touching the real project:

```bash
SOURCE_DIR="$(pwd)"
mkdir -p /tmp/zig-fetch-sandbox
touch /tmp/zig-fetch-sandbox/build.zig
cd /tmp/zig-fetch-sandbox
for dep in "$SOURCE_DIR"/zig-deps-git/*.tar.gz; do
  zig fetch --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" "$dep"
done
```

Projects whose source extracts directly to the staging root (like ghostty) do not have this
problem — ghostty's `build.zig` is at the staging root, so `zig fetch` finds it immediately.

**Zig 0.15.x and earlier**: The `place_git_dep` function (extract tarball into `p/<hash>/`)
did work in 0.15.x. The behaviour change is a 0.16.0 regression/redesign. Do not use
`place_git_dep` for packages built with Zig 0.16.0+.

`tar.bst` and `gzip.bst` are NOT needed in build-depends when using `zig fetch` (Zig handles
decompression internally). They are only needed if using the system `tar` command directly
(e.g., the old `place_git_dep` pattern).

### Use `DESTDIR + --prefix /usr`, not `--prefix %{install-root}/usr`

Zig respects the POSIX `DESTDIR` convention. Using `--prefix "%{install-root}/usr"` bakes
the staging path into installed file contents (.desktop files, .pc files), breaking the image.

### URL aliases for ghostty

`ghostty_deps`, `ghostty_releases`, and `ziglang` must be in `include/aliases.yml`:

```yaml
ghostty_deps: https://deps.files.ghostty.org/
ghostty_releases: https://release.files.ghostty.org/
ziglang: https://ziglang.org/
```

### pika-os git deps (falcond pattern)

falcond's `build.zig.zon` deps are all `git+https://git.pika-os.com/...` — no CDN tarballs. All go
in `zig-deps-git/` and are populated via `zig fetch <local-tarball>`. Add the alias:

```yaml
pikaos_files: https://git.pika-os.com/
```

Archive URL from Gitea: `pikaos_files:<org>/<repo>/archive/<commit-sha>.tar.gz`

In the build commands, run `zig fetch --global-cache-dir ... zig-deps-git/<sha>.tar.gz` for each
dep. Zig computes the content hash and stores the package in the correct 0.16.0 format. If the
Gitea archive content matches the git tree, the hash matches `build.zig.zon` and the build resolves
the dependency offline.

### Source lives in a subdirectory — cd before zig build

If the repo root contains the source in a subdirectory (e.g. `falcond/build.zig`), prefix the
build command with `cd <subdir>`. All commands in a BST `|` block run in the same shell, so `cd`
persists for subsequent lines within that block.

```yaml
install-commands:
  - |
    cd falcond
    DESTDIR="%{install-root}" zig build --prefix /usr ...
```

### `strip-binaries: ""` disables the default strip pass

Ghostty's debug info is intentionally retained (for crash reporting). Set `strip-binaries: ""`
to opt out of BST's default strip step.

### `tar` and `gzip` in build-depends

Only needed if you use the system `tar` binary directly (e.g., the old `place_git_dep` pattern
for Zig 0.15.x). If using `zig fetch <tarball>` (correct pattern for 0.16.0), these are NOT
required — Zig decompresses tarballs internally.

If you do need them (0.15.x compat or other shell tar usage), add:

```yaml
build-depends:
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/gzip.bst
```

Symptom of missing: `sh: line N: tar: command not found` at exit code 127.

### Zig version splits: use a separate element when minimum_zig_version conflicts

Zig is **not backwards-compatible across minor versions**. Each release changes the package cache
hash format. A package pinned to 0.15.x will break silently or loudly under 0.16.x.

**What changes in 0.16.0 that breaks 0.15.x packages:**

`zig build` now extracts packages to a project-local `zig-pkg/` directory instead of reading
directly from the global `p/<hash>/` cache. HTTP deps still land in the global cache via
`zig fetch`, but transitive `git+https://` deps referenced from within those packages are
re-resolved at build time. If their global-cache entry isn't at the hash path 0.16.0 expects,
Zig attempts a live network fetch — which fails inside the BST sandbox. Symptom:

```
error: unable to discover remote git server capabilities: NameServerFailure
    .url = "git+https://github.com/…",
```

**Pattern when two packages need different Zig versions:**

1. Keep `zig.bst` at the version used by the most established / most-transitive package.
2. Create `zig-<version>.bst` (e.g., `zig-0.16.bst`) mirroring `zig.bst` at the new version.
3. Have the newer package reference the versioned element.
4. When the established package (ghostty) is updated to support the newer Zig version, promote
   `zig-<version>.bst` to `zig.bst` and delete the old element.

**Ghostty / Zig 0.16.0 transition note:**

As of ghostty 1.3.x, ghostty builds against Zig 0.15.x. ghostty 1.4 is expected to target
Zig 0.16.0. When updating ghostty to 1.4:

- Run `mise run ghostty-update` to get the new source ref and dep hashes.
- Verify `minimum_zig_version` in the new ghostty `build.zig.zon` says `0.16.0`.
- Promote `zig-0.16.bst` → `zig.bst` (replace its contents in place).
- Delete `zig-0.16.bst`.
- Update `falcond.bst` `build-depends` to reference `zig.bst` again.
- Re-derive all `place_git_dep` hashes for ghostty deps under 0.16.0 (hash format changed).

**Current state (as of 2026-06-28):** `zig.bst` = 0.15.2 (ghostty), `zig-0.16.bst` = 0.16.0
(falcond). Both coexist until ghostty 1.4 ships.

### `-Dpie=true` is project-specific — check `build.zig` first

`-Dpie=true` is not a standard Zig build option. A project only accepts it if `build.zig` explicitly
declares an `addOption` or `option` for `pie`. If the project doesn't declare it, `zig build` exits
with:

```
error: invalid option: -Dpie
```

**Symptom**: build fails in `install-commands`, not in `build-commands` (zig fetch phase succeeds).

**Fix**: Grep `build.zig` for `pie` before adding `-Dpie=true`. If absent, omit the flag — don't
assume it applies because another package (e.g., ghostty) uses it.

ghostty defines `-Dpie`; falcond does not. Do not copy flags blindly across elements.
