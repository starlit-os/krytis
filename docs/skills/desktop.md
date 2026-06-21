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

**Force pixman when needed** via a systemd drop-in (see below). pixman uses DRM dumb buffers
as its allocator, which work on all drivers including amdgpu.

### GLES2 on amdgpu fails with fdsdk mesa

wlroots attempts GLES2 via EGL with the render node fd. This requires the glvnd EGL dispatch to
route the call to `libEGL_mesa.so.0` and for MESA-LOADER to find `radeonsi_dri.so`. With fdsdk's
non-standard mesa prefix, this path currently fails (root cause unresolved as of 2026-06-21 —
see issue #95 / parent #94). The fix in use is `WLR_RENDERER=pixman`.

### Vulkan path not yet verified

Both `WLR_RENDERER=vulkan` (wlroots Vulkan renderer) and `MESA_LOADER_DRIVER_OVERRIDE=zink`
(OpenGL via Vulkan/radv) require the radv Vulkan ICD to be discoverable by the Vulkan loader.
The ICD JSON is in the non-standard mesa path; the Vulkan loader does not search it by default.
Fix: set `VK_ICD_FILENAMES` (or `VK_DRIVER_FILES`) to the radv ICD JSON path, or install the
ICD JSON to `/usr/share/vulkan/icd.d/`. Tracked in #95 (wlroots Vulkan), #96 (Zink), parent #94.

## Greeter Service Drop-in Pattern

Add per-service environment overrides in `config/greetd-config.bst`:

```bst
- |
  install -Dm644 /dev/stdin \
    "%{install-root}%{sysconfdir}/systemd/system/greetd.service.d/<name>.conf" <<'EOF'
  [Service]
  Environment=VAR=value
  EOF
```

Current active drop-in — `wlr-renderer.conf`:
```ini
[Service]
Environment=WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1
```

`WLR_NO_HARDWARE_CURSORS=1` is required when pixman is active: the pixman path has no KMS
cursor plane support and will otherwise log cursor errors and potentially crash.

## niri vs wlroots

niri uses **smithay** (pure Rust), not wlroots. Its rendering stack handles EGL/GPU failures
differently — smithay falls back more gracefully, which is why niri works from a TTY on amdgpu
even when wlroots-based compositors (noctalia-greeter-compositor) fail.

## Diagnostic Commands (run on the booted image)

```bash
# Check which DRM devices are present
ls -la /dev/dri/

# Greeter compositor log (all past sessions)
cat /var/log/noctalia-greeter.log

# Current greetd service status and environment
systemctl show greetd.service | grep Environment
journalctl -u greetd --boot

# Check Vulkan ICD files (for radv)
find /usr/lib -name '*radeon*icd*.json' 2>/dev/null
```
