# Desktop Stack Reference

Load when working with greetd, noctalia-greeter, wlroots, niri, or the mesa GPU driver configuration.

## Component Map

| Binary | Element | Notes |
|---|---|---|
| `greetd` | `desktop/greetd.bst` | Login session manager; ships the systemd unit |
| `noctalia-greeter-compositor` | `desktop/noctalia-greeter.bst` | wlroots compositor run by greetd |
| `noctalia-greeter` | `desktop/noctalia-greeter.bst` | Wayland client (UI) spawned by the compositor |
| `niri` | `desktop/niri.bst` | User session compositor (Rust/smithay, not wlroots) |
| `wlroots.so` | `desktop/wlroots.bst` | Shared by noctalia-greeter-compositor |

Config (PAM, greetd.toml, sysusers, tmpfiles, systemd drop-ins): `config/greetd-config.bst`.

## Local patches on noctalia-greeter

`desktop/noctalia-greeter.bst` pulls a `kind: tar` GitHub archive of the `kitten-lily/noctalia-greeter`
fork. To carry a local UI tweak (e.g. removing the brand logo) without pushing to the fork, add a
`kind: patch` source after the `tar` source, same pattern as `overrides/vim.bst`:

```yaml
- kind: patch
  path: patches/noctalia-greeter/<name>.patch
```

- BST's tar source strips the archive's single top-level directory by default, so patch paths are
  relative to the fork's repo root (e.g. `src/greeter/greeter_surface.cpp`), not the archive path.
- Generate the patch with standard `git diff` (`a/`/`b/` prefixes) — BST's patch source defaults to
  `strip-level: 1`, matching git's default. A `--no-prefix` diff needs `-p0` and will fail to apply.
- Verify before committing: download the pinned tarball, `tar xzf`, `patch -p1 --dry-run <
  patches/noctalia-greeter/<name>.patch` from the extracted root. Confirms both hunk context and
  strip level before `bst build` ever sees it.
- The greeter's logo widget (`m_bottomBrandLogo` in `greeter_surface.cpp`) only reserves layout space
  when its texture load succeeds (`m_brandLogoTexture.id != 0`, checked in the layout pass). Deleting
  the load call entirely (rather than hiding the widget after load) leaves the id at its zero default,
  so the widget both stays invisible and never reserves space — cleaner than a visibility-only patch.

## Mesa Layout in the Image

fdsdk installs mesa to a non-standard prefix:

```
/usr/lib/x86_64-linux-gnu/GL/default/lib/        ← shared libs (libgbm, libEGL_mesa, …)
/usr/lib/x86_64-linux-gnu/GL/default/lib/dri/    ← DRI drivers (radeonsi_dri.so, …)
/usr/lib/x86_64-linux-gnu/GL/default/lib/vulkan/icd.d/  ← Vulkan ICDs (radeon_icd.x86_64.json)
```

`vm/mesa-default.bst` installs `/etc/ld.so.conf.d/00_mesa.conf` with the GL/default/lib path so
shared libraries are found by the dynamic linker. It is **not** a reduced mesa build — it depends
on the full `extensions/mesa/mesa.bst`, which includes for x86_64:

- gallium: `radeonsi`, `zink`, `llvmpipe`, `virgl`, and more
- vulkan: `amd` (radv), `intel`, `swrast`, `virtio`, and more

## wlroots Renderer Selection (0.20.x)

wlroots picks a renderer at startup based on the DRM backend's render node:

| GPU situation | Render node | Auto renderer | Notes |
|---|---|---|---|
| simpledrm (early boot / efifb) | none | **pixman** (software) | No render node → `wlr_backend_get_drm_fd` returns -1 → pixman chosen automatically |
| amdgpu / real GPU | `/dev/dri/renderD128` | GLES2 attempted, then Vulkan | Fails if neither renderer can initialise — **no pixman fallback** in this path |

pixman uses DRM dumb buffers as its allocator; works on all drivers including amdgpu.

### GLES2 on amdgpu fails with fdsdk mesa

wlroots GLES2 requires glvnd to find `libEGL_mesa.so.0` and MESA-LOADER to find `radeonsi_dri.so`.
With fdsdk's non-standard mesa prefix this path fails. Use `WLR_RENDERER=vulkan` or fall back to
`WLR_RENDERER=pixman` if Vulkan is unavailable.

### Vulkan ICD discovery: compat-vulkan-link

`freedesktop-sdk.bst:components/compat-vulkan-link.bst` (in `stacks/desktop.bst`) is a stack
element whose integration commands symlink the fdsdk ICD directories into standard Vulkan loader
search paths:

```
/usr/share/vulkan/icd.d/          → /usr/lib/x86_64-linux-gnu/GL/vulkan/icd.d/
/usr/share/vulkan/explicit_layer.d → /usr/lib/x86_64-linux-gnu/GL/vulkan/explicit_layer.d/
/usr/share/vulkan/implicit_layer.d → /usr/lib/x86_64-linux-gnu/GL/vulkan/implicit_layer.d/
```

The Vulkan loader searches `/usr/share/vulkan/icd.d/` by default, so `VK_ICD_FILENAMES` is
**not** needed after this element is present. Closes the ICD discovery gap (#94).

### wlroots Vulkan renderer — compiled in but NOT used for the greeter

`desktop/wlroots.bst` compiles the Vulkan renderer (`-Drenderers=vulkan`) with:
- build-depends: `components/vulkan-headers.bst`, `components/vulkan-icd-loader.bst`, `components/glslang.bst`
- runtime depend: `components/vulkan-icd-loader.bst` (provides libvulkan.so)

Build notes:
- `pixman` is **not** a valid `-Drenderers` value in 0.20.1 — allowed: `auto`, `gles2`, `vulkan`; pixman is always compiled in unconditionally.
- `gles2` must **not** be listed: `egl.pc` is absent from the pkgconfig path in the BST build sandbox, causing an error. With `auto` it was silently skipped.

**The Vulkan renderer cannot be used for the greeter compositor on displays wider than 2560px.**

wlroots Vulkan renderer has a DMA-BUF import size limit of **2560x2560 pixels** (AMD DCC tiling
modifier constraint). On a 3440x1440 display:

```
[ERROR] DMA-BUF is too large to import (3440x1440 > 2560x2560)
[ERROR] failed to enable output DP-1
```

The compositor silently falls back to the next connected output (DP-2 at 1920x1200), leaving
the primary monitor blank. The wlroots Vulkan renderer also self-reports as experimental:
`"The vulkan renderer is only experimental and not expected to be ready for daily use"`

**Conclusion:** use `WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1` for the greeter compositor.
Pixman uses DRM dumb buffers with no size constraint and works reliably on all outputs.

A potential workaround is `WLR_VK_NO_MODIFIERS=1` (forces linear buffers, removing the modifier
size constraint) but this is untested and pixman is adequate for a login greeter.

Do **not** set `MESA_LOADER_DRIVER_OVERRIDE=zink` in the greetd command: the greeter PAM session
inherits `/etc/environment` via `pam_env`, so GL env overrides also reach the noctalia-greeter
GTK client and cause its UI to render black (GTK Vulkan GSK renderer fails silently).

Toolkit env hints (`GSK_RENDERER`, `SDL_VIDEODRIVER`) belong only in `environment.d` (user
systemd sessions), not in `/etc/environment` (which is read by the greeter PAM session too).

## Passing Environment Variables to the Greeter Compositor

**Do NOT use a systemd `Environment=` drop-in on `greetd.service` to pass env vars to the compositor.**

greetd constructs a clean PAM environment for the greeter child session — it does not inherit
its own systemd service environment into child processes. A drop-in that sets `WLR_RENDERER=pixman`
on greetd.service has no effect on `noctalia-greeter-compositor`. This was confirmed empirically:
the drop-in was present and the compositor still failed with the same renderer error.

**Correct approach:** prefix the command in `greetd config.toml` with `env VAR=val`:

```toml
[default_session]
command = "env WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 noctalia-greeter-session"
user = "greeter"
```

The `env` call runs before the compositor inherits the environment, so the vars are always present
regardless of PAM env construction.

`WLR_NO_HARDWARE_CURSORS=1` is required when pixman is active — pixman has no KMS cursor plane
support and will otherwise log cursor errors and potentially crash.

## Toolkit Vulkan / Wayland Environment (#97)

### Two-layer environment strategy

Toolkit hints go in **`environment.d/`** only, never `/etc/environment`:

- `/etc/environment` is read by `pam_env.so readenv=1` in the greetd PAM stack — vars there reach the greeter GTK client. `GSK_RENDERER=vulkan` there caused the noctalia-greeter window to render black (GTK Vulkan GSK renderer failed silently).
- `/usr/lib/environment.d/90-krytis-session.conf` is read by the systemd user manager at user session start — safe for toolkit hints.

**Why not rely on niri's `environment {}` block alone?** niri's environment block fires after the compositor starts. systemd user services launched before niri (`xdg-desktop-portal`, `pipewire`, D-Bus activated services) do not inherit it. `environment.d/` is set at user manager startup, before any service starts, so it covers the full session.

`niri-session` also calls `systemctl --user import-environment` which propagates the PAM environment into the user session — but this fires at the same time as niri startup, too late for early services.

### Variables in `environment.d/90-krytis-session.conf`

| Variable | Value | Effect |
|---|---|---|
| `XDG_SESSION_TYPE` | `wayland` | Also in `/etc/environment` — logind/pam_systemd critical |
| `XDG_CURRENT_DESKTOP` | `niri` | Also in `/etc/environment` — desktop identification |
| `XDG_SESSION_DESKTOP` | `niri` | Session desktop for xdg-desktop-portal backend selection |
| `GSK_RENDERER` | `vulkan` | GTK4 scene-kit uses Vulkan renderer (radv via compat-vulkan-link) |
| `GDK_BACKEND` | `wayland` | Forces GDK Wayland backend for GTK3 apps (GTK4 auto-detects) |
| `EGL_PLATFORM` | `wayland` | EGL platform hint for Wayland |
| `CLUTTER_BACKEND` | `wayland` | Clutter backend for GNOME apps |
| `MOZ_ENABLE_WAYLAND` | `1` | Firefox/Thunderbird native Wayland |
| `MOZ_DBUS_REMOTE` | `1` | Firefox D-Bus remote control on Wayland |
| `GTK_IM_MODULE` | `simple` | Compose sequences — see Dead Keys section; also set in niri config.kdl for belt-and-suspenders |
| `QT_AUTO_SCREEN_SCALE_FACTOR` | `1` | Qt HiDPI scaling |
| `QT_WAYLAND_FORCE_DPI` | `physical` | Qt DPI from physical display |
| `ELECTRON_OZONE_PLATFORM_HINT` | `auto` | Electron native Wayland via ozone |
| `_JAVA_AWT_WM_NONREPARENTING` | `1` | Java AWT apps render correctly on Wayland |

**Do not set `SDL_VIDEODRIVER=wayland`** in `environment.d` or `/etc/environment`. SDL2 apps break when this is forced: SDL2's own Wayland auto-detection (`SDL_VIDEODRIVER` unset) is more reliable than overriding it unconditionally. Setting it caused regressions in SDL2 apps that need fallback paths.

## niri vs wlroots

niri uses **smithay** (pure Rust), not wlroots. Its rendering stack handles EGL/GPU failures
differently — smithay falls back more gracefully, which is why niri works from a TTY on amdgpu
even when wlroots-based compositors (noctalia-greeter-compositor) fail.

## bootc BLS Entry Title and os-release Fields

bootc constructs the BLS (Boot Loader Specification) entry title from os-release. Key fields:

| Field | Effect |
|---|---|
| `PRETTY_NAME` | Base display name in the boot menu |
| `VERSION_ID` | Appended as `(VERSION_ID)` in the boot title |
| `IMAGE_VERSION` | If set, bootc uses this for the version segment instead of the conf filename |

**Pitfall:** If `VERSION_ID` equals the codename (e.g. `"Krytis"`) and `PRETTY_NAME` already includes that name (e.g. `"StarlitOS Krytis"`), the entry shows `StarlitOS Krytis (Krytis)` — redundant. Without `IMAGE_VERSION`, the BLS conf filename leaks into the title as a third segment.

**Fix pattern** (in `elements/core/os-release.bst`):
- Set `VERSION_ID` to `%{image-version}` (e.g. `25.08.202606201613`) — a real version number
- Set `IMAGE_VERSION` to the same value so bootc has an explicit version field
- Make `PRETTY_NAME` static (e.g. `"StarlitOS Krytis"`) so the codename is preserved in the human display name independent of `VERSION_ID`
- Keep the codename in `VERSION` for human-readable context (e.g. `"25.08.202606201613 (Krytis Edition)"`)

Result: boot entry shows `StarlitOS Krytis (25.08.202606201613)`.

## niri Keybind Pattern

Keybinds in `files/niri/config.kdl` follow this form:

```kdl
Mod+X hotkey-overlay-title="Label: binary" { spawn "binary"; }
```

- `Mod+X` — modifier + key (Mod = Super on TTY, Alt in nested session)
- `hotkey-overlay-title=` — label shown in the `Mod+?` overlay; format `"Verb a Thing: binary-name"`
- `{ spawn "binary"; }` — launches the binary; use `spawn-sh "..."` for shell pipelines

Standard binds already in `files/niri/config.kdl`:

| Bind | Action |
|---|---|
| `Mod+T` | ghostty (terminal) |
| `Mod+D` | fuzzel (launcher) |
| `Mod+E` | nautilus (file manager) |
| `Super+Alt+L` | swaylock (screen lock) |

## Cursor Theme

Krytis uses `xcursor-theme "Adwaita"` (size 24) set in the top-level `cursor { }` block in `files/niri/config.kdl`. No extra element is needed — `gnome-build-meta.bst:core/nautilus.bst` already pulls `sdk/adwaita-icon-theme.bst` transitively. Verify with `grep -r "adwaita-icon-theme" <gnome-build-meta-staged>/elements/core/nautilus.bst`.

## Validating niri Config Changes

When editing `files/niri/config.kdl`, validate before committing. If niri is available on the current machine:

```bash
niri validate --config files/niri/config.kdl
```

If the file needs to be in a specific location (e.g. testing on the booted image), write to a temp file first:

```bash
cp files/niri/config.kdl /tmp/niri-test.kdl
niri validate --config /tmp/niri-test.kdl
```

`niri validate` catches unknown node names, type errors, and structural mistakes. Common mistake: `theme`/`size` inside `cursor { }` — correct names are `xcursor-theme`/`xcursor-size`.

## xdg-desktop-portal Backend Routing for niri

`XDG_CURRENT_DESKTOP=niri` is already set in `/etc/environment`, but xdg-desktop-portal also needs a portal configuration file to know which backend to use for each interface. Without this file the daemon cannot resolve a backend and default-app lookups (e.g. opening a URL) fail silently.

Ship `/usr/share/xdg-desktop-portal/portals/niri.portal` (see `config/xdg-portals.bst`):

```ini
[preferred]
default=gnome;gtk
org.freedesktop.impl.portal.Settings=gnome
org.freedesktop.impl.portal.Wallpaper=gnome
org.freedesktop.impl.portal.Screenshot=gnome
```

This routes gnome-specific interfaces to `xdg-desktop-portal-gnome` and everything else to gnome/gtk in preference order. Both backends are already in `stacks/desktop.bst`; this file activates the routing.

## Camera Stack

libcamera + PipeWire + WirePlumber are wired in `stacks/desktop.bst`. Key facts:

- `freedesktop-sdk.bst:components/pipewire-daemon.bst` is built with `-Dlibcamera=enabled` inside
  `pipewire-base.bst`, so the `spa-0.2/libcamera` SPA node ships with the daemon — no separate
  "pipewire-libcamera" element exists; it is part of the daemon split-rules.
- `freedesktop-sdk.bst:vm/config/pipewire.bst` installs the user-preset enabling `pipewire.socket`
  and `pipewire-pulse.socket`; without it the daemon does not start on login.
- `wireplumber.bst` is the required session manager — pipewire-daemon alone does not route streams.
- The xdg-desktop-portal camera portal is built into `xdg-desktop-portal` base (already in stack);
  no separate portal element needed.
- **v4l2loopback** (virtual V4L2 device kernel module) is out-of-tree. It requires a prebuilt
  CachyOS package vendored like `core/linux-cachyos.bst`. Not yet implemented (see issue #86).

Diagnostic:
```bash
# Verify PipeWire is running
systemctl --user status pipewire.socket pipewire.service wireplumber.service

# List camera devices seen by libcamera
cam --list

# Check spa-0.2/libcamera plugin is present
find /usr/lib -path '*/spa-0.2/libcamera*'
```

## Fontconfig: fc-cache in the OCI Build

**Do NOT run `fc-cache` in `stack.bst` integration commands.**

BST integration commands in a `kind: stack` element run when the stack is staged inside a compose element (e.g., `runtime.bst`). In practice, fc-cache invoked there produces an incomplete cache — some font directories are missed. Root cause is timing/ordering of when font artifacts are fully staged vs. when integration commands fire.

**Correct approach:** run `fc-cache` in `oci/krytis/image.bst` (kind: script), after all other sysroot operations, using `FONTCONFIG_SYSROOT` to target the assembled layer:

```yaml
# In build-depends:
- freedesktop-sdk.bst:components/fontconfig.bst

# In commands (after ldconfig):
- FONTCONFIG_SYSROOT=/layer fc-cache -f
```

`FONTCONFIG_SYSROOT` makes fc-cache:
1. Read `/layer/etc/fonts/fonts.conf` (not the build host's)
2. Scan `/layer/usr/share/fonts/` and all subdirs
3. Write cache to `/layer/usr/lib/fontconfig/cache/`

Requires fontconfig ≥ 2.13.95. fdsdk ships 2.14+ so this is safe.

**Symptom of the broken approach:** fonts present at `/usr/share/fonts/{dejavu,Adwaita}/` but absent from `fc-list` and font pickers on first boot. Manual `fc-cache` on the booted image appears to fix it — but `/usr` is immutable in bootc, so fontconfig falls back to writing the user cache at `~/.cache/fontconfig/` instead.

## Fontconfig: conf.avail vs conf.d

`fontconfig` only loads conf files that are either **directly in** `/etc/fonts/conf.d/` or **symlinked there**. Files in `conf.avail/` are inert until activated.

`symbols-nerd-font.bst` installs the alias conf to both:
- `/usr/share/fontconfig/conf.avail/10-nerd-font-symbols.conf` (canonical location)
- `/etc/fonts/conf.d/10-nerd-font-symbols.conf` → symlink to the above (activates it)

**Pitfall:** Installing only to `conf.avail` means all `<alias>` rules (including the Symbols Nerd Font fallback for MonoLisaCode and all other families) are silently ignored. Nerd Font glyphs render as `?` even though the font and config are both present.

**Pattern for any new fontconfig conf in a BST element:**
```yaml
- |
    install -Dm644 my.conf \
      "%{install-root}%{datadir}/fontconfig/conf.avail/my.conf"
- |
    mkdir -p "%{install-root}%{sysconfdir}/fonts/conf.d"
    ln -s "%{datadir}/fontconfig/conf.avail/my.conf" \
      "%{install-root}%{sysconfdir}/fonts/conf.d/my.conf"
```

### Variable font families have distinct fontconfig family names

A variable-weight font (`MonoLisaCode Variable`) registers under a **different family name** from its static-weight counterparts (`MonoLisaCode`, `MonoLisaCode Bold`, etc.). Each distinct family name needs its own `<alias>` block in the Nerd Font fallback conf.

Without a separate alias for `MonoLisaCode Variable`, Nerd Font glyphs render as `?` when the terminal is configured to use the variable family — even though the alias for `MonoLisaCode` exists and the font itself is present.

Add one `<alias>` block per distinct family name:
```xml
<alias binding="same">
  <family>MonoLisaCode Variable</family>
  <prefer><family>Symbols Nerd Font Mono</family></prefer>
</alias>
```

The variable family name can be found with `fc-list | grep -i "monolisa"` on the booted image.

## Diagnostic Commands (run on the booted image)

```bash
# Check which DRM devices are present
ls -la /dev/dri/

# Greeter compositor log (all past sessions)
cat /var/log/noctalia-greeter.log

# Current greetd service status and environment
systemctl show greetd.service | grep Environment
journalctl -u greetd --boot

# Verify Vulkan ICD symlink is in place (compat-vulkan-link)
ls -la /usr/share/vulkan/icd.d/

# Check Vulkan ICD files (original fdsdk path)
find /usr/lib -name '*radeon*icd*.json' 2>/dev/null

# Verify session environment vars are set
grep -E 'GSK_RENDERER|SDL_VIDEODRIVER|MESA_LOADER' /etc/environment
```

## Dead Keys / Compose Sequences in GTK4 Apps

**Symptom:** dead key + space does not produce the character (e.g. `dead_grave` + space → nothing, or the compose sequence is ignored).

**Root cause:** GTK4 on Wayland defaults to the IBus input method module. With IBus absent, the IM module initialization fails silently and compose sequences are never processed.

**Fix:** set `GTK_IM_MODULE=simple` in niri's `environment` block (`files/niri/config.kdl`). The `simple` IM module uses GDK's built-in xkbcommon compose handling, which correctly processes compose tables from `/usr/share/X11/locale/<locale>/Compose`.

```kdl
environment {
    GTK_IM_MODULE "simple"
    // ... other vars
}
```

This variable is passed to all niri child processes (ghostty, nautilus, etc.).

**Note:** the compose table lookup uses `LANG` / `LC_CTYPE`. `en_US.UTF-8/Compose` has 258 `dead_grave` entries; `C/Compose` has 0 — so if LANG is unset, compose still won't work even with `GTK_IM_MODULE=simple`. Ensure LANG is set system-wide (e.g. via `/etc/locale.conf` or `environment.d`).

## xdg-utils / xdg-open

`xdg-utils` is not in fdsdk — no `xdg-open` binary exists in the image by default. Apps that call `xdg-open` to open URLs (e.g. ghostty clicking a link) will silently fail.

**Fix:** `elements/desktop/xdg-utils.bst` — autotools element from `freedesktop:xdg/xdg-utils.git`.

Key element overrides:
```yaml
variables:
  conf-link-args: ""  # no C code — shared/static lib flags not accepted by configure
  build-dir: ""       # out-of-tree builds not supported by xdg-utils configure
config:
  build-commands:
  - |
    cd scripts
    for xml in desc/*.xml; do
      base=$(basename "$xml" .xml)
      printf 'Name\n\n%s\n\nDescription\n' "$base" > "$base.txt"
    done
    make -j1 scripts
  install-commands:
  - make -j1 -C scripts DESTDIR="%{install-root}" install
```

**Why not `make install` at top level?** Top-level `make` builds HTML/man docs requiring `xmlto`/`xsltproc` (absent from fdsdk). Top-level `make install` also has no `install-exec` target — `scripts/Makefile.in` is hand-written with only `install`/`uninstall`. Installing from `-C scripts` skips all doc targets; the `install` target guards absent man pages with `if [ -f $x ]`.

**Why stub `.txt` files?** `generate-help-script.awk` reads each script's `.txt` (produced by `xmlto txt desc/*.xml`) for the one-line synopsis in `--help` output. Without `.txt` files, `make scripts` fails. Stubbing them with `printf 'Name\n\n%s\n\nDescription\n' "$base"` satisfies the prerequisite — scripts are fully functional; `--help` just shows the script name as synopsis instead of the docbook description. Avoids pulling in xmlto + docbook-xml + docbook-xsl + lynx (no text browser exists in fdsdk).

xdg-utils v1.2.x uses `org.freedesktop.portal.OpenURI` (via `gdbus`) to open URLs on Wayland. Requires `glib` as runtime dep for `gdbus`.

**Tag format in repo:** `v*.*.*` (not `xdg-utils-*.*.*` as one might expect).

## Locale Data

`config/locale-data.bst` (kind: script) replaces `freedesktop-sdk.bst:components/locales.bst` in `stacks/base-system.bst`. It generates only the locales Krytis needs instead of the full glibc SUPPORTED list (~400+ entries).

Current locales: `sv_SE.UTF-8`. `en_US.UTF-8` and `C.UTF-8` are already generated by `freedesktop-sdk.bst:components/utf-locale.bst` (which is part of `runtime-minimal.bst`). Do **not** re-generate them in `locale-data.bst` — BST will raise an overlap error at compose time.

**`en_SE.UTF-8` is blocked on fdsdk glibc bump.** `en_SE` was added in glibc 2.43; fdsdk tracks `release/2.42/master`. Add `en_SE` to `locale-data.bst` once fdsdk bumps to 2.43+.

The `locale` split is not excluded by `oci/krytis/runtime.bst` (only `devel`/`debug`/`static-blocklist` are stripped), so locale archives in `/usr/lib/locale/` land in the image.

## cava (Audio Visualizer) — not currently in stack

cava is not packaged in fdsdk or gnome-build-meta (confirmed 2026-06-26). cava is **not** a noctalia dependency (checked noctalia `meson.build` at `78e528ba` — no reference).

If noctalia adds cava as a dependency or it is otherwise needed, element notes:
- Upstream: `github:karlstav/cava.git`, bare semver tags (`1.0.0`, no `v` prefix), track glob `[0-9]*`
- Build system: autotools from git — needs `autoreconf -fiv` before `configure` (no pre-generated script in repo)
- Deps: FFTW (`fftw.bst`), PipeWire (`pipewire.bst`), ALSA (`alsa-lib.bst`); all present in fdsdk
- SDL2 and ncurses are not in fdsdk; default terminal-escape-code output works without them
- See also: #164 (sdl2-compat investigation)

## gvfs / Volume Monitor

`gnome-build-meta.bst:core/gvfs-daemon.bst` is included in `stacks/desktop.bst`. GIO discovers volume monitors as runtime D-Bus services — not build-time Nautilus deps.

Without gvfs-daemon: non-boot disks absent from Nautilus sidebar, `trash://` broken, network mounts (SMB/NFS/SFTP) unavailable.

`gvfs-daemon.bst` depends on `udisks2` — no separate udisks2 entry needed. Dep surface: samba, libgphoto2, libmtp, avahi, openssh, libbluray, libcdio-paranoia, libimobiledevice, libnfs, gnome-online-accounts, fuse3, polkit.

Verify on booted image:
```bash
systemctl --user status gvfs-udisks2-volume-monitor.service
udisksctl status
gio info trash://
```

Note: glibc locale archives (`/usr/lib/locale/`) are distinct from X11 compose tables (`/usr/share/X11/locale/`). xkbcommon uses the X11 path for dead-key compose — glibc locale availability does not affect compose table lookup.

## Codec Stack

`stacks/codecs.bst` is a separate stack wired into `oci/krytis/stack.bst` alongside `stacks/desktop.bst`.
Ported from zirconium-hawaii. Key facts:

- `freedesktop-sdk.bst:extensions/codecs-extra/*` live under `extensions/`, not `components/` — these
  contain patent-encumbered codecs (H.264 via x264, HEVC via libheif, etc.).
- `extensions/platform-vaapi-intel/intel-media-driver.bst` is x86_64-only; safe because krytis
  is x86_64_v3-only. Do not add this to an aarch64 build without an arch guard.
- `gstreamer-plugins-ugly-x264.bst` and `codecs-extra/ffmpeg.bst` are the codec-extra overlays that
  extend the base gstreamer-plugins-ugly and ffmpeg with encumbered codecs.
- `gst-thumbnailers.bst` is from gnome-build-meta, not fdsdk.
- `gstreamer-plugins-base.bst` is already a transitive dep of many gnome-build-meta elements;
  adding it explicitly here is harmless and makes the stack self-documenting.

## AMD VA-API H.264 Decode — Junction Override Pattern

**Problem:** fdsdk's `extensions/mesa/mesa.bst` builds with `video_codecs: all_free` — `radeonsi_drv_video.so` has no H.264/H.265 decode support. `mesa-extra.bst` builds with `video_codecs: all` but cannot coexist with `mesa.bst` as a runtime dep (BST `fatal-warnings: overlaps` fires because both provide the full mesa library tree).

fdsdk has `platform-vaapi-intel` and `platform-vaapi-nvidia` extensions but **no `platform-vaapi-amd`** — there is no upstream fdsdk element that provides AMD VA-API hardware decode.

**Why `build-depends: mesa-extra.bst` doesn't work:**

BST 2's `kind: compose` stages ALL deps (`--deps all`) of its `build-depends`, including transitive build-deps. Any element with `build-depends: mesa-extra.bst` causes `mesa-extra.bst` to appear alongside `mesa.bst` at compose time — both providing the full mesa file tree — which triggers `fatal-warnings: overlaps`. There is no whitelist that can resolve this because `mesa.bst` itself has no `overlap-whitelist`.

**Fix — junction override in `elements/freedesktop-sdk.bst`:**

```yaml
config:
  overrides:
    extensions/mesa/mesa.bst: desktop/mesa-all-codecs.bst
```

`desktop/mesa-all-codecs.bst` is a standalone `kind: meson` element with sources and build config mirroring `mesa-extra.bst` exactly (same fdsdk deps, same meson flags, `video_codecs: all`). It replaces `mesa.bst` across the entire junction dep graph — one mesa in the image, no overlap.

Key facts:
- Since sources, deps, and meson config match `mesa-extra.bst` exactly, BST should reuse the remote-cached artifact (same resolved configuration → same cache key).
- Junction overrides replace the upstream element everywhere it appears in the dep graph: `vm/mesa-default.bst` and anything else that depends on `extensions/mesa/mesa.bst`.
- krytis is x86_64_v3-only so arch-conditional variables are hardcoded (no conditional expressions).
- Update path: tied to the `freedesktop-sdk.bst` junction ref — when the junction bumps, sync the mesa git ref and crate refs in `mesa-all-codecs.bst` to match `mesa-sources.yml` in the new fdsdk tag.

**Verification (on booted image):**
```bash
# 1. Confirm GStreamer VA-API H.264 decode element present
gst-inspect-1.0 va | grep vah264dec
# expect: vah264dec: VA-API H.264 Decoder in AMD Radeon RX 7800 XT

# 2. Generate a test H.264 file (libx264 not in image; use h264_vaapi encoder)
ffmpeg -vaapi_device /dev/dri/renderD128 \
  -f lavfi -i testsrc=duration=5:size=640x480:rate=30 \
  -vf 'format=nv12,hwupload' \
  -c:v h264_vaapi /tmp/test.mp4

# 3. Decode via VA-API and confirm no errors
gst-launch-1.0 filesrc location=/tmp/test.mp4 ! qtdemux ! h264parse ! vah264dec ! fakesink
# expect: pipeline reaches EOS, context shows AMD device, no fallback errors
```

Notes:
- `strings ... | grep VAProfileH264` is unreliable — VA-API profiles are enum integers, not string literals in the `.so`. Skip it.
- `vainfo` is not in the image (`libva-utils` not packaged). `gst-inspect-1.0 va` is sufficient.
- `libx264` encoder not in ffmpeg build; use `h264_vaapi` to generate test clips on the device.

## Plymouth Boot Splash

Plymouth is sourced from `freedesktop-sdk.bst:components/plymouth.bst` (also exists in `gnome-build-meta.bst:core-deps/plymouth.bst` — fdsdk was chosen to stay within the existing dep graph).

### Three integration points

**1. Runtime binary** — `freedesktop-sdk.bst:components/plymouth.bst` in `stacks/desktop.bst`. Provides `plymouthd`, `plymouth`, and systemd units. `plymouth-quit.service` has `After=display-manager.service`; greetd ships `Alias=display-manager.service`, so quit ordering is automatic.

**2. Initramfs** — `freedesktop-sdk.bst:components/plymouth.bst` is also a build-dep of `core/initramfs.bst`. This stages Plymouth's binary and dracut module into the BST sandbox so dracut can include it. The dracut conf (`30-bootcrew-bootc-container-build.conf`) adds `plymouth` to `add_dracutmodules`.

**3. Kernel args** — `files/bootc-config/20-plymouth.toml` ships `kargs = ["quiet", "splash"]` to `/usr/lib/bootc/kargs.d/`. bootc applies these at deploy time. `quiet` suppresses kernel log messages; `splash` activates the Plymouth splash on the kernel cmdline.

### Pitfall: Plymouth must appear in both build-depends AND depends

`core/initramfs.bst` lists Plymouth as a **build-dep** (staged into sandbox for dracut). `stacks/desktop.bst` lists Plymouth as a **runtime dep** (installed into the image for `plymouthd` and the systemd units). Listing it only in one place leaves either the initramfs splash or the post-switch-root quit service broken.

### Theme selection: same both-places pitfall applies to `/etc/plymouth/plymouthd.conf`

fdsdk's `plymouth.bst` ships `plymouthd.defaults` with `Theme=bgrt` — this renders the UEFI firmware logo (ACPI BGRT) via the `two-step` module's `UseFirmwareBackground=true`. Stock themes available (installed by the meson build regardless of which is active): `bgrt`, `spinner`, `spinfinity`, `glow`, `solar`, `fade-in`, `text`, `details`, `tribar`, `script`. Only `bgrt` touches the firmware logo — all others are pure Plymouth-rendered graphics.

`glow` was tried first (two-step module, `merge-fade` transition, off-center large watermark) but dropped as visually too heavy (pie-chart progress fill + logo-reveal animation). Settled on `spinner` instead: it's the same `two-step` module and animation frames `bgrt` itself reuses (`bgrt.plymouth`'s `ImageDir=/usr/share/plymouth/themes//spinner`), just without the firmware-background layer — lighter, and it already has a watermark slot.

**Reuse the existing watermark slot instead of inventing a theme directory.** fdsdk's `plymouth-logo.bst` (a transitive dep of `plymouth.bst`) installs `freedesktop-sdk-40.png` to `%{datadir}/plymouth/themes/spinner/watermark.png`. `config/plymouth-theme.bst` overwrites that same path with a local logo (`files/plymouth/krytis-watermark.png`) rather than copying spinner's ~70 animation frames into a new theme dir. Requires **two** `overlap-whitelist` entries on `config/plymouth-theme.bst`, not just one: `/etc/plymouth/plymouthd.conf` (upstream ships a commented-out template there) and `/usr/share/plymouth/themes/spinner/watermark.png` (upstream's own logo file).

**Positioning/sizing the watermark: the `two-step` module has no scale knob.** `spinner.plymouth`'s `[two-step]` section exposes `WatermarkHorizontalAlignment`/`WatermarkVerticalAlignment` (0.0–1.0, 0=top/left, 1=bottom/right — stock is `.5`/`.96`, i.e. bottom-center) but nothing for image scale. To move the logo and resize it:
- **Position**: overwrite `spinner.plymouth` itself too (third `overlap-whitelist` entry: `/usr/share/plymouth/themes/spinner/spinner.plymouth`). Copy the stock file's `[two-step]` section verbatim and only change the alignment value — the translated `Name[xx]=` lines are cosmetic (theme picker only) and safe to drop, but every other key must be preserved since this is a full-file replacement, not a patch.
- **Scale**: resize the source PNG itself before it ever reaches `files/plymouth/` (e.g. `ffmpeg -i in.png -vf scale=W:H out.png` — preserves the alpha channel, confirmed via `file` reporting `RGBA` on the output). There's no runtime scale parameter to lean on.

**dracut only packages the currently-selected theme's files into the initramfs**, not all stock themes — so `config/plymouth-theme.bst` (which drops `Theme=spinner` into `%{sysconfdir}/plymouth/plymouthd.conf`) must be a **build-dep of `core/initramfs.bst`** (theme picked up before `dracut --force` runs) **and** a **runtime dep of `stacks/desktop.bst`** (theme persists on the final rootfs for shutdown/reboot animations after switch-root). Same failure mode as the plymouth binary itself: miss one side and the initramfs splash and the post-switch-root theme diverge.

### Verification (on booted image)

```bash
# Plymouth units present
systemctl status plymouth-start.service plymouth-quit.service
# Kernel args applied by bootc
cat /proc/cmdline | grep -o 'quiet\|splash'
# dracut module was included
lsinitrd /usr/lib/modules/$(uname -r)/initramfs.img | grep plymouth
# Active theme (should read "spinner")
plymouth-set-default-theme
# Theme assets present inside the initramfs, not just the rootfs
lsinitrd /usr/lib/modules/$(uname -r)/initramfs.img | grep 'plymouth/themes/spinner'
# Watermark is the krytis logo, not the freedesktop-sdk swirl
lsinitrd /usr/lib/modules/$(uname -r)/initramfs.img --file usr/share/plymouth/themes/spinner/watermark.png > /tmp/watermark.png
# Confirm alignment override landed (should read .4, not stock .96)
lsinitrd /usr/lib/modules/$(uname -r)/initramfs.img --file usr/share/plymouth/themes/spinner/spinner.plymouth | grep WatermarkVerticalAlignment
```

---

## AccountsService / D-Bus-activated gnome-build-meta daemons

`gnome-build-meta.bst:core-deps/accountsservice.bst` provides the `org.freedesktop.Accounts` D-Bus interface. noctalia-greeter queries it to load per-user avatar paths (`IconFile` property → `/var/lib/AccountsService/icons/<username>`).

Pattern for gnome-build-meta D-Bus-activated services:
- **No systemd preset** — `Type=dbus` in the service file; D-Bus activates the daemon on first call. No `system-preset` drop-in needed.
- **No config element** — upstream meson build installs `tmpfiles.d/accountsservice.conf` (creates `/var/lib/AccountsService/` and `/var/lib/AccountsService/icons/`), the D-Bus policy config, and the `.service` activation file. Nothing to patch or override.
- **No new tracking** — versioned by the `gnome-build-meta.bst` junction, updated by the `track-core-junctions` CI job. Do not add a matrix entry to `track-bst-sources.yml`.

Reference: `elements/stacks/desktop.bst`. Closes #182.

---

## GTK Settings and dconf System Database

### GTK4 settings.ini vs gsettings priority (critical pitfall)

GTK4 priority order (highest wins):

| Priority | Source |
|---|---|
| 4 | Application (hardcoded) |
| 3 | XSettings daemon |
| **2** | **`~/.config/gtk-4.0/settings.ini`** |
| **2** | **`/etc/gtk-4.0/settings.ini`** (loaded earlier, so `~/.config/` wins on tie) |
| **1** | **gsettings / dconf** |

`/etc/gtk-4.0/settings.ini` is priority 2 — it **overrides** per-user gsettings. A system `settings.ini` with `gtk-icon-theme-name=Papirus` means `gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'` has **no effect**.

**Fix: use dconf system database instead.** System-db values sit at priority 1 alongside user-db; user-db takes precedence, so `gsettings set` correctly overrides system defaults.

### dconf system database pattern

Three files required:

**1. dconf profile** (`/etc/dconf/profile/user`):
```
user-db:user
system-db:local
```

**2. keyfile** (`/etc/dconf/db/local.d/00-defaults`):
```ini
[org/gnome/desktop/interface]
icon-theme='Papirus'
color-scheme='prefer-dark'
```

**3. Compile** — run `dconf update` after all elements are staged. Place in `oci/krytis/stack.bst` integration-commands (same pattern as `fc-cache -f /usr/share/fonts/` for fonts):
```yaml
# Compile dconf system database from /etc/dconf/db/local.d/ keyfiles.
# Must run after all elements are staged so the keyfiles exist.
- dconf update
```

dconf is **not transitive** in this image — must depend on `gnome-build-meta.bst:core-deps/dconf.bst` explicitly in the config element.

### GTK3 dark mode

GTK3 has no `color-scheme` key. Dark mode requires `gtk-application-prefer-dark-theme=true` in `/etc/gtk-3.0/settings.ini`. GTK3 reads icon-theme from dconf but `settings.ini` provides a fallback:

```ini
[Settings]
gtk-icon-theme-name=Papirus
gtk-application-prefer-dark-theme=true
```

GTK3 `settings.ini` priority is the same structure as GTK4 — but since GTK3 apps rarely expose a per-user override for dark mode this is acceptable.

### Resetting per-user dconf overrides

After the system db is baked, a user can reset per-user overrides to pick up system defaults:

```bash
dconf reset /org/gnome/desktop/interface/icon-theme
dconf reset /org/gnome/desktop/interface/color-scheme
# or reset entire subtree:
dconf reset -f /org/gnome/desktop/interface/
```

Reference: `elements/config/gtk-settings.bst`, `elements/oci/krytis/stack.bst`. Closes #212.

## Performance Services (from #101)

### power-profiles-daemon

Available in `gnome-build-meta.bst:core-deps/power-profiles-daemon.bst` — one line in `stacks/desktop.bst`, zero new packaging. Provides a D-Bus API (`org.freedesktop.UPower.PowerProfiles`) for balanced/performance/power-saver switching. Works standalone without GNOME; required by falcond. Do not add tuned alongside it — they conflict via the PPD compat shim.

noctalia's power-profile UI is a genuine bidirectional D-Bus client of this — verified
live both directions (UI clicks land on `ActiveProfile`, and external `powerprofilesctl
set` calls reflect back into the UI). No krytis glue code needed there. What's missing:
nothing in the stack (ppd, falcond, or noctalia) watches AC/battery state to
auto-switch profiles — ppd is a pure mechanism with no policy of its own, and grepping
noctalia's `power_profiles_service.cpp`/`power_tab.cpp` shows its UPower integration is
read-only telemetry only. Tracked as a Design Gate item in #261.

### systemd-oomd

Already compiled into our systemd build. Enable via a config element (`elements/config/oomd.bst`) that drops:
- `/usr/lib/systemd/oomd.conf.d/krytis.conf` — SwapUsedLimit=90%, pressure limit 60%, duration 20s
- `/usr/lib/systemd/system-preset/70-krytis-oomd.preset` — `enable systemd-oomd.service`

Add to `stacks/base-system.bst` (system-level, not desktop-level). Pattern: `strip-commands: [':']` since no binaries.

### amd-pstate EPP default

Use `tmpfiles.d` type `w` to write `balance_performance` to all cpufreq policy sysfs paths at boot:

```
w /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference - - - - balance_performance
```

Add as `files/desktop-tweaks/tmpfiles.d/amd-pstate-epp.conf`. systemd-tmpfiles expands the glob at runtime. Requires `amd-pstate-epp` driver; linux-cachyos enables `amd_pstate=active` by default.

## falcond (PikaOS gaming performance daemon)

`elements/desktop/falcond.bst`. Source: https://git.pika-os.com/general-packages/falcond

Requires Zig 0.16.0+ (`minimum_zig_version = "0.16.0"` in build.zig.zon). All three deps
(`otter_conf`, `otter_desktop`, `otter_utils`) are `git+https://git.pika-os.com/...` — all go in
`zig-deps-git/` and are placed via `place_git_dep`. See `docs/skills/packaging-zig.md` §
pika-os git deps.

`zig build` only installs the binary. Install the service file manually from
`falcond/debian/falcond.service`. Also create `/usr/share/falcond/profiles/user/` at
**build time** (`/usr/share` is read-only at runtime in bootc — `install -d`, not
tmpfiles.d), drop a tmpfiles.d fragment for `/var/lib/falcond/` + `/etc/falcond/`, and a
systemd preset to enable `falcond.service`.

`/usr/share/falcond/profiles/user/` is falcond's compiled-in `-Duser-profiles-dir`
default — documented in falcond's own upstream README under "Build Path Options", not
something you need to reverse-engineer from `strings`. (First pass at this fix guessed
`/etc/falcond/profiles` instead, by pattern-matching against sibling `/etc/falcond`
state dirs rather than checking the README or the binary's literal path strings —
`strings /usr/bin/falcond | grep -E "^/(usr|etc|var).*falcond"` gives the real compiled
defaults directly, `config.user_profiles_dir` alone is just a misleading struct-field
symbol name, not a resolved path. Always check literal path strings or the README before
trusting a symbol name.) The build element only creates the parent
`/usr/share/falcond/profiles` (system profiles dir), never the `/user` subdir — without
it, falcond's inotify watch fails silently at startup
(`warning(event_loop): inotify: cannot watch user profiles dir: error.FileNotFound` in
`journalctl -u falcond`) and `LOADED_PROFILES` stays `0` forever, even with the daemon
otherwise fully healthy and feature-detection working (DMEM cgroup GPU region correctly
found, SCX scheduler list correctly enumerated). This is exactly the kind of failure that
looks like "service is running fine" in `systemctl status` while the daemon's actual
purpose (per-game profiles) silently never fires — `systemctl status` alone is not
sufficient verification for this daemon; check `journalctl -u falcond -b` for the inotify
warning and `cat /var/lib/falcond/status` for `LOADED_PROFILES`.

Upstream ships zero default profiles in the source tarball itself (`falcond/debian/`
contains only the systemd unit) — game profiles are entirely separate, maintained at
[PikaOS-Linux/falcond-profiles](https://github.com/PikaOS-Linux/falcond-profiles) and
pulled in at package-build time by PikaOS's own packaging (per the README's "Packaging"
section). krytis vendors the full set — see "Default game profiles (#258)" below.

Runtime: requires `power-profiles-daemon` (or `tuned-ppd`). Do NOT run alongside gamemode —
they conflict. SCX scheduler binaries (`scx_lavd`, `scx_bpfland`) are optional; falcond
feature-detects them and degrades gracefully if absent. Closes #221.

### Default game profiles (#258)

Upstream falcond ships zero default profiles in its own source tree (`falcond/debian/`
has only the systemd unit). PikaOS's real profile set lives in a separate repo,
[PikaOS-Linux/falcond-profiles](https://github.com/PikaOS-Linux/falcond-profiles) — 9
root profiles (`cs2`, `cyberpunk2077`, `ffxiv`, `hades2`, `civ7`, `factorio`, `obliv`,
`x4`, `proton`), plus `handheld/`/`htpc/` device-mode variants and `system.conf`, no
GitHub Releases (commits straight to `main`).

Vendored as a single `kind: tar` source pinned to a commit SHA (not per-file — simpler
one-ref tracking, and the whole repo is a clean `usr/share/falcond/` tree with no
collisions against krytis's own `profiles/user/` override dir). Two things that bit on
the way in:

- **BST's tar source auto-strips the single leading path component.** The GitHub archive
  is `falcond-profiles-<sha>/usr/share/falcond/...`; after staging into the source's
  `directory:`, it's just `<directory>/usr/share/falcond/...` — no `falcond-profiles-<sha>/`
  prefix survives. Don't glob for it.
- **Scope any grep/sed against this element to the specific source block.** falcond.bst
  already has several unrelated `archive/<40-hex-commit-sha>.tar.gz` sources (the
  `zig-deps-git` pins) — a loose `grep -oP "archive/\K[0-9a-f]{40}"` matches the *first*
  one in the file, not necessarily the one you mean. `mise/tasks/falcond-profiles-update`
  scopes with `grep -A2 "PikaOS-Linux/falcond-profiles/archive"` first. Caught this by
  actually running the task and diffing — it silently corrupted an unrelated
  `otter_conf` source pin on the first attempt.

Update path: `mise run falcond-profiles-update` (commit-SHA based, no release tags to
compare — different shape from `falcond-update`/`scx-loader-update`) + `track-falcond-profiles`
job in `.github/workflows/track-bst-sources.yml`, same `track-mise` pattern as every other
`kind: tar`/`kind: remote` element (`bst source track` is a no-op on these — see
`docs/skills/bst.md` § Element update path).

`LOADED_PROFILES` should read `9` with default `profile_mode: none` (the root profiles;
`handheld`/`htpc` variants only load when that config key is set) — see the
`fix/falcond-user-profiles-dir` branch (#262) for why it read `0` before the
profiles-dir bug fix landed (falcond's compiled-in `-Duser-profiles-dir` default,
`/usr/share/falcond/profiles/user`, wasn't being created at build time). This branch
supersedes #262's single `proton.conf` vendoring — the full tarball already contains it.

### Verification (on booted image)

No CI or `mise` task boots the image and checks service health (AGENTS.md's Verification
gate references `mise boot-test` — that task does not exist as of 2026-07; treat it as
aspirational, not real, until someone builds it). The fastest real check is a host already
running krytis (self-hosted dev box) or `mise run boot-vm` + manual login:

```bash
# Daemons actually alive (not just "enabled")
systemctl is-active power-profiles-daemon falcond scx_loader

# ppd: real D-Bus data, not just process presence
busctl --system get-property org.freedesktop.UPower.PowerProfiles \
  /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile
powerprofilesctl list   # CLI works fine (PyGObject is packaged under system python3).
# CAUTION: if you're testing from a dev shell with a mise/uv Python venv active, PATH
# puts that venv's `python3` before /usr/bin/python3, and `powerprofilesctl`'s
# `#!/usr/bin/env python3` shebang picks up the venv instead — which lacks `gi` and
# throws ModuleNotFoundError. That's a dev-shell PATH artifact, not a packaging bug.
# Verify with `env -i HOME=$HOME PATH=/usr/bin:/bin powerprofilesctl list` to rule out
# shell contamination before concluding the CLI itself is broken.

# scx_loader: real scheduler list, not stub
busctl --system get-property org.scx.Loader /org/scx/Loader org.scx.Loader SupportedSchedulers
# CurrentScheduler == "unknown" at idle is expected (on-demand loader, nothing has called
# SwitchScheduler yet) — not itself a failure signal.

# falcond: the check that actually matters — is the profiles-dir watch healthy?
journalctl -u falcond -b --no-pager | grep -i "profiles\|inotify"
# No "cannot watch user profiles dir" warning = the directory-creation bug is fixed.
# LOADED_PROFILES: 9 is expected on krytis — see "Default game profiles (#258)" above.
cat /var/lib/falcond/status
```

### Proton-catch-all matching depends on launcher process ancestry, not filename

Ground truth from upstream source (`matcher.zig`/`scanner.zig`, cloned from
`git.pika-os.com/general-packages/falcond`), verified live against real games across
four launchers (Bottles, Faugus, Heroic, Steam):

1. Exact/case-insensitive hash-map hit: process name == a `.conf` filename stem (e.g.
   `cs2.conf` matches process `cs2`). Wins immediately, no ancestry walk.
2. Proton catch-all (`proton.conf`) only fires if the process name ends in `.exe`, is
   NOT in `system.conf`'s ignore-list (Wine launcher/updater helper exes), AND walking
   up to 10 parent PIDs via `/proc/<pid>/status` `PPid:`, some ancestor's `comm`
   contains `wine`/`reaper`/`umu-run` **or** its `/proc/<pid>/cmdline` contains the
   literal substring `proton`.

This makes matching launcher-dependent, not just "is it Wine":

- **Bottles-direct** (`bottles-cli run -p ... -b ...`) — MISS. Bottles bundles its own
  runner; nothing in its cmdline says `proton`, and `bwrap` (which Bottles always
  sandboxes through) reparents the game exe as `wineserver`'s *sibling*, not its
  descendant — severing the ancestry link entirely.
- **Faugus, Heroic, Steam** — HIT. All three either run a direct wine ancestor or
  invoke a Steam Proton compat tool (`.../Proton-CachyOS.../proton waitforexitandrun`)
  whose cmdline satisfies the substring fallback, even when also sandboxed through
  `bwrap`/pressure-vessel (Faugus/Steam both are — bwrap by itself does not break
  matching, only the *absence* of a wine/proton needle in the surviving ancestry does).

Don't assume "it's Wine so falcond will catch it" — check whether the launcher's own
invocation puts one of those literal needles in cmdline/comm within 10 hops.

### dmem_protect cgroup delegation gap (#260)

`dmem_protect = true` in a profile is currently a silent no-op on krytis. The kernel's
`dmem` controller is present in root `cgroup.controllers` but is not delegated into
`app.slice`'s `cgroup.subtree_control` (only `cpu io memory pids` are) — so no
`dmem.min`/`dmem.max` file exists at a game's actual cgroup scope for falcond to write
into. No error logged; verified by walking a live game's full cgroup ancestry and
finding zero non-empty `dmem.min`/`dmem.low`/`dmem.max` anywhere. Needs a systemd
drop-in delegating `dmem` (e.g. `Delegate=+dmem`) at the `user@.service`/`app.slice`
level before this profile field does anything. See #260.

### Proton-catch-all matching depends on launcher process ancestry, not filename

Ground truth from upstream source (`matcher.zig`/`scanner.zig`, cloned from
`git.pika-os.com/general-packages/falcond`), verified live against real games across
four launchers (Bottles, Faugus, Heroic, Steam):

1. Exact/case-insensitive hash-map hit: process name == a `.conf` filename stem (e.g.
   `cs2.conf` matches process `cs2`). Wins immediately, no ancestry walk.
2. Proton catch-all (`proton.conf`) only fires if the process name ends in `.exe`, is
   NOT in `system.conf`'s ignore-list (Wine launcher/updater helper exes), AND walking
   up to 10 parent PIDs via `/proc/<pid>/status` `PPid:`, some ancestor's `comm`
   contains `wine`/`reaper`/`umu-run` **or** its `/proc/<pid>/cmdline` contains the
   literal substring `proton`.

This makes matching launcher-dependent, not just "is it Wine":

- **Bottles-direct** (`bottles-cli run -p ... -b ...`) — MISS. Bottles bundles its own
  runner; nothing in its cmdline says `proton`, and `bwrap` (which Bottles always
  sandboxes through) reparents the game exe as `wineserver`'s *sibling*, not its
  descendant — severing the ancestry link entirely.
- **Faugus, Heroic, Steam** — HIT. All three either run a direct wine ancestor or
  invoke a Steam Proton compat tool (`.../Proton-CachyOS.../proton waitforexitandrun`)
  whose cmdline satisfies the substring fallback, even when also sandboxed through
  `bwrap`/pressure-vessel (Faugus/Steam both are — bwrap by itself does not break
  matching, only the *absence* of a wine/proton needle in the surviving ancestry does).

Don't assume "it's Wine so falcond will catch it" — check whether the launcher's own
invocation puts one of those literal needles in cmdline/comm within 10 hops. This
applies to every profile in this vendored set, not just `proton.conf` — native-game
profiles (`cs2.conf` etc.) match on exact process name and don't need any of this, but
anything relying on the Proton fallback does.

### dmem_protect cgroup delegation gap (#260)

`dmem_protect = true` — set on every profile in this vendored set — is currently a
silent no-op on krytis. The kernel's `dmem` controller is present in root
`cgroup.controllers` but is not delegated into `app.slice`'s `cgroup.subtree_control`
(only `cpu io memory pids` are) — so no `dmem.min`/`dmem.max` file exists at a game's
actual cgroup scope for falcond to write into. No error logged; verified by walking a
live game's full cgroup ancestry and finding zero non-empty
`dmem.min`/`dmem.low`/`dmem.max` anywhere. Needs a systemd drop-in delegating `dmem`
(e.g. `Delegate=+dmem`) at the `user@.service`/`app.slice` level before this field does
anything. See #260 — not a defect in this profile set, the profiles are correct, the
delegation just isn't wired up yet.

## scx_loader (sched-ext D-Bus scheduler loader)

`elements/desktop/scx-loader.bst`. Source: https://github.com/sched-ext/scx-loader

**Repo disambiguation:** `sched-ext/scx-loader` is a *separate* repo from `sched-ext/scx` (the
full scheduler monorepo). The D-Bus loader service is also bundled inside the monorepo but the
standalone repo is the right source for an isolated package. Use `scx-loader`, not `scx`.

Provides `org.scx.Loader` on the system D-Bus. falcond calls it for per-game CPU scheduler
switching. Requires kernel sched-ext support (present in linux-cachyos). Closes #228.

Packaged as `kind: manual` + `kind: cargo2` (Rust/cargo2 strategy A — see `docs/skills/bst.md`
§ Rust / Cargo Projects). Uses `buildsystem-make.bst` in `build-depends` (linker).

Install targets from the upstream source tree:
- `services/scx_loader.service` → `%{indep-libdir}/systemd/system/`
- `services/org.scx.Loader.service` → `%{datadir}/dbus-1/system-services/`
- `configs/org.scx.Loader.conf` → `%{datadir}/dbus-1/system.d/`
- `configs/org.scx.Loader.xml` → `%{datadir}/dbus-1/interfaces/`
- `configs/org.scx.Loader.policy` → `%{datadir}/polkit-1/actions/`
- `configs/scx_loader.toml` → `%{datadir}/scx_loader/config.toml`

## Kernel Tuning — config/desktop-udev.bst

`config/desktop-udev.bst` installs kernel configuration files from `files/desktop-tweaks/`. It covers:

| Directory | Install path | Purpose |
|---|---|---|
| `udev/` | `/usr/lib/udev/rules.d/` | Audio PM, HPET perms, SATA link power, I/O schedulers |
| `modprobe.d/` | `/usr/lib/modprobe.d/` | amdgpu force-load for GCN 1.0+ |
| `modules-load.d/` | `/usr/lib/modules-load.d/` | ntsync autoload |
| `tmpfiles.d/` | `/usr/lib/tmpfiles.d/` | THP tuning |
| `sysctl.d/` | `/usr/lib/sysctl.d/` | Kernel parameter overrides |

**CachyOS sysctl overrides.** CachyOS ships a hardened kernel with `kernel.unprivileged_userns_clone=0`. This disables the sandbox in Flatpak apps (bubblewrap) and Chromium/Electron. `files/desktop-tweaks/sysctl.d/99-userns.conf` re-enables it. The pattern for any future CachyOS sysctl override is the same: add a `.conf` file under `files/desktop-tweaks/sysctl.d/` and it is installed automatically by the loop in `desktop-udev.bst` — except the current element installs `sysctl.d/99-userns.conf` explicitly (no glob loop yet). Add a glob loop if a second sysctl file is needed.

Reference: `elements/config/desktop-udev.bst`. Closes #224.
