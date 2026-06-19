# Plan: Self-Build (Build Krytis from Krytis)

## Goal

Boot a running krytis system (VM or real hardware), clone the git repo, and run the full build pipeline — `mise load-image`, `mise generate-disk`, etc. — to produce a new bootable image without any external dev machine.

This enables offline rebuilds, dog-fooding, and eventually a fully reproducible bootstrap story.

---

## Current gaps

The krytis OCI image does not include the tools needed to run its own build pipeline. Specifically:

| Tool | Why needed | Currently in image? |
|------|-----------|---------------------|
| `git` | `mise run generate-image-version`; cloning the repo | No |
| `mise` | Task runner — every build step goes through it | No (element exists on a branch) |
| `python3.12` + `uv` | BST native runtime; `uv` managed by mise via `mise.toml` | No (mise installs both at `mise install` time) |
| `buildstream` (PyPI) | BST build engine for native path | No (installed into uv venv from repo's `pyproject.toml`) |
| `bubblewrap` | BST sandbox (native path) | Possibly via freedesktop-sdk, unconfirmed |
| `fuse-overlayfs` or `fuse3` | BST overlay sandbox | Possibly via freedesktop-sdk, unconfirmed |
| `lzip` | Decompressor for some BST sources | Unknown |
| `ostree-libs` | BST artifact checkout backend | Possibly via freedesktop-sdk |
| `containers-storage` config | Rootful podman already present; needs correct storage config | Needs verification |

Rootful podman, skopeo, `fallocate` (via `util-linux-full`), `vim`, `wget2`, `jq`, `bash`, `sudo` are already present.

---

## BST approach inside krytis

Native BST via uv. Consistent with the existing plans for CI and local dev (see `docs/plan/native-bst-local-dev.md` and `docs/plan/ci-workflows.md`).

`mise` is present in the image (element on a branch, merged before this lands). When the user clones the repo and runs `mise install`, mise reads `mise.toml` and installs `python = "3.12"` and `uv = "latest"` into its tool cache in `~/.local/share/mise`. From there, `uv sync` creates the venv and installs `buildstream` from `pyproject.toml`+`uv.lock`. No BST2 container pull required.

---

## Required additions to the image

### 1. `git` → `stacks/base-system.bst`

Needed for `generate-image-version` (reads `git log`), cloning the repo, and general usefulness on any developer system — this belongs in the base system, not just the dev-tools stack.

- Check if `freedesktop-sdk.bst:components/git.bst` exists. If so, add it to `stacks/base-system.bst`.
- If absent, add `elements/core/git.bst` (autotools element pointing to the git.kernel.org release tarball).

### 2. `bubblewrap` → `stacks/dev-tools.bst`

BST uses bubblewrap for its build sandbox. Check `freedesktop-sdk.bst:components/bubblewrap.bst`; if present, reference it directly. If absent, add `elements/dev/bubblewrap.bst` (meson element from upstream tarball).

### 3. `fuse-overlayfs` / `fuse3` → `stacks/dev-tools.bst`

BST's sandbox uses FUSE overlay mounts. Confirm whether `freedesktop-sdk.bst` exposes a fuse element. If not, add `elements/dev/fuse-overlayfs.bst` and ensure `/dev/fuse` is accessible at runtime (bootc images inherit the host's device access; this should work by default on a normally-booted Linux system).

### 4. `lzip` → `stacks/dev-tools.bst`

BST's source fetch layer needs this to unpack upstream tarballs that use lzip compression. `gzip`, `xz`, and `bzip2` are very likely in the runtime already via freedesktop-sdk. Verify and add `elements/dev/lzip.bst` (autotools, nongnu.org tarball) if missing.

### 5. `ostree-libs` → `stacks/dev-tools.bst`

BST artifact checkout uses the ostree backend when pulling from remote CAS. Check if it's a transitive dep of something already present (fwupd, dracut) — if so, it's already installed. If not, add explicitly.

---

## New elements to write

| Element | Build system | Source | Notes |
|---------|-------------|--------|-------|
| `elements/core/git.bst` | autotools | git.kernel.org tarball | Only if not in fdo-sdk |
| `elements/dev/bubblewrap.bst` | meson | github:containers/bubblewrap | Only if not in fdo-sdk |
| `elements/dev/fuse-overlayfs.bst` | autotools | github:containers/fuse-overlayfs | Only if not in fdo-sdk |
| `elements/dev/lzip.bst` | autotools | nongnu.org tarball | Only if not already present |

Before writing any of the "only if not in fdo-sdk" elements, audit the freedesktop-sdk junction:

```bash
mise run bst show --deps all stacks/base-system.bst | grep -iE 'bubblewrap|fuse|lzip|ostree'
```

Prefer pulling from the junction over duplicating build logic.

---

## Stack changes

**`stacks/base-system.bst`** — add git:

```yaml
  # ── Core utilities ─────────────────────────────────────────────────
  - core/git.bst
```

**`stacks/dev-tools.bst`** (new file) — BST runtime deps and the mise element:

```yaml
kind: stack

depends:
  - core/mise.bst
  - dev/bubblewrap.bst          # verify not already present via fdo-sdk
  - dev/fuse-overlayfs.bst      # verify not already present via fdo-sdk
  - dev/lzip.bst                # verify not already present
```

`stacks/dev-tools.bst` is included in the OCI image stack (`oci/krytis/stack.bst` or equivalent). Since the image is developer-targeted for now, no project option gate is needed yet.

---

## pyproject.toml + uv.lock inside the repo clone

The self-build workflow requires the BST Python deps (`buildstream`, `click==8.2.1`, `dulwich==0.24.0`, etc.) specified in `pyproject.toml`+`uv.lock` to be present in the cloned repo. These are already planned in `docs/plan/ci-workflows.md`. Once that plan ships, the clone will have them and `mise install` + `uv sync` will create the venv automatically (via `mise.toml`'s `[deps.uv]` block).

---

## Self-build workflow (once image includes the above)

```bash
# 1. Boot krytis (VM or real hardware)

# 2. Clone the repo
git clone https://github.com/starlit-os/krytis.git
cd krytis

# 3. Install python + uv (via mise), then bootstrap the BST venv
mise install

# 4. Validate the element graph
mise run validate

# 5. Build the OCI image (uses native BST; pulls sources + artifacts from
#    the configured caches in project.conf)
mise run load-image

# 6. Apply Containerfile lint
mise run lint

# 7. Write to a disk image
mise run generate-disk

# 8. The resulting bootable.raw can be dd'd to a USB stick or used with
#    bootc switch/upgrade to replace the running system.
```

For a fully offline rebuild (no source/artifact cache access), a prior `bst push` to a local CAS or a pre-seeded `~/.cache/buildstream` is needed. This is out of scope here.

---

## Disk space requirements

| Item | Approximate size |
|------|-----------------|
| BST local artifact cache (`~/.cache/buildstream`) | 20–60 GB |
| BST source cache | 2–5 GB |
| `bootable.raw` output | 30 GB (sparse, actual usage ~5 GB) |
| mise tool cache (python + uv) | ~300 MB |
| uv venv + BST Python deps | ~200 MB |

The running system's root partition must have sufficient free space. For a self-build VM, allocate at least 80 GB total. On real hardware, ensure `/home` or a secondary data partition is large enough — `~/.cache/buildstream` should live on a fast, large volume.

---

## Open questions

### ~~Can `buildstream` run inside a bootc composefs root?~~ — Resolved

**Yes.** Verified by running `mise load-image --container` inside a booted Krytis VM (composefs root). bubblewrap + user namespaces work without a sysctl drop-in. No `kernel.unprivileged_userns_clone` override is needed. Closed as #23.

### ~~SELinux / AppArmor interference~~ — Resolved

No interference observed in practice. The booted image does not ship a MAC policy that restricts bwrap sandboxes.

### Pinning `mise` version

The `mise.bst` element must pin a specific release version and sha256 checksum. Renovate should track it via the `regex` or `github-releases` manager once the element is added. See `docs/plan/renovate-expansion.md` for the expansion plan. `uv` is pinned via `mise.toml` (`uv = "latest"` today; see `docs/plan/mise-tool-versions.md` for the plan to pin tool versions there).

### `mise` shell integration

`mise activate bash` in `/etc/profile.d/` or similar is needed if `mise` should be on `PATH` for all sessions without manual activation. The `mise.bst` element should install a `/etc/profile.d/mise.sh` drop-in (or document that users run `eval "$(mise activate bash)"` in their shell rc).

### Repo access inside the running system

`git clone` over HTTPS requires network access and (for private repos) authentication. For the initial self-build story the repo is public, so HTTPS clone works without credentials. SSH clone requires a key configured in the user's home.
