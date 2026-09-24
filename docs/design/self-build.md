# Plan: Self-Build (Build Krytis from Krytis)

## Goal

Boot a running krytis system (VM or real hardware), clone the git repo, and run the full build pipeline — `mise load-image`, `mise generate-disk`, etc. — to produce a new bootable image without any external dev machine.

This enables offline rebuilds, dog-fooding, and eventually a fully reproducible bootstrap story.

---

## Tooling gaps — all closed

Every tool the build pipeline needs is in the image today. The table is kept as
the record of what had to be added and where it came from:

| Tool | Why needed | In the image via |
|------|-----------|------------------|
| `git` | `mise run generate-image-version`; cloning the repo | `freedesktop-sdk.bst:components/git.bst` in `stacks/base-system.bst` (#43) |
| `mise` | Task runner — every build step goes through it | `elements/core/mise.bst` (#12), pulled by `stacks/dev-tools.bst` |
| `python3.12` + `uv` | BST native runtime | installed by `mise install` from `mise.toml` `[tools]` into `~/.local/share/mise` |
| `buildstream` (PyPI) | BST build engine for native path | uv venv built from the repo's `pyproject.toml` + `uv.lock` |
| `bubblewrap` | BST sandbox (native path) | `freedesktop-sdk.bst:components/bubblewrap.bst` |
| `fuse-overlayfs` | BST overlay sandbox | `freedesktop-sdk.bst:components/fuse-overlayfs.bst` |
| `lzip` | Decompressor for some BST sources | `freedesktop-sdk.bst:components/lzip.bst` |
| `ostree` | BST artifact checkout backend | transitively via `core/bootc.bst`. `ostree-minimal` is deliberately *not* in `dev-tools.bst`: it overlaps the full `components/ostree.bst` at `oci/krytis/runtime.bst` (#49) |
| `containers-storage` config | Rootful podman already present; needs correct storage config | **still unverified** — the one row of this table nobody has checked on a booted image |

Rootful podman, skopeo, `fallocate` (via `util-linux-full`), `vim`, `wget2`, `jq`, `bash`, `sudo` are already present.

---

## BST approach inside krytis

Native BST via uv. Consistent with the existing plans for CI and local dev (see `docs/design/native-bst-local-dev.md` and `docs/plans/done/2026-06-17-ci-workflows.md`).

`mise` ships in the image (`elements/core/mise.bst`, a prebuilt musl-static binary — see `docs/skills/mise.md` § The shipped `mise` is musl-static). When the user clones the repo and runs `mise install`, mise reads `mise.toml` and installs the pinned `python` and `uv` into its tool cache in `~/.local/share/mise`. From there, `uv sync` creates the venv and installs `buildstream` from `pyproject.toml`+`uv.lock`. No BST2 container pull required.

---

## How each addition landed

### 1. `git` → `stacks/base-system.bst`

Needed for `generate-image-version` (reads `git log`), cloning the repo, and general usefulness on any developer system — it belongs in the base system, not just the dev-tools stack.

The junction had it: `stacks/base-system.bst` depends on
`freedesktop-sdk.bst:components/git.bst` (#43). No krytis-owned `git` element was needed.

### 2–4. `bubblewrap`, `fuse-overlayfs`, `lzip` → `stacks/dev-tools.bst`

BST uses bubblewrap for its build sandbox, FUSE overlay mounts inside it, and lzip
to unpack upstream tarballs that use lzip compression. All three exist in the
junction and are referenced directly from `stacks/dev-tools.bst`
(`freedesktop-sdk.bst:components/{bubblewrap,fuse-overlayfs,lzip}.bst`), plus
`components/patch.bst`. `/dev/fuse` access at runtime works by default on a
normally-booted Linux system; bootc images inherit the host's device access.

### 5. `ostree` → already transitive

BST artifact checkout uses the ostree backend when pulling from remote CAS.
`core/bootc.bst` already brings in the full `freedesktop-sdk.bst:components/ostree.bst`,
which is a superset of `ostree-minimal` — adding the minimal variant caused
non-whitelisted overlaps at `oci/krytis/runtime.bst` and was removed again in #49.

---

## New elements to write: none

All four "only if not in fdo-sdk" candidates (`git`, `bubblewrap`, `fuse-overlayfs`,
`lzip`) turned out to exist in the freedesktop-sdk junction, so krytis writes none of
them. The audit that settled it is still the right first step for any future addition:

```bash
mise run bst show --deps all stacks/base-system.bst | grep -iE 'bubblewrap|fuse|lzip|ostree'
```

Prefer pulling from the junction over duplicating build logic.

---

## Stack changes — as shipped

`stacks/base-system.bst` carries `freedesktop-sdk.bst:components/git.bst` alongside the
rest of the core utilities.

`stacks/dev-tools.bst` is the self-build stack, and it grew past the original sketch —
it now also carries the ISO-build host tools (`squashfs-tools`, `mtools`, `dosfstools`,
`rsync`) for `mise run build-iso` and the VM-boot-test tools (`dev/qemu.bst`,
`dev/ovmf.bst`, `dev/virt-firmware.bst`) for `mise run boot-vm` / `boot-test` (#382).
`buildah` and `xorriso` have no freedesktop-sdk component and run from a podman
build-tools container instead (see `docs/skills/mise.md` § ISO build task).

`stacks/dev-tools.bst` is pulled into the OCI image by `oci/krytis/stack.bst`. Since the
image is developer-targeted, no project option gate is needed.

---

## pyproject.toml + uv.lock inside the repo clone

The self-build workflow requires the BST Python deps (`buildstream`, `click`,
`dulwich`, etc.) specified in `pyproject.toml`+`uv.lock`. Both files are committed at
the repo root, so a fresh clone has them and `mise install` + `uv sync` creates the venv
automatically (via `mise.toml`'s `[deps.uv]` block).

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

### Pinning `mise` version — done

`elements/core/mise.bst` pins an exact release URL + sha256 per architecture. Renovate
does not track it; the `track-mise` job in `.github/workflows/track-bst-sources.yml` does,
opening a manual-merge PR on each upstream release. `python` and `uv` are pinned to exact
versions in `mise.toml` `[tools]` and bumped by Renovate's `mise` manager (#24/#25) — see
`docs/design/renovate-expansion.md`.

### `mise` shell integration — done

`elements/core/mise.bst` installs `/etc/profile.d/mise.sh` and `mise.zsh` (each guarded by
`command -v mise` so a broken binary cannot break interactive shells) plus
`/usr/share/fish/vendor_conf.d/01-mise.fish` and fish completions. `mise` is on `PATH`
for all users with no manual activation.

### Repo access inside the running system

`git clone` over HTTPS requires network access and (for private repos) authentication. For the initial self-build story the repo is public, so HTTPS clone works without credentials. SSH clone requires a key configured in the user's home.
