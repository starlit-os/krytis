# Zirconium Hawaii Reference

Load when referencing the sibling project at `../zirconium-hawaii/` — to compare patterns, borrow elements, or understand what a more mature version of this stack looks like.

## What It Is

Zirconium Hawaii is the upstream inspiration for Krytis. Same foundation:

| Aspect | Zirconium Hawaii | Krytis |
|---|---|---|
| Build system | BST 2.5+ | BST 2.5+ |
| Base SDK | Freedesktop SDK | Freedesktop SDK |
| Extra junction | GNOME Build Meta | — |
| Desktop | Niri + Wayland | Niri + Wayland |
| Output | bootc OCI image | bootc OCI image |
| Task runner | `just` (via mise) | `mise` |
| Kernel | Fedora kernel (`core/linux-fedora.bst`) | CachyOS kernel (`core/linux-cachyos.bst`) |
| Secure Boot | Yes — `just generate-keys` | Deferred |
| composefs | Yes — `--composefs-backend` in install | Yes — `--composefs-backend` in install |
| Gaming variant | `zirconium-hawaii-jackrabbit` | — |

## Directory Layout

```
elements/
├── core/           # kernel, greetd, initramfs, bootc, uupd, dkms, tuned
├── config/         # bootc config, system config fragments
├── desktop/        # niri, foot, quickshell, matugen, iio-niri, fonts, ...
├── deps/           # dependency aggregation stacks
├── gamerslop/      # gaming stack (Steam, Gamescope, MangoHUD, SCX schedulers)
├── stacks/
│   ├── base-system.bst
│   ├── bootc.bst
│   ├── codecs.bst
│   ├── desktop.bst
│   └── zirconium.bst   # top-level: all stacks combined
├── oci/
│   ├── zirconium/      # filesystem, image, manifest, runtime, stack, init-scripts
│   └── jackrabbit/     # gaming variant OCI pipeline
└── sysext/         # systemd sysext images
```

## Key Workflows

```bash
# Build and load the main image
just build          # bst build oci/zirconium/image.bst + pkexec podman load

# Final OCI with bootc lint
just build-containerfile          # sudo podman build --squash-all -t zirconium-hawaii:latest .

# Install to a raw disk image
just generate-bootable-image      # 30GB fallocate + bootc install to-disk --composefs-backend

# Generate Secure Boot keys
just generate-keys                # OpenSSL RSA-2048: PK, KEK, DB, VENDOR, linux-module-cert

# Stamp image version
just generate-image-version       # writes include/image-version.yml from git log
```

## Task Runner

Uses `just` (declared in `mise.toml` as a managed tool). The `bst` recipe wraps the bst2 container via rootful podman (`--privileged`). Override the bst2 image with `BST_IMAGE=...`.

Unlike Krytis's mise file tasks, zirconium-hawaii uses `just`'s recipe syntax with positional `$var=default` arguments.

## OCI Assembly Pipeline

Identical pattern to Krytis:

```
stacks/zirconium.bst              (dep aggregator — stack kind)
  ↓
oci/zirconium/filesystem.bst      (compose kind — filters into /layer)
  ↓
oci/zirconium/image.bst           (script kind — prepare-image, sysusers, build-oci)
  ↓
Containerfile: RUN bootc container lint
  ↓
ghcr.io/zirconium-dev/zirconium-hawaii:latest
```

## GNOME Build Meta Junction

Zirconium Hawaii adds a `gnome-build-meta.bst` junction on top of fdsdk. This provides GNOME components directly from upstream builds. Krytis does not use this junction currently.

When a project uses both fdsdk and gnome-build-meta, the `buildstream-plugins` and `buildstream-plugins-community` junctions are loaded in multiple contexts. Fix: add `junctions: internal:` to `project.conf` (see `docs/skills/bst.md` § Multiple Plugin Junction Contexts).

## Custom Plugin: patch_queue

`plugins/patch_queue.py` — a BST source kind that applies a directory of patches in order:

```yaml
sources:
- kind: patch_queue
  path: patches/some-package
```

The patch directory must contain only patch files — any non-patch file (`.gitkeep`, etc.) causes a fatal `git apply` error.

## Desktop Components to Reference

| Element | What it is |
|---|---|
| `desktop/niri.bst` | Niri compositor (Wayland, tiling) |
| `desktop/foot.bst` | Terminal emulator |
| `desktop/quickshell.bst` | Shell/bar framework |
| `desktop/matugen.bst` | Material You color scheme generator |
| `desktop/iio-niri.bst` | IIO sensor integration for Niri |
| `desktop/satty.bst` | Screenshot annotation tool |
| `desktop/ddcutil.bst` | DDC/CI monitor control |
| `core/greetd.bst` | Login manager daemon |

## Secure Boot

Keys are generated locally with `just generate-keys <vendor>` and stored in `files/boot-keys/`. The kernel element signs modules with `linux-module-cert`. Cosign public key is at `cosign.pub` in the repo root.

## composefs

`just generate-bootable-image` passes `--composefs-backend` to `bootc install to-disk`. This works with a regular squashed OCI image — bootc creates composefs from the ostree checkout on the target disk. Chunkah pre-builds composefs layers in the image as an optimisation, but is not required.

**Critical**: always use `podman save --format oci-archive` when copying an image between stores before `bootc install to-disk --composefs-backend`. The default docker-archive format converts OCI layer media types to Docker format, which causes bootc to fail with "Invalid splitstream content type" during composefs setup.

Without `--composefs-backend`, bootc takes the traditional ostree path and requires bootupd. bootupd's `generate-update-metadata` relies on RPM-registered EFI component metadata and fails on non-RPM (BST) builds. The composefs path is the correct approach for BST-built images.

## Removing a Broken Upstream profile.d Script

freedesktop-sdk ships `/etc/profile.d/fcitx5.sh` (fcitx5 is a transitive fdsdk dependency,
so krytis inherits this file too). Without fcitx5 actually configured, the script does
nothing useful and breaks the Steam overlay. zirconium-hawaii's fix is to remove the file
from the image via `remove-files:` in `elements/zirconium/common.bst` rather than patch or
disable it in freedesktop-sdk itself — a narrowly-scoped `remove-files:` on the file, kept
in place until fcitx5 support is actually wired up, not a permanent fix.

## Disabling a Redundant Service via systemd Preset

To drop avahi (redundant once systemd-resolved is in use), zirconium-hawaii doesn't remove
an avahi element — it ships a systemd preset file (`files/systemd-zirconium/10-zirconium.preset`)
that disables `avahi-daemon.service` and `avahi-daemon.socket` by default. This is the right
pattern when the package/element is still installed (e.g. as a transitive dependency you
don't control) but shouldn't run: a preset-file disable is declarative and shows up
alongside other service-default overrides, versus deleting the element outright (which only
works if nothing else depends on it).

## Referencing This Project

When borrowing an element or pattern, copy from `../zirconium-hawaii/elements/` and adapt — don't symlink or junction into zirconium-hawaii from Krytis. Both projects maintain independent BST artifact caches and element trees.

## Porting Elements with Local Files

When a zirconium-hawaii element has a `kind: local` source referencing `files/<name>/`, port those files alongside the element:

- Create `files/<name>/` in krytis with the same contents
- The `local` source `path:` is relative to the project root, so `path: files/i2c-tools` maps to `<krytis-root>/files/i2c-tools/`

Example: `deps/i2c-tools.bst` brings three files — `45-i2c-tools.rules` (udev), `i2c-tools.conf` (modules-load.d), `i2c-tools.sysusers` (sysusers.d).

## ddcutil X11 Dependencies

ddcutil links against X11 at build time if `xorg-lib-x11`, `xorg-lib-xext`, and `xorg-lib-xrandr` are present. On a pure Wayland image these are already available transitively via xwayland. The krytis port includes them explicitly (matching zirconium-hawaii); an `--disable-x11` configure pass could drop them if X11 is confirmed unused at runtime.

## xdg-terminal-exec Install Quirk

The upstream `make install` installs `xdg-terminals.list` to `%{datadir}/xdg-terminal-exec/`. This file is a user-editable priority list for terminal emulators — it must live in `%{docdir}/xdg-terminal-exec/` (documentation, not program data) so it is not overwritten on image updates. Move it immediately after `make install`:

```yaml
config:
  install-commands:
  - |
    make %{make-install-args}
    mkdir -p "%{install-root}%{docdir}/xdg-terminal-exec"
    mv "%{install-root}%{datadir}/xdg-terminal-exec/xdg-terminals.list" \
       "%{install-root}%{docdir}/xdg-terminal-exec"
```
