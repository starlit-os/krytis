# Host requirements for the MX Control noctalia plugin

**Issue:** #1220 · **Status (2026-10-14): steps 1 and 2 shipped in #1244.** Step 3's hardware
check is tracked in its own draft PR, which archives this plan once the results below are
filled in. Step 3's skill write-back (`docs/skills/desktop.md`, `docs/skills/bst.md`) landed
with #1244.

| Plugin | Catalog id | What it executes |
|---|---|---|
| MX Control | `gamaraan/mx-control` 0.2.2, `plugin_api` 24 | `python3 backend/mxctl.py serve`, which imports Solaar's `logitech_receiver` and `solaar` packages and opens Logitech `/dev/hidraw*`; `pkill`; `hyprctl` |

From `noctalia-dev/community-plugins` at `1f12fa9` (2026-10-13). The `dependencies =` field in
a plugin's `plugin.toml` is informational only (mx-control's own comment says so), so the
requirements below come from reading what the plugin executes.

The Razer Devices plugin, which needs out-of-tree kernel modules, is planned separately under
#1224. The two share one element, `deps/python3-pyudev.bst`; whichever plan lands first adds
it. Each step below is one PR.

## Non-goals

- **Enabling the plugin in `files/noctalia-skel/settings.toml`.** It is hardware-specific. A
  user turns it on in Settings → Plugins (see `docs/skills/desktop.md`
  § noctalia plugins: enabling in skel).
- **The Solaar GUI.** The plugin replaces it. Its `.desktop` launcher and metainfo are deleted
  in the element (step 2).
- **MX Control's Hyprland-only features** (per-app shortcuts, pointer acceleration through
  `hyprctl`). They are upstream's documented limit, and every hardware setting works on niri.
- **Anything against `pwr-Solaar/Solaar` or the plugin author.** No issue, no PR, no comment
  without explicit approval (AGENTS.md § Third-party repositories).

## Design Gate decision

**Decided 2026-10-14: Solaar is a declared `floor` consumer; no patch.** The carried patch was
sized before deciding (one file, 12 lines added, 7 removed) and skipped because it saves no
bytes while the other floor apps keep GTK3. Its contents, and what it would not cover (the
`solaar` CLI imports Gtk 3 regardless), are in `docs/plans/2026-09-30-gtk3-realistic-floor.md`
§ Solaar: a floor consumer through GObject introspection.

| Decision | Recommendation |
|---|---|
| Solaar becomes a declared consumer of `gnome-build-meta.bst:sdk/gtk+-3.bst`, with a new `gtk3-audit` row | Yes, tagged `floor`. GTK3 ships for its floor apps regardless, so the image does not grow. The alternative is a carried patch making `diversion.py`'s Gdk import optional, which is a permanent rebase cost for zero bytes saved. |

## Reference: measured facts

All measured on `26.08.202610131212`, unless stated otherwise.

### MX Control / Solaar 1.1.20 (released 2026-06-28)

| Fact | Evidence |
|---|---|
| Import-time deps of what `mxctl.py:703-711` imports: `pyudev` (`hidapi/udev_impl.py`), `yaml` and `typing_extensions` (`hidpp20.py`), and `psutil`, `evdev` plus `gi.require_version("Gdk", "3.0")` (`diversion.py:36-54`, pulled in by `settings_templates`) | Read at tag `1.1.20`. Throwaway venv (`--system-site-packages`, `pip install --no-deps solaar==1.1.20`, plus pyudev, psutil and typing_extensions): `device`, `receiver` and `settings_templates` fail with `No module named 'evdev'`; with `evdev` stubbed, all five import. |
| Not needed: `python-xlib`, `dbus-python` (imported lazily in functions), `hid-parser`, Notify (inside `try`) | Same read. Solaar's `install_requires` lists more than it imports. |
| In the image: `python3` 3.14.7, PyYAML 6.0.3, PyGObject 3.58.0, `Gdk-3.0.typelib` | `/usr/bin/python3 -c 'import gi; gi.require_version("Gdk","3.0"); from gi.repository import Gdk'` succeeds |
| In fdsdk, not shipped: `components/python3-psutil.bst`, `components/python3-typing-extensions.bst` | fdsdk `freedesktop-sdk-26.08.2` |
| In no junction: `pyudev`, `evdev` | No element in fdsdk 26.08.2 or gnome-build-meta `51.0-10` |
| `evdev` builds a C extension; it does not install from pip on the host (no compiler) | Throwaway venv |
| hidraw is root-only: every `/dev/hidraw*` is `crw------- root root`. `71-logitech-gdu.rules` covers only the F310/F710 gamepads (`046d:c216`, `c21f`). | `ls -l /dev/hidraw*`; `/usr/lib/udev/rules.d/71-logitech-gdu.rules` |
| With Solaar importable, the helper sees the hardware but cannot open it | `mxctl.py discover` → `"installed": true, "accessible": false`, G915 TKL on Lightspeed receiver `046d:c547` |
| Solaar's `rules.d/42-logitech-unify-permissions.rules` tags hidraw `uaccess` for `046d` over USB and Bluetooth (`KERNELS=="0005:046D:*"`) and for Lenovo `17ef:6042`. Its uinput rule duplicates the existing `71-uinput-dev-early-creation.rules`. | Read at tag `1.1.20`; `setup.py` installs it to `lib/udev/rules.d` under the prefix |
| `setup.py` `data_files` also installs `share/applications/solaar.desktop`, `share/metainfo/…`, icons and locales. It installs no autostart entry. | `setup.py:30-39` at `1.1.20` |

## Steps

### 1. Python dependency elements

- `elements/deps/python3-pyudev.bst` (shared with #1224; skip if it already exists): `kind: pyproject`, `git_repo` `github:pyudev/pyudev.git`,
  `track: v*` (latest `v0.24.5`). Runtime deps: `freedesktop-sdk.bst:components/python3.bst`.
  pyudev loads `libudev.so.1` with ctypes. fdsdk 26.08.2 has `components/systemd-libs.bst`;
  confirm with `bst artifact list-contents` that it ships `libudev.so.1`, then add it.
- `elements/deps/python3-evdev.bst`: `kind: pyproject`, `git_repo`
  `github:gvalkov/python-evdev.git`, `track: v*` (latest `v2.0.0`). It is a C extension, and
  its build reads `/usr/include/linux/input*.h`. Those headers come from fdsdk's
  `bootstrap/linux-headers.bst`; check that `public-stacks/buildsystem-python-setuptools.bst`
  already stages it before adding an explicit build-depend.
- Pattern: `elements/dev/virt-firmware.bst`. It is the only `kind: pyproject` element in the
  repo, and `docs/skills/bst.md` has no Python packaging section; step 3 adds one.
- Add both to the `track` matrix in `.github/workflows/track-bst-sources.yml`, using the
  `- group:` / `element:` / `branch: auto/track-<name>` / `title:` row format (AGENTS.md
  § Update path gate).

**Check:** `mise run validate`; `./mise/tasks/bst build deps/python3-evdev.bst`; the artifact
contains `site-packages/evdev/_input*.so`.

### 2. `elements/desktop/solaar.bst`

- `kind: pyproject`, `git_repo` `github:pwr-Solaar/Solaar.git`. Tags are bare versions
  (`1.1.20`), so `track: '[0-9]*'`. Add a `track` matrix row.
- Runtime deps: `components/python3.bst`, `components/python3-pyyaml.bst`,
  `components/python3-psutil.bst`, `components/python3-typing-extensions.bst`,
  `components/pygobject.bst` (resolves to gnome-build-meta's through the junction override),
  `gnome-build-meta.bst:sdk/gtk+-3.bst` (the Design Gate decision: `diversion.py` needs the Gdk-3.0 typelib at
  import time), `deps/python3-pyudev.bst`, `deps/python3-evdev.bst`. Do **not** add
  `python-xlib` or `dbus-python`; nothing on the plugin's path imports them.
- Keep `/usr/lib/udev/rules.d/42-logitech-unify-permissions.rules` and `/usr/bin/solaar` (the
  CLI: `solaar show` and `solaar config` need no GTK window). Delete
  `share/applications/solaar.desktop` and `share/metainfo/io.github.pwr_solaar.solaar.metainfo.xml`
  in `install-commands`. They advertise a GUI that needs a tray backend krytis does not ship.
  Follow `docs/skills/bst.md` § Overriding `install-commands`: run the real install first.
- Add to `elements/stacks/desktop.bst` § Input devices. In the same edit, correct the
  `game-devices-udev` comment's "Logitech": it covers two Logitech gamepads, not HID++
  devices.
- Add the decided row to `mise/tasks/gtk3-audit`'s `ELEMENTS`:
  `"desktop/solaar.bst": ("floor", "Solaar diversion.py imports Gdk 3.0 at load")`. Add a
  matching note to `docs/plans/2026-09-30-gtk3-realistic-floor.md`'s floor list.

**Check:** `mise run build` (includes lint). `mise run gtk3-audit` passes; it runs neither in
`build` nor in CI. In the loaded image:
`podman run --rm localhost/krytis:latest python3 -c 'import logitech_receiver.settings_templates, solaar.configuration'`
exits 0.

### 3. Verify on hardware, write back

On a booted image (`mise run boot-vm` is not enough: it needs real HID++ hardware):

1. Unplug and replug the receiver. `ls -l /dev/hidraw*` shows `+` (ACL) on the Logitech nodes.
   Run `getfacl` on one of them.
2. `python3 <plugin dir>/backend/mxctl.py discover` returns `"accessible": true`.
3. Enable `gamaraan/mx-control` in Settings → Plugins and add the bar widget. The capsule
   shows battery, and the panel shows DPI and the device settings.

Then update `docs/skills/desktop.md` § noctalia plugins: enabling in skel with a "hardware-backed plugins"
entry: `dependencies` is informational, so read what the plugin executes; Solaar's import
chain; the uaccess rule. Add a short Python-packaging section to `docs/skills/bst.md`
(`kind: pyproject` pattern, C extensions need fdsdk's kernel headers, `install_requires` is
not resolved, so declare only what is actually imported).

Archive this plan to `docs/plans/done/` in the same PR.

## Step 3 results

Image: _version under test_ (first build containing #1244). Hardware: G915 TKL on Lightspeed
receiver `046d:c547`.

| Check | Result |
|---|---|
| `/dev/hidraw*` for the receiver after a replug: `ls -l` shows `+`, `getfacl` has `user:<seat user>:rw-` | _pending_ |
| `python3 <plugin dir>/backend/mxctl.py discover` → `"accessible": true`, device listed | _pending_ |
| MX Control enabled in Settings → Plugins: bar capsule shows battery | _pending_ |
| Panel shows DPI and device settings; a setting change applies | _pending_ |
