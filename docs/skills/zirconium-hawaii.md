# Zirconium Hawaii Reference

Load when referencing the sibling project at `../zirconium-hawaii/` — to compare patterns, borrow elements, or understand what a more mature version of this stack looks like.

## What It Is

Zirconium Hawaii is the upstream inspiration for Krytis. Same foundation:

| Aspect | Zirconium Hawaii | Krytis |
|---|---|---|
| Build system | BST 2.5+ | BST 2.5+ |
| Base SDK | Freedesktop SDK | Freedesktop SDK |
| Extra junction | GNOME Build Meta | GNOME Build Meta |
| Desktop | Niri + Wayland | Niri + Wayland |
| Output | bootc OCI image | bootc OCI image |
| Task runner | `just` (via mise) | `mise` |
| Kernel | Fedora kernel (`core/linux-fedora.bst`) | CachyOS kernel (`core/linux-cachyos.bst`) |
| Secure Boot | Yes — `just generate-keys` | Yes — `mise run generate-keys` + `mise run seal-uki`/`sign` (see `secure-boot.md`, `signing.md`) |
| composefs | Yes — `--composefs-backend` in install | Yes — `--composefs-backend` in install |
| Gaming variant | `zirconium-hawaii-jackrabbit` | — |

## Directory Layout (zirconium-hawaii's `elements/`, not krytis's)

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

Uses `just` (declared in zirconium-hawaii's own `mise.toml` as a managed tool). The `bst` recipe wraps the bst2 container via rootful podman (`--privileged`). Override the bst2 image with `BST_IMAGE=...`.

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

Zirconium Hawaii adds a `gnome-build-meta.bst` junction on top of fdsdk. This provides GNOME components directly from upstream builds. Krytis junctions it too (`elements/gnome-build-meta.bst`, tracking `gnome-51`) and leans on it hard — `elements/stacks/base-system.bst` pulls seven `gnomeos-deps/*` elements from it, and `elements/freedesktop-sdk.bst`'s `config.overrides:` redirects ~20 `components/*.bst` at `gnome-build-meta.bst:sdk/*` equivalents.

When a project uses both fdsdk and gnome-build-meta, the `buildstream-plugins` and `buildstream-plugins-community` junctions are loaded in multiple contexts. Fix: add `junctions: internal:` to `project.conf` (see `docs/skills/bst.md` § Multiple Plugin Junction Contexts).

## Custom Plugin: patch_queue

zirconium-hawaii's `plugins/patch_queue.py` — a BST source kind that applies a directory of patches in order. Krytis gets the same source kind from the `buildstream-plugins-community` junction instead (declared in `project.conf`'s `plugins:` block), not from a vendored copy:

```yaml
sources:
- kind: patch_queue
  path: patches/some-package
```

The patch directory must contain only patch files — any non-patch file (`.gitkeep`, etc.) causes a fatal `git apply` error.

## Desktop Components to Reference

All paths below are under zirconium-hawaii's `elements/`:

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

Keys are generated locally with `just generate-keys <vendor>` and stored in zirconium-hawaii's `files/boot-keys/`. The kernel element signs modules with `linux-module-cert`. Cosign public key is at `cosign.pub` in that repo's root. (Krytis's own `files/boot-keys/` is the same layout, populated by `mise run generate-keys` and gitignored — see `secure-boot.md`.)

## composefs

`just generate-bootable-image` passes `--composefs-backend` to `bootc install to-disk`. This works with a regular squashed OCI image — bootc creates composefs from the ostree checkout on the target disk. Chunkah pre-builds composefs layers in the image as an optimisation, but is not required.

**Critical**: always use `podman save --format oci-archive` when copying an image between stores before `bootc install to-disk --composefs-backend`. The default docker-archive format converts OCI layer media types to Docker format, which causes bootc to fail with "Invalid splitstream content type" during composefs setup.

Without `--composefs-backend`, bootc takes the traditional ostree path and requires bootupd. bootupd's `generate-update-metadata` relies on RPM-registered EFI component metadata and fails on non-RPM (BST) builds. The composefs path is the correct approach for BST-built images.

## Removing a Broken Upstream profile.d Script

freedesktop-sdk ships `/etc/profile.d/fcitx5.sh` (fcitx5 is a transitive fdsdk dependency,
so krytis inherits this file too). Without fcitx5 actually configured, the script does
nothing useful and breaks the Steam overlay. zirconium-hawaii's fix is to remove the file
from the image via `remove-files:` in its `elements/zirconium/common.bst` rather
than patch or disable it in freedesktop-sdk itself — a narrowly-scoped `remove-files:` on the
file, kept in place until fcitx5 support is actually wired up, not a permanent fix.

## Disabling a Redundant Service via systemd Preset

To drop avahi (redundant once systemd-resolved is in use), zirconium-hawaii doesn't remove
an avahi element — it ships a systemd preset file (its own
`files/systemd-zirconium/10-zirconium.preset`)
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

## Ported-element drift — upstream keeps editing the element you copied

*Source: zirconium-hawaii `87e2291` — "chore: use buildsystem stacks for elements it applies to"*

A ported element freezes in the shape it had on copy day. Upstream's copy does not. This
is the failure mode of the section above: porting is a one-shot fork, and nothing tells
you later that the original moved.

Concrete instance in this range. fdsdk 26.08 added `public-stacks/buildsystem-rust.bst`
and `public-stacks/buildsystem-python-{setuptools,hatchling}.bst`, so a hand-rolled
build-dep list (`stripper` plus `python3-build`, `python3-installer`,
`python3-setuptools`, `python3-wheel`) collapses to one line. zirconium migrated 19
elements in this commit, `deps/i2c-tools.bst` among them — its build-depends are now
just `public-stacks/buildsystem-make.bst` plus
`public-stacks/buildsystem-python-setuptools.bst`.

krytis's `elements/deps/i2c-tools.bst:11-19` — the port named in the section above —
still carries the pre-migration eight-entry list (`runtime-gnu`, `make`, `gcc`,
`stripper`, and the four `python3-*` components). `elements/dev/virt-firmware.bst:10`
already build-depends on `freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst`,
so the stack resolves on krytis's current fdsdk pin — this is a simplification available
today, not a version gate.

The general move for an `upstream-lessons` pass: for each element krytis ported, diff it
against upstream's current copy rather than only reading new commits. Drift accumulates
in elements that never appear in a changed-file list you are looking at.

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

## Gaming trees (`gamerslop`, `jackrabbit`) — deliberately not ported

Upstream's gaming support is three directories: `elements/gamerslop/*`
(packages), `elements/sysext/jackrabbit/*` (a systemd-sysext delta), and
`elements/oci/jackrabbit/*` (a second bootable image). **krytis has no
counterpart to any of them, by decision** — gaming is delivered through
Flatpak instead. See `docs/design/gaming-variant.md` for the full comparison
and the reasons.

**Do not report these as a downstream gap during an `upstream-lessons` pass.**
There is no name mapping to look for: krytis has no `gaming`/`jackrabbit`
element tree at all. The same applies to dakota's `elements/gaming/*` and its
`-o gaming` project option.

A working port of the sysext path (Path B) does exist, unmerged and unbuilt, in
closed PR #522. Its branch is deleted, but the commit survives at
`refs/pull/522/head` (`e2e871c`) — `git fetch origin refs/pull/522/head`. Start
from there rather than re-porting from upstream if this is ever revisited.

Two upstream-specific details worth keeping, since they are the parts that do
not exist anywhere in krytis:

**The dual-sysroot diff is how upstream builds a sysext.** zirconium-hawaii's
`elements/sysext/jackrabbit/layer.bst` runs `prepare-image.sh` **twice** — once for the
base `elements/oci/zirconium/filesystem.bst` sysroot, once for
`elements/sysext/jackrabbit/filesystem.bst` (base + gaming) — then diffs them with its
`files/sysext/make-layer.py <lower> <upper> <output>` and packages only the
delta as an erofs `.raw` tagged with
`usr/lib/extension-release.d/extension-release.<id>`. `make-layer.py` is
generic (pure `os.walk` + `shutil.copy2` + whiteouts, no upstream-specific
paths), so it ports verbatim for any future sysext. krytis used to carry the
activation half (`gnome-build-meta.bst:gnomeos/reload-sysext.bst` in
`elements/stacks/base-system.bst`, with no consumer) but gnome-build-meta deleted that
element between `gnome-50` and `master` with no replacement, so krytis dropped it — see
the comment left in `elements/stacks/base-system.bst`. A sysext port now needs its own
reload trigger, or confirmation that systemd v261 (fdsdk 26.08) handles it natively.

**32-bit support is a cross-compile + filter pair.** zirconium-hawaii's
`elements/sysext/jackrabbit/lib32.bst` builds fontconfig, libglvnd, libva,
libxkbcommon, vulkan-icd-loader, xorg-lib-xinerama, libdrm and mesa against
`freedesktop-sdk.bst:cross-compilers/freedesktop-sdk-i686.bst`, and its
`lib32-filter.bst` (`kind: filter`) splits out only the arch-specific paths.
krytis has **no i686 cross-compiler junction override** in
`elements/freedesktop-sdk.bst`, so this is a prerequisite, not a copy.

## `git_repo` `exclude:` for a broken upstream tag

*Source: zirconium-hawaii `7b4bf41` — "chore: pin bootc by excluding 1.16.7"*

A `ref:` downgrade alone doesn't stick on a `track: v*` source — the next
`bst source track` run will happily re-resolve to a known-bad tag unless it's also listed
in `exclude:`. zirconium hit a broken bootc v1.16.7 and pinned around it with:

```yaml
- kind: git_repo
  url: github:bootc-dev/bootc.git
  track: v*
  ref: v1.16.6-0-gcf828dc1ec9eb4cac647992a2b09b3a67e5b8868
  exclude:
  - v1.16.7
```

Full writeup in `docs/skills/bst.md` § `git_repo` tracking: excluding a bad tag, and
patching ahead of a vendored ref. Krytis's own `elements/core/bootc.bst` tracks `v*` on
the same upstream project with no `exclude:` today — same exposure if a future point
release ships broken.

## Patching a junction's own vendored source pin

*Source: zirconium-hawaii `30febd5`, `5cb27df`*

A `patch_queue` entry against a junction (e.g. `freedesktop-sdk.bst`) can bump one of the
junction's own internal vendored source pins (freedesktop-sdk's
`elements/extensions/mesa/mesa-sources.yml` and `elements/include/ostree-source.yml`)
directly, landing a point-fix immediately instead of
waiting for krytis's own junction ref to advance past a known-bad upstream version — which
can drag in weeks of unrelated changes. Full writeup and the cache-key tradeoff (see the
"Patch queues on junctions destroy upstream cache reuse" entry in `docs/skills/dakota.md`)
in `docs/skills/bst.md` § `git_repo` tracking. The two specific bugs that motivated this
upstream (mesa 26.1.6, ostree v2026.3) are already fixed in krytis's current fdsdk pin
(`freedesktop-sdk-26.08.1`) — recorded as a technique for the next time this happens, not
an action item today.

Also new upstream: a second junction, zirconium-hawaii's `elements/freedesktop-sdk-extra.bst`
(`kind: junction`, tracks `freedesktop-sdk-extra.git`), added purely to reuse a
pre-packaged component (smartmontools) instead of writing a new element from scratch — uses
the same `config.overrides:` mechanism this file already documents for `gnome-build-meta`
(§ GNOME Build Meta Junction), applied to a second junction. Not adopted — krytis has no
current need for smartmontools — but worth knowing the pattern exists if a future package
is already packaged there.

## Audit: full `mesa.bst` vs `mesa-headers.bst` in `build-depends`

*Source: zirconium-hawaii `3b5af5d` — "mesa-headers is good enough for the build, we don't need full fat mesa"*

zirconium dropped `freedesktop-sdk.bst:extensions/mesa/mesa.bst` from `build-depends`
(kept only in `depends` for runtime linking) across 7 elements that already also had
`components/mesa-headers.bst`, cutting build-sandbox size with no behavior change. Full
writeup and the explicit caveat against a blind swap in `docs/skills/bst.md` § C library
deps and Mesa. Krytis's `desktop/niri.bst`, `desktop/cage.bst`, `desktop/wlroots.bst`, and
`desktop/noctalia-greeter.bst` all build-depend on full `mesa.bst` per this file's own
documented "always both" rule — worth a per-element spot-check, not a mechanical change.

## xwayland-satellite: patch the regression, don't pin behind it

*Source: zirconium-hawaii `9cf2c6a`, `de344f0` — "Update xwayland-satellite to 0.8.2 with patches"*

**This supersedes the earlier "pin to 0.8.1" guidance** (zirconium `4a3f63a`), which is no
longer upstream's position. 0.8.2 carries fixes worth having over 0.8.1, and both of its
regressions are patchable, so zirconium moved to `ref: v0.8.2-0-g8d135d3…`, re-enabled
`track: v*`, and added a `kind: patch_queue` source on `patches/xwayland-satellite/`
holding two patches cherry-picked from upstream `main`:

| Patch | Fixes |
|---|---|
| `0002-fix-never-focus-override-redirect-popups-offer-WM_TA.patch` | Steam drop-downs closing immediately — upstream [#468](https://github.com/Supreeeme/xwayland-satellite/issues/468), i.e. the exact bug the 0.8.1 pin existed for. Originally upstream PR 494; `de344f0` re-pointed the patch at the commit as merged to `main`. |
| `0001-fix-classify-resizable-DIALOG-windows-as-toplevel-no.patch` | Resizable `DIALOG` windows classified as popup instead of toplevel, so DaVinci Resolve's Project Manager and Qt/GTK file dialogs never appear — upstream #470. |

**krytis has not moved.** `elements/desktop/xwayland-satellite.bst` is still
`ref: v0.8.1-0-g536bd32…` (`:81`) with `exclude: [v0.8.2]` (`:79-80`) and
`# track: 'v*'` commented out behind a FIXME (`:76-78`). The only file in
`patches/xwayland-satellite/` is `bump-time-ghsa-r6v5-fh4h-64xc.patch`; neither upstream
patch is present. Adopting them means switching that `kind: patch` to a `kind: patch_queue`
over the whole directory — which then also carries the `time` GHSA patch, so ordering in
the directory matters and the dir must stay patch-files-only (§ Custom Plugin: patch_queue
above). The `VERGEN_GIT_DESCRIBE` handling in that element is unaffected: it already
neutralises the `-dirty` marker any number of patches would produce.

**The real lesson is the exit condition.** That element's header comment (`:13-19`) says
to re-enable tracking "once issue #468 is fixed and a new release ships the fix", and
gates dropping the vendored element entirely on "#468 is fixed (meaning v0.8.2 is no
longer the latest)". #468 *is* fixed — as a commit merged to `main`. No tag carries it,
and v0.8.2 is still the latest release. A condition written against a *release event*
cannot be discharged by a *merged fix*, so the workaround outlives its
cause and nobody re-reads it, because on its own terms it is still unmet. Write removal
conditions against the fix being available in a form you can consume — merged commit,
backportable patch, or tag — not against upstream cutting a release.

## Arch-derived kernel configs don't create `/sys/fs/selinux`

*Source: zirconium-hawaii `df54ad2` — "linux-ogc: Use fedora's kernel config as the base"*

A kernel built from Arch's config never creates `/sys/fs/selinux`. On a system that does
not use SELinux this is invisible — until a podman container **created on a Fedora host**
is moved over. Such containers record `/sys/fs/selinux` as a bind-mounted volume, and with
the directory absent the container cannot start at all. That makes it a distrobox/toolbox
failure, not a kernel one, which is why it is hard to trace back to the kernel config.
freedesktop-sdk's own kernel config *does* create the directory, so an eventual switch to
the fdsdk config closes this without any explicit fix.

**krytis exposure.** `elements/core/linux-cachyos.bst` unpacks prebuilt CachyOS
`.pkg.tar.zst` packages — an Arch-derived config, with no config step krytis controls —
and krytis ships toolbox (`gnome-build-meta.bst:gnomeos-deps/toolbox.bst` via
`elements/stacks/base-system.bst:139`). Grep across `elements/`, `docs/` and
`files/fakecap-manifest.tsv` for `fs/selinux` returns exactly one hit, a Rust source path
inside bootc's debug split — nothing creates or expects the directory. Upstream's own
element here is `elements/gamerslop/linux-ogc.bst`, in the gaming tree krytis deliberately
does not port, but the config lineage and the failure are the same.

Worth knowing for its own sake: this lesson is four paragraphs into the body of a commit
whose subject is only "use Fedora's kernel config as the base". **zirconium-hawaii has no
`docs/` tree, no `AGENTS.md`, and no skills directory** — its entire distilled knowledge
lives in commit bodies, and several of them contradict or retract their own subject lines.
Reading only subjects and diffs on this upstream loses most of what it knows.

## Container signature policy belongs in `/usr/share/containers`

*Source: zirconium-hawaii `4229691`, `d4e641b`, `f251073`*

zirconium ships a container `policy.json` and learned three things doing it: use
`%{datadir}/containers`, not the mutable `/etc/containers`; fdsdk's own
`/etc/containers/policy.json` silently overrides yours (its unsigned images stayed
pullable because of it); and bootc's ostree backend breaks on a `"default"` of
`insecureAcceptAnything`. All three bear directly on krytis #418 and on the never-written
`container-sigpolicy.bst` sketched in `docs/design/cosign-keyless-signing.md` §4. Full
writeup, including the `integration-commands` fix and krytis's own inherited
`/etc/containers` files, in `docs/skills/signing.md` § Where a `policy.json` has to live,
and why the sketched path is wrong.
