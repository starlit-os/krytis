# Gaming Variant — Sysext (Path B)

Status: **implementing** — Path A (full OCI variant) deferred per decision
below. This doc still carries the full investigation for context; see
"Decisions" for what's locked in.

## Two upstream models

### dakota — build-option toggle on a single image

Not a separate element path. One `-o gaming true` project option threads
through the existing pipeline:

- `elements/freedesktop-sdk.bst` overrides `components/linux.bst` →
  `core/linux-ogc.bst` only when `gaming == true` (OpenGamingCollective kernel
  fork: `sched_ext`, `ntsync`, BTF; `core/linux-fdsdk.bst` otherwise).
- `oci/layers/bluefin-stack.bst` conditionally appends `gaming/deps.bst`
  (`gaming/host-platform.bst` + `gaming/flatpak-apps.bst`) to the same stack
  the non-gaming build uses.
- `oci/bluefin.bst` / `oci/bluefin-nvidia.bst` switch `image-repo` under the
  same `(?): - gaming == true:` pattern (`dakota` → `dakota-gaming`,
  `dakota-nvidia` → `dakota-nvidia-gaming`) — same Containerfile, same CI leg,
  different output tag.
- `elements/gaming/public-stacks/{gaming-core,gaming-full}.bst` — two public
  stacks (`gaming-core` = host runtime only: steam-native, gamescope,
  mangohud, vkbasalt, inputplumber, gamescope-session-steam,
  sdl-gamecontrollerdb, i686 compat libs; `gaming-full` = core + curated
  Flathub preinstalls: protontricks, Heroic, Bottles, ProtonPlus, goverlay,
  Lutris) meant for external consumers who junction dakota and want to choose
  their own app delivery.

One build, one Containerfile, one CI matrix leg gated by the option flag.

### zirconium-hawaii — two artifacts, one shared package stack

`elements/gamerslop/*` holds the packages: `steam.bst` (tar, manual version
bump), `gamescope.bst` + `gamescope-session.bst` +
`gamescope-session-steam.bst`, `mangohud.bst`, `scopebuddy.bst`,
`umu-launcher.bst`, `steamos-manager.bst`, `inputplumber.bst` (git_repo,
`track: v*`), `linux-ogc.bst`, plus handheld-specific pieces
(`powerstation.bst`, `powerbuttond.bst`, `valve-hw-audio.bst`,
`xonedo.bst`/`xonedo-dkms.bst`/`xonedo-firmware.bst`, `scx-scheds.bst`,
`scx-tools.bst`). `config/gamerslop.bst` drops local config files. Both
artifacts below consume the same `gamerslop/*` elements — the split is only
in assembly:

**Path A — full OCI variant** (`elements/oci/jackrabbit/*`): `image.bst`,
`filesystem.bst`, `stack.bst`, `manifest.bst`, `init-scripts.bst`,
structurally identical to `oci/zirconium/*` but building on
`stacks/jackrabbit.bst` (= `stacks/zirconium.bst` + all of `gamerslop/*` +
`sysext/jackrabbit/lib32-filter.bst`). Own `image-repo`/tag, own
`integration-commands` (imports `67-gamerslop.just` into the `just` include
chain). A second, complete, independently bootable image.

**Path B — sysext delta** (`elements/sysext/jackrabbit/*`): `deps.bst` is
just the gamerslop package stack (no zirconium base). `layer.bst` builds
*both* sysroots — the base `oci/zirconium/filesystem.bst` output and the
`sysext/jackrabbit/filesystem.bst` output — via two `prepare-image.sh` runs,
then diffs them with `files/sysext/make-layer.py <lower=base> <upper=gaming>
<output>` (walk `upper`, copy anything absent or changed from `lower` into
`output`; walk `lower`, whiteout anything gaming removes). Only the *delta*
is packaged, tagged with `usr/lib/extension-release.d/extension-release.jackrabbit`
metadata, into an erofs `.raw`. This is a real systemd-sysext image —
droppable at `/var/lib/extensions/jackrabbit.raw` on an already-installed
base system, activated by `systemd-sysext refresh`, no reinstall needed.
`sysext/jackrabbit/lib32.bst` + `lib32-filter.bst` cross-compile
fontconfig/libglvnd/libva/libxkbcommon/vulkan-icd-loader/xorg-lib-xinerama/
libdrm/mesa for i686 via `freedesktop-sdk.bst:cross-compilers/freedesktop-sdk-i686.bst`
and split out only the arch-specific paths — 32-bit Steam/Proton GL+Vulkan
runtime support.

## Krytis today (why this shapes the recommendation)

- **CachyOS kernel is already unconditional** (`core/linux-cachyos.bst`,
  prebuilt v3 package). It already ships `sched_ext`
  (`CONFIG_SCHED_CLASS_EXT`) and `ntsync` — that's why `desktop/scx-loader.bst`
  and `desktop/falcond.bst` already work today, with no option gate. Neither
  dakota's `-o gaming` kernel swap nor zirconium's `gamerslop/linux-ogc.bst`
  dependency applies here — **no second kernel, full stop**, per the
  constraint given.
- **Gaming-adjacent packages are already unconditional** in
  `stacks/desktop.bst`: `freedesktop-sdk.bst:components/steam-devices.bst`,
  `desktop/game-devices-udev.bst`, `desktop/falcond.bst`,
  `desktop/scx-loader.bst`. Missing: Steam itself, gamescope, MangoHud,
  InputPlumber, scopebuddy, umu-launcher, 32-bit compat.
- **The sysext refresh mechanism is already wired** —
  `gnome-build-meta.bst:gnomeos/reload-sysext.bst` sits in
  `stacks/base-system.bst` today. It's plumbing with nothing plugged into it;
  a gaming sysext would be the first real consumer.
- **No i686/cross-compiler junction override exists** in
  `elements/freedesktop-sdk.bst` — required before any lib32 element
  (zirconium's `sysext/jackrabbit/lib32.bst` pattern) can be ported.
- **`project.conf` `options:` only has `arch`** — no toggle exists for a
  build-time gaming flag (dakota's model would need one; the zirconium model
  doesn't).
- **Single OCI variant today**: `oci/krytis/*` → `localhost/krytis-input:latest`
  → `Containerfile` → `ghcr.io/starlit-os/krytis`. No nvidia variant, no
  second `publish.yml`/`checks.yml`/`cache-warm.yml` CI leg exists. Either
  path below is new CI surface, not just new elements.
- **Update-path gate**: zirconium's gamerslop mixes source kinds —
  `inputplumber.bst` is `git_repo` with `track: v*` (auto-trackable, gate (a));
  `steam.bst` is `tar` with a manually-bumped `steam_version` variable (needs
  gate (b): a `<name>-update` mise task + `track-bst-sources.yml` job, same
  pattern already used for `linux-cachyos`/`mise`/`falcond`/etc.). Any ported
  element needs this classified before merge, not after.

## Recommendation

Krytis is closer in shape to zirconium-hawaii than dakota — same
niri/greetd/bootc base, no gnome-build-meta gaming junction to lean on, and
(unlike dakota) the sysext refresh plumbing already exists. The user asked
for both an image variant path *and* a sysext path, which is exactly
zirconium's two-artifact/one-package-stack split, not dakota's single-image
option toggle. Recommend mirroring zirconium's structure:

```
elements/
├── gamerslop/                 # packages, ported from zirconium-hawaii/elements/gamerslop/
│   ├── steam.bst
│   ├── gamescope.bst
│   ├── gamescope-session.bst
│   ├── gamescope-session-steam.bst
│   ├── mangohud.bst
│   ├── scopebuddy.bst
│   ├── umu-launcher.bst
│   └── inputplumber.bst       # scope question below covers handheld-only pieces
├── config/
│   └── gamerslop.bst           # local config file drop
├── stacks/
│   └── gamerslop.bst            # dep aggregator: stacks/desktop.bst + gamerslop/* + lib32-filter
├── oci/gamerslop/                # Path A — full alternate bootable image
│   ├── image.bst
│   ├── filesystem.bst
│   ├── stack.bst
│   ├── manifest.bst
│   └── init-scripts.bst
└── sysext/gamerslop/               # Path B — runtime-loadable delta sysext
    ├── deps.bst
    ├── filesystem.bst
    ├── init-scripts.bst
    ├── layer.bst                    # diffs against oci/krytis/filesystem.bst's /usr
    ├── lib32.bst
    └── lib32-filter.bst
```

- No `-o gaming` project option, no kernel branching. CachyOS stays
  unconditional across every image, gaming or not.
- `files/sysext/make-layer.py` ports verbatim — generic diff tool, no
  zirconium-specific logic (confirmed by reading it: pure `os.walk` +
  `shutil.copy2`/whiteout, no hardcoded paths).
- lib32 support requires adding an i686 cross-compiler junction override to
  `elements/freedesktop-sdk.bst` first — a prerequisite, not part of the
  gaming element tree itself.
- Internal element-tree name `gamerslop` kept deliberately — matches the
  vocabulary already used in `docs/skills/zirconium-hawaii.md`, so future
  `upstream-lessons` passes diff cleanly against it. The shippable/user-facing
  name (image tag, sysext filename) is a separate, undecided question below.

## Decisions (resolved 2026-08-06)

1. **Package scope: desktop-only.** No handheld daemons — skip
   `steamos-manager`, `powerstation`, `powerbuttond`, `valve-hw-audio`,
   `xonedo*`, `linux-ogc` (kernel, not needed per the CachyOS point above),
   `scx-scheds`/`scx-tools` (pre-existing gap that scx_loader has no
   scheduler binaries to load is real but predates this work and is out of
   scope here — not gaming-specific). Ported set: `steam`, `gamescope`,
   `gamescope-session`, `gamescope-session-steam`, `mangohud`, `scopebuddy`,
   `umu-launcher`, `inputplumber`.
2. **Sequencing: sysext first, OCI variant deferred.** This doc and the
   landed elements cover Path B only. Path A (`elements/oci/gamerslop/*`,
   `stacks/gamerslop.bst` as a full desktop-stack superset, second
   publish/boot-test/sbom/sign CI leg) is intentionally not built — revisit
   once the sysext ships and the package set is validated in the field.
3. **Steam delivery: native.** Matches both upstreams; required for
   `gamescope-session-steam` integration regardless.
4. **Naming:** sysext artifact is `gamerslop-<arch>.raw`, extension ID
   `gamerslop`, dropped at `/var/lib/extensions/gamerslop.raw` on a running
   base krytis system, activated via `systemd-sysext refresh` (the mechanism
   `gnomeos/reload-sysext.bst` already wires up). OCI variant tag/repo
   naming is deferred along with Path A itself.
5. **nvidia stays out of scope**, confirmed — no nvidia variant exists or is
   introduced by this work.
