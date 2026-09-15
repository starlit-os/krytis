# dakota-iso Reference

Load when referencing the sibling live-media project at `../dakota-iso/` — to compare the
ISO/installer pipeline krytis forked out of it, or to understand a lesson mined from it.
Krytis's own pipeline is documented in [`mise.md`](mise.md) § ISO build task and
[`krytis-live-config.md`](krytis-live-config.md); this file is only about upstream.

## What It Is

`projectbluefin/dakota-iso` builds the live installer media for the Bluefin family —
`dakota`, `bluefin`, `bluefin-lts-hwe`, `lts`, `stable`. A `just` project: `just container
<target>` builds the live-environment image, `just iso-sd-boot <target>` assembles the
squashfs + systemd-boot ESP + hybrid ISO, and a `plain-boot-qemu-live` /
`plain-install-qemu` / `plain-boot-qemu-installed` chain drives a QEMU install gate.

Multi-target by a **file-per-value** convention: `<target>/{payload_ref,live_target,tag,
registry,live_title,live_label}`, one line each, read by the justfile. `live/Containerfile`
then builds `FROM ghcr.io/${REGISTRY}/${TARGET}:${TAG}` and runs `src/configure-live.sh`.

Krytis's installer ISO was built by this project until #838/#839 ported the whole call
graph in-tree ([#519](https://github.com/starlit-os/krytis/issues/519) has the file-by-file
BOM and the exclusion list). Krytis is single-target, always composefs + systemd-boot, so
every one of those indirections collapsed to a constant on the krytis side.

## Fork State — there is no fork any more

Krytis tracks `projectbluefin/dakota-iso` **directly**, the way `zirconium-hawaii` is
tracked: the local checkout's `origin` is the upstream repo, and no fork sits in the loop
(`upstream-sync.md` § An `origin` pointing at a fork makes the sync lie explains why that
matters). The `kitten-lily/dakota-iso` fork was reset to upstream and then **deleted** in
#841. Do not re-fork it to make a change here; see § Third-party repositories in
`AGENTS.md`.

That fork carried four krytis-specific commits on `main` (`a5780cf`, `ab94dcf5`,
`8ee95564`, `3d32f848`): the krytis variant, the installer rebrand, sealed-payload support
(`PAYLOAD_SEALED`/`PAYLOAD_REF`, `sealed-test-qemu`, `scripts/e2e-lib.sh`) and the
root-free LUKS install chain — **none of which exist upstream**. All of that logic now
lives in krytis's `mise/tasks/iso-*`, `scripts/` and `live/`, so nothing was lost by the
deletion. The pre-demotion git history is archived twice on the dev host, since GitHub no
longer holds it:

| Where | Contents |
|---|---|
| `../dakota-iso` branch `archive/krytis-fork-main` | `3d32f848` — fork `main` before the reset, all four commits |
| `../dakota-iso` branch `archive/krytis-sealed-payload-support` | `89bb5aa6` — pre-merge branch of the sealed-payload work |
| `../dakota-iso` branch `archive/krytis-luks-passphrase-knob` | `a03f98db` — pre-merge branch of the LUKS work |
| `~/Projects/StarlitOS/dakota-iso-krytis-fork-archive.bundle` | all three of the above, `git bundle verify`-clean ("records a complete history") |

The two feature branches are *not* ancestors of `3d32f848` — they were rewritten on merge,
so they are independent history rather than redundant copies. That is why the archive
carries all three refs and not just `main`. Restore with
`git clone dakota-iso-krytis-fork-archive.bundle` or
`git fetch ../dakota-iso-krytis-fork-archive.bundle 'refs/heads/*:refs/heads/*'`.

## Lessons Mined

### The payload mutation exists three times; only one copy is on any given path

*Source: upstream `scripts/iso-sd-boot.sh:91`, `scripts/build-live-squashfs.sh`,
`live/iso-tools/payload-prep.sh` — all three inject `/usr/lib/bootc/install/00-defaults.toml`*

`iso-sd-boot.sh` has its own inline `buildah run … 00-defaults.toml` injection,
`build-live-squashfs.sh` is a *separate* entry point with a duplicate of the same logic, and
`live/iso-tools/payload-prep.sh` is a third copy for hosts with no host-side buildah. A fix
applied to one is invisible to the other two. Before porting or trusting any payload-prep
behaviour from this repo, `grep -rln 00-defaults.toml` and work out which copy your entry
point actually reaches. Krytis deliberately ported only `payload-prep.sh`, so it has exactly
one — see [`secure-boot.md`](secure-boot.md) § A sealed ISO payload must be embedded
byte-identically.

### `dakota/src/` is a second, divergent copy of `live/src/`

*Source: upstream `dakota/src/build-iso.sh` vs `live/src/build-iso.sh` (different content,
18855 vs 19386 bytes); `dakota/src/show-screenshot.sh` vs `live/src/show-screenshot.sh`
(byte-identical)*

The live image's build context is `./live`, so nothing under `dakota/src/` reaches the ISO
build at all — yet it holds a full, drifted copy of `build-iso.sh` plus its own duplicate of
the dracut module below. A commit landing "in build-iso.sh" may have landed in the
unreachable one. Check the path, not the filename, when mining a change from here.

### The `95dakota-isofile` dracut module is orphaned in both trees

*Source: upstream `live/src/dracut/95dakota-isofile/`, `dakota/src/dracut/95dakota-isofile/`
vs `live/Containerfile:47,87`*

Both copies define a complete dracut module with an `inst_hook initqueue` line, and nothing
adds it: the Containerfile's two `dracut --add` invocations pass `dmsquash-live` only, and no
`dracut.conf`/`modules.d` entry references it for any target. It is dead code upstream, not
a krytis omission — which is why #519 excluded it from the port. Don't read it as the
mechanism by which live media finds its ISO.

### `PAYLOAD_SEALED`, `e2e-lib.sh` and the sealed test chain are not upstream concepts

*Source: upstream `justfile`, `scripts/` — no `sealed-test-qemu` recipe, no `PAYLOAD_SEALED`
handling, no `scripts/e2e-lib.sh`*

Upstream's install gate greps the installed system's serial console for
`Reached target Graphical Interface`, which a sealed (signed-UKI) system can never produce —
its cmdline is frozen, so `console=ttyS0` cannot be injected. Anything about sealed payloads,
byte-identical embedding, or the single-owner `EXIT` trap registry came from the krytis fork
and now lives in krytis. Do not expect a fix for those areas to appear upstream, and do not
file one there.

---

Copy patterns from `../dakota-iso/` and adapt — same convention as
[`dakota.md`](dakota.md) and [`zirconium-hawaii.md`](zirconium-hawaii.md): no symlinking, no
junctioning, no `DAKOTA_ISO_DIR`-style runtime dependency. krytis's ISO pipeline is
self-contained by design since #840.
