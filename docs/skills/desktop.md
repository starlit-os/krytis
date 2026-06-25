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

Set in both `/etc/environment` (pam_env reads it → all sessions including greeter) and
`/usr/lib/environment.d/90-krytis-session.conf` (systemd reads it → user session units):

| Variable | Value | Effect |
|---|---|---|
| `GSK_RENDERER` | `vulkan` | GTK4 scene-kit uses Vulkan renderer (radv via compat-vulkan-link) |

These are set in `config/greetd-config.bst` **only in `environment.d`**, NOT in `/etc/environment`.

`/etc/environment` is read by `pam_env.so readenv=1` in the greetd PAM stack, so toolkit hints
there reach the greeter client GTK app. This caused `GSK_RENDERER=vulkan` to make the noctalia-
greeter window render black (GTK Vulkan GSK renderer failed silently). Toolkit hints belong only
in `/usr/lib/environment.d/` which is read by the systemd user manager, not by the greeter PAM
session.

`GDK_BACKEND=wayland` is not set explicitly — GTK4 already prefers Wayland when
`XDG_SESSION_TYPE=wayland` is present.

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

**Fix:** `elements/desktop/xdg-utils.bst` — autotools element from `freedesktop:xdg/xdg-utils.git`, installs via `make install-exec` (skips man page generation, which requires `xmlto`/`xsltproc`).

Key element overrides needed because xdg-utils has no C code:
```yaml
variables:
  conf-link-args: ""   # --enable-shared/--disable-static not accepted by configure
  build-dir: ""        # xdg-utils configure does not support out-of-tree builds
config:
  install-commands:
  - make -j1 DESTDIR="%{install-root}" install-exec
```

xdg-utils v1.2.x uses `org.freedesktop.portal.OpenURI` (via `gdbus`) to open URLs on Wayland. Requires `glib` as runtime dep for `gdbus`.

**Tag format in repo:** `v*.*.*` (not `xdg-utils-*.*.*` as one might expect).
