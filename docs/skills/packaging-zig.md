---
name: packaging-zig
description: Packages a Zig build system project in BST. Covers two-stage cache population, git-dep manual placement, DESTDIR pattern, and -Dcpu=baseline. ghostty.bst is the reference.
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

  # Git deps go under zig-deps-git/ (cannot use zig fetch — see lesson below)
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

    # Stage 3: Place git deps manually (see lesson below)
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      place_git_dep() {
        local tarball="$1" zig_hash="$2"
        local dest="$ZIG_GLOBAL_CACHE_DIR/p/$zig_hash"
        mkdir -p "$dest"
        tar xf "$tarball" --strip-components=1 -C "$dest"
      }
      place_git_dep "zig-deps-git/<commit-sha>.tar.gz" "<zig-content-hash>"

  install-commands:
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      DESTDIR="%{install-root}" \
      zig build \
        --prefix /usr \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dpie=true
```

## Key flags

| Flag | Why |
|---|---|
| `--global-cache-dir` | Override Zig global cache — required for reproducibility |
| `-Dcpu=baseline` | Don't use host-CPU extensions; produces portable binaries |
| `-Doptimize=ReleaseFast` | Max optimization; use `ReleaseSafe` for safety-critical code |
| `-Dpie=true` | Position-independent executable |
| `DESTDIR="%{install-root}"` with `--prefix /usr` | See lesson below |

## Lessons

### git deps cannot be resolved by `zig fetch` — manual cache placement required

Dependencies declared as `git+https://...` in `build.zig.zon` cannot be fetched by
`zig fetch` from a tarball. Download the commit tarball (e.g., GitHub archive), stage under
`zig-deps-git/`, and extract into the Zig cache at the exact content-hash path the build
expects. The expected hash is the `hash:` field in `build.zig.zon` for that dep.

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
in `zig-deps-git/` (not `zig-deps/`), placed manually via `place_git_dep`. Add the alias:

```yaml
pikaos_files: https://git.pika-os.com/
```

Archive URL from Gitea: `pikaos_files:<org>/<repo>/archive/<commit-sha>.tar.gz`

The `place_git_dep` function is the same as for GitHub git deps (strip-components=1 into
`$ZIG_GLOBAL_CACHE_DIR/p/<zig-hash>/`). Hash values come from the `.hash` field in `build.zig.zon`.

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

### `tar` and `gzip` must be in `build-depends`

The `place_git_dep` helper calls `tar xf` and implicitly decompresses `.tar.gz` via gzip. Neither
`tar` nor `gzip` is available in the BST sandbox by default. Add both explicitly:

```yaml
build-depends:
  - desktop/zig.bst          # or zig-0.16.bst
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/gzip.bst
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
```

Symptom of missing these: `sh: line N: tar: command not found` at exit code 127 during
`place_git_dep`.

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
