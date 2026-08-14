# Gaming Delivery — Native Sysext Investigated, Flatpak Chosen

Status: **native paths abandoned (2026-08-14)**. Gaming support is delivered by
improving the **Flatpak** experience, not by a native `elements/gaming/`
package tree, not by a systemd-sysext delta, and not by a second bootable OCI
variant.

This doc is kept as the investigation record: it says what the two sibling
upstreams do, which krytis facts constrain any gaming work, why the native
route was dropped, and which of those facts still bind the Flatpak route.

## Outcome

| Path | Verdict |
|---|---|
| **Flatpak** — Steam/Heroic/Bottles/etc. from Flathub, host runtime already present | **chosen** |
| **Path B** — systemd-sysext delta (`elements/sysext/gaming/*`) | abandoned |
| **Path A** — full alternate bootable OCI variant (`elements/oci/gaming/*`) | abandoned (was already deferred) |
| dakota's `-o gaming` build-option toggle | rejected |
| **`gamescope-session`** as a greetd session entry (+ `gamescope-session-steam`) | rejected — no couch/handheld mode wanted, niri stays the only session |

An implementation of Path B existed and is recoverable: PR
[#522](https://github.com/starlit-os/krytis/pull/522) (closed unmerged), branch
`feat/gamerslop-sysext` at `e2e871cd34f87187e59155b3543a16ad2f7b4edd` — 34
files, 8 `gaming/*` packages, 6 `deps/*` build deps, the dual-sysroot diff
tooling (`files/sysext/make-layer.py`), `mise/tasks/build-sysext-gaming`, and
262 lines of `track-bst-sources.yml` update-path jobs. Its element graph
resolved (1126 elements); it was **never built and never booted**. Anyone
reviving native gaming packages should start from that commit rather than
re-porting from upstream.

### Why the native route was dropped

- **Cost is carried forever, in the base image graph.** Even scoped to Path B,
  the port added 8 gaming packages plus 6 shared build deps
  (google-benchmark, libxres, luajit, libiio, libserialport, glfw) into the
  shared element graph, an i686 cross-compiler junction override for 32-bit
  Steam/Proton, a vendored meson-subproject shim plus an upstream patch for
  gamescope's fork, and 262 lines of bespoke update-path CI because three of
  the sources are `tar`-pinned and two are `cargo2` (see AGENTS.md § Update
  path gate). Flathub carries all of that upstream.
- **Nothing had been proven.** Graph resolution is not a build. The remaining
  work was a cold-cache build of gamescope's OGC fork with
  wlroots/libliftoff/vkroots/openvr/reshade submodules plus a full i686
  toolchain, then a boot + `systemd-sysext refresh` smoke test — before the
  first line of user-visible benefit.
- **Sysext is the wrong delivery shape for apps.** A sysext delta is a `/usr`
  overlay refreshed by `systemd-sysext refresh`; it updates on krytis's release
  cadence, not Steam's or Proton's. Flatpak updates per-app, per-user, and
  `config/starlit-update.bst` already refreshes system Flatpaks on a daily
  timer.
- **32-bit compat comes free.** The single largest chunk of the port —
  cross-compiling fontconfig/libglvnd/libva/libxkbcommon/vulkan-icd-loader/
  xorg-lib-xinerama/libdrm/mesa for i686 and filtering out the arch-specific
  paths — exists only to run 32-bit Steam and Proton titles. The Flatpak Steam
  runtime ships its own 32-bit stack.

### What the Flatpak route inherits from this investigation

- **The host Vulkan/GL path must stay correct**, because Flatpak apps use the
  host driver. `freedesktop-sdk.bst:components/compat-vulkan-link.bst` is
  already in the desktop stack for exactly this reason (see
  `docs/skills/bst.md` § Vulkan ICD discovery with fdsdk mesa). Zink,
  direct-Vulkan apps, and Flatpak Steam all depend on it.
- **Kernel-side gaming support is already unconditional** — see "Krytis today"
  below. `sched_ext` + `ntsync` + `falcond` + `scx-loader` need no gaming
  variant, and Proton's WOW64/ntsync path works against them.
- **`gamescope-session` is out of scope — decided, not deferred (2026-08-14).**
  A gamescope session as a greetd entry is the one gaming capability Flatpak
  genuinely cannot deliver (it needs a system-level session desktop entry and a
  native `gamescope`), and krytis does not want it. There is no couch or
  handheld mode on the roadmap; niri stays the only session. This also settles
  `gamescope-session-steam` and, with it, the last argument for native Steam —
  Flatpak Steam has no session to integrate with. Do not reopen this as a
  side-effect of some other gaming change.
- **`scx_loader` has no schedulers to load** — tracked separately, not
  gaming-specific. Live on 2026-08-14: `scx_loader.service` is active and
  advertises 13 `SupportedSchedulers` over `org.scx.Loader`, `/usr/bin` holds
  no `scx_*` binary but the loader itself, and `/sys/kernel/sched_ext/state`
  reads `disabled`. Nothing errors today only because every shipped falcond
  profile sets `scx_sched = none` and `scx_loader`'s `default_sched` is
  commented out. See issue #590.
- **App pre-installs have a home already**: `elements/config/flatpak-preinstall.bst`
  (marker-file-gated oneshot, see `docs/skills/bst.md` § Flatpak Pre-install
  Service Pattern) and the Flathub remote via
  `gnome-build-meta.bst:gnomeos-deps/flathub-config.bst`. A gaming app set is
  a list change there, not a new subsystem. dakota's `gaming-full` public stack
  is the same idea and a useful list to crib: protontricks, Heroic, Bottles,
  ProtonPlus, goverlay, Lutris.
- **`gnomeos/reload-sysext.bst` remains plumbing with no consumer.** It sits in
  `stacks/base-system.bst` today. Nothing here changes that; the first real
  sysext consumer is still unwritten.

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

`make-layer.py` is generic — pure `os.walk` + `shutil.copy2`/whiteout, no
zirconium-specific paths — so it ports verbatim if a sysext is ever wanted for
something else.

## Krytis today (the facts that constrained every option)

Each of these was verified when this investigation ran; they still hold.

- **CachyOS kernel is already unconditional** (`core/linux-cachyos.bst`,
  prebuilt v3 package). It already ships `sched_ext`
  (`CONFIG_SCHED_CLASS_EXT`) and `ntsync` — that's why `desktop/scx-loader.bst`
  and `desktop/falcond.bst` already work today, with no option gate. Neither
  dakota's `-o gaming` kernel swap nor zirconium's `gamerslop/linux-ogc.bst`
  dependency applies here — **no second kernel, full stop**.
- **Gaming-adjacent packages are already unconditional** in
  `stacks/desktop.bst`: `freedesktop-sdk.bst:components/steam-devices.bst`,
  `desktop/game-devices-udev.bst`, `desktop/falcond.bst`,
  `desktop/scx-loader.bst` — though the loader has no schedulers to load
  (#590). Absent natively: Steam, gamescope, MangoHud, InputPlumber,
  scopebuddy, umu-launcher, 32-bit compat — all covered by Flathub, and the one
  thing Flathub cannot cover (`gamescope` as a session) is rejected outright.
- **The sysext refresh mechanism is already wired** —
  `gnome-build-meta.bst:gnomeos/reload-sysext.bst` sits in
  `stacks/base-system.bst` today. It's plumbing with nothing plugged into it.
- **No i686/cross-compiler junction override exists** in
  `elements/freedesktop-sdk.bst` — any native lib32 element would need one
  added first.
- **`project.conf` `options:` only has `arch`** — no build-time gaming toggle
  exists (dakota's model would need one; neither chosen path does).
- **Single OCI variant**: `oci/krytis/*` → `localhost/krytis-input:latest` →
  `Containerfile` → `ghcr.io/starlit-os/krytis`. No nvidia variant, no second
  `publish.yml`/`checks.yml`/`cache-warm.yml` CI leg. Either native path was
  new CI surface, not just new elements.
- **nvidia is out of scope**, confirmed — no nvidia variant exists.

## Naming note for `upstream-lessons` passes

krytis has no `gaming` element tree, by decision. When diffing
zirconium-hawaii, `elements/gamerslop/*`, `elements/sysext/jackrabbit/*`, and
`elements/oci/jackrabbit/*` have **no downstream counterpart and should not be
reported as a gap** — see `docs/skills/zirconium-hawaii.md` § Gaming trees.
Same for dakota's `elements/gaming/*` and its `-o gaming` option.
