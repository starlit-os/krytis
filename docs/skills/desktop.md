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

### Greeter Vulkan renderer (WLR_RENDERER=vulkan)

With radv discoverable via `compat-vulkan-link`, the wlroots Vulkan renderer works on amdgpu:

- `WLR_RENDERER=vulkan` — wlroots uses the Vulkan backend (radv) instead of GLES2/pixman.
- `MESA_LOADER_DRIVER_OVERRIDE=zink` — GL/GLES2 calls in the greeter client go through
  Zink → radv, bypassing the broken radeonsi glvnd path.
- `WLR_NO_HARDWARE_CURSORS=1` is **not** needed with the Vulkan renderer (required for pixman only).

## Passing Environment Variables to the Greeter Compositor

**Do NOT use a systemd `Environment=` drop-in on `greetd.service` to pass env vars to the compositor.**

greetd constructs a clean PAM environment for the greeter child session — it does not inherit
its own systemd service environment into child processes. A drop-in that sets `WLR_RENDERER=pixman`
on greetd.service has no effect on `noctalia-greeter-compositor`. This was confirmed empirically:
the drop-in was present and the compositor still failed with the same renderer error.

**Correct approach:** prefix the command in `greetd config.toml` with `env VAR=val`:

```toml
[default_session]
command = "env WLR_RENDERER=vulkan MESA_LOADER_DRIVER_OVERRIDE=zink noctalia-greeter-session"
user = "greeter"
```

The `env` call runs before the compositor inherits the environment, so the vars are always present
regardless of PAM env construction.

`WLR_NO_HARDWARE_CURSORS=1` was required when pixman was active (pixman has no KMS cursor plane
support). It is not needed with `WLR_RENDERER=vulkan`.

## Toolkit Vulkan / Wayland Environment (#97)

Set in both `/etc/environment` (pam_env reads it → all sessions including greeter) and
`/usr/lib/environment.d/90-krytis-session.conf` (systemd reads it → user session units):

| Variable | Value | Effect |
|---|---|---|
| `GSK_RENDERER` | `vulkan` | GTK4 scene-kit uses Vulkan renderer (radv via compat-vulkan-link) |
| `SDL_VIDEODRIVER` | `wayland` | SDL2 apps use Wayland backend instead of X11 |

These are set in `config/greetd-config.bst`. `GDK_BACKEND=wayland` is not set explicitly — GTK4
already prefers Wayland when `XDG_SESSION_TYPE=wayland` is present.

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
