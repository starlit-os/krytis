# Remove the dead niri portal routing file

**Issue:** #1027 · **Branch:** `1027-fix-dead-niri-portal-routing` · **Worktree:**
`krytis.worktrees/fix/gh1027-fix-dead-niri-portal-routing` · **Status: ready, not started.**
**Gates:** none. Routing does not change; step 2 proves it.

Lands **first** of the three portal plans. Its step 1 gate measures the other two:
[#1029](2026-10-01-umbriel-portal-routing.md) (Umbriel routing) and
[#1028](2026-10-01-oo7-secret-portal.md) (oo7 Secret backend).

## Decision: delete the file, don't replace it

#1027 offers two fixes: delete, or keep a krytis override in `/etc/xdg`. This plan deletes:

- The file has never had any effect, so deleting it changes nothing. Measured below.
- The issue's case against the override ("an `/etc` override fully replaces niri's file")
  does not hold for xdg-desktop-portal 1.22.1. xdp **falls through** config files per
  interface (proof below). The Secret route #1028 needs is therefore a one-key delta file, and
  everything else keeps coming from niri's file. That delta belongs in #1028's PR, under its
  Security Gate, next to the backend it routes to. Without the backend it does nothing.
- krytis needs no other niri routing change today.

## Verified facts (2026-10-01)

Image `localhost/krytis:latest`, built 2026-09-30. `xdg-desktop-portal --version` →
`1.22.1`. niri pinned at `v26.04` (`elements/desktop/niri.bst`).

**Routing resolves headlessly.** No session, GPU, seat or root is needed:

```shell
podman run --rm -e XDG_CURRENT_DESKTOP=niri localhost/krytis:latest sh -c \
  'timeout 5 dbus-run-session -- /usr/libexec/xdg-desktop-portal --verbose 2>&1'
```

At startup xdp logs `Using portal configuration file '<path>' for desktop '<d>'` for each
config it loads, then `Using <backend>.portal for org.freedesktop.impl.portal.<Iface> (…)`
for every interface it can serve. In the container the backends then fail to *activate*.
That is expected and harmless here, because routing is decided before activation. An
interface with no backend gets `Found '<x>' in configuration for …` lines but no `Using` line.
The whole resolution took about 1.2 s (timestamps 08:50:34.77 → 08:50:35.96).

**niri routing today**, from that command. The only config loaded is niri upstream's
`/usr/share/xdg-desktop-portal/niri-portals.conf`:

| Backend | Interfaces |
|---|---|
| gnome | Account, AppChooser, Background, Clipboard, DynamicLauncher, FileChooser, GlobalShortcuts, InputCapture, Lockdown, Print, RemoteDesktop, ScreenCast, Screenshot, Settings, Usb, Wallpaper |
| gtk | Access, Notification (both from the interface-specific keys), Email, Inhibit |
| none | Secret (`gnome-keyring` is not installed; #1028) |

**The dead file only shows up as a warning.** xdp logs it twice per start:
`Error loading /usr/share/xdg-desktop-portal/portals/niri.portal: Key file does not have group "portal"`.

**xdp falls through config files per interface.** In
`src/xdp-portal-config.c::xdp_portal_config_find` (tag `1.22.1`), xdp walks the loaded
configs from highest precedence down. In each config:

1. `none` for the interface (or for `default`, if the interface has no key) → stop, no backend.
2. The interface's own key names an installed backend that implements it → use that backend.
3. `default` names one → use that backend.
4. Otherwise, **try the next config file.**

A file without `default=` is valid: `load_portal_configuration_for_dir` treats every key the
same way. Tested on the image by bind-mounting a two-key `/etc/xdg/xdg-desktop-portal/niri-portals.conf`
(`FileChooser=gtk;`, `Wallpaper=none;`). xdp loaded both files. FileChooser moved to gtk and
Wallpaper went to none. Every other interface resolved exactly as before, including
`Access`/`Notification`, which came from the `/usr/share` file's interface-specific keys.

portals.conf(5) documents the precedence order but not the fall-through. It is implementation
behaviour, and step 1 therefore gates it. Two consequences matter to the sibling plans:

- `none` anywhere in a value list means none, wherever it appears:
  `portal_config_interface_prefers_none` is a `g_strv_contains`. `Screenshot=umbriel;none`
  is always none. portals.conf cannot express "this backend or nothing".
- A higher file's `default=` captures every interface its listed backends implement, so a
  lower file is only consulted for interfaces none of them implement.

**Correction to the issue.** niri v26.04 *does* implement `org.gnome.Shell.Screenshot`
(`src/dbus/gnome_shell_screenshot.rs`). It also implements `org.gnome.Shell.Introspect` and
Mutter's `ScreenCast`, `DisplayConfig` and `ServiceChannel` (`src/dbus/` at the tag). The dead
file's Screenshot pin was redundant, not wrong. Keep "niri lacks org.gnome.Shell.Screenshot"
out of the docs.

## Step 1 — `mise run portal-routing-check`

A ratchet in the shape of `mise/tasks/gtk3-audit`: the expected state lives in the task, and
a change in either direction fails.

- [ ] `mise/tasks/portal-routing-check`, python3, `#USAGE flag "--tag <tag>"` defaulting to
      `localhost/krytis:latest`.
- [ ] One `podman run --rm --entrypoint sh` that loops over the desktops `niri` and
      `Umbriel`. For each, run the command above with `XDG_CURRENT_DESKTOP` set to that
      desktop, and `cat` every `/usr/share/xdg-desktop-portal/portals/*.portal` and
      `/etc/xdg/xdg-desktop-portal/*.conf`. One container start, not two. Measure the
      shortest `timeout` that still captures every `Using` line (≈1.2 s seen above), and
      leave margin.
- [ ] Parse `Using (\S+)\.portal for org\.freedesktop\.impl\.portal\.(\w+)`. The interface
      universe is the expected table's keys ∪ every interface declared in an installed
      `.portal` file. An interface with no `Using` line is `none`.
- [ ] Expected table in the task: one dict per desktop, `interface → (backend, reason)`, with
      the reason in a few words, like gtk3-audit's rows. Initial content: the niri table
      above, and the Umbriel table from [#1029's plan](2026-10-01-umbriel-portal-routing.md)
      § Today.
- [ ] Fail on:
  - any interface whose backend differs from the table (print `iface: expected X, got Y`);
  - an interface in the universe with no row (a backend grew one, so a human classifies it);
  - any `Error loading …` warning: an unparsable `.portal` file is exactly this bug;
  - no `Using portal configuration file` line for a desktop: no routing file at all means
    xdp is on its legacy `UseIn` fallback.
- [ ] Wire it into `mise/tasks/build` after `cracklib-dict-check`, with the same kind of
      comment those calls carry. Reasons: `desktop/xdg-desktop-portal-umbriel.bst` tracks
      `refs/heads/main` and is bumped daily, niri's file changes with every niri bump, and a
      routing change is otherwise invisible until a Flatpak misbehaves. The same reasoning
      put `umbriel-config-validate` into `build`.
- [ ] Update the `build` task's `#MISE description`, AGENTS.md § Mandatory Gates →
      Verification (it spells out the `mise run build` chain), and `docs/skills/mise.md`:
      the task table (Desktop / session row) and § Standard build workflow.

Before step 2 the task fails on the `niri.portal` warning. After step 2 it passes. That is
the regression proof.

## Step 2 — Delete `config/xdg-portals.bst`

- [ ] `git rm elements/config/xdg-portals.bst`.
- [ ] `elements/stacks/desktop.bst`: drop the entry and its three-line comment (lines 58–61
      at `5a5da59`).
- [ ] `files/fakecap-manifest.tsv`: delete the one row
      `/./usr/share/xdg-desktop-portal/portals/niri.portal	config/xdg-portals.bst	monthly`.
      Apply only this delta and keep the file `LC_ALL=C`-sorted (precedent: `36afa08`).
- [ ] Check that nothing else references it: `grep -rn 'xdg-portals' --exclude-dir=done`.
      At `5a5da59` the only other hits are docs (step 3) and the untracked, generated
      `krytis.spdx.json`.

## Step 3 — Fix every doc that describes the file

The fix's payload is "the documented thing was wrong", so edit the old text in place. Don't
append a correction beside it (AGENTS.md § What the first sweep learned).

- [ ] `docs/skills/desktop.md` § xdg-desktop-portal Backend Routing for niri (line 1303):
      rewrite as **§ xdg-desktop-portal routing**. Contents: descriptor
      (`portals/*.portal`, `[portal]`, `DBusName=`/`Interfaces=`) vs routing
      (`<desktop>-portals.conf`, `[preferred]`); the precedence list; the fall-through and
      the `none` semantics from *Verified facts*; which element ships which file (niri's from
      `desktop/niri.bst`, Umbriel's from `desktop/xdg-desktop-portal-umbriel.bst`); the
      headless command; `mise run portal-routing-check`; the list of GNOME D-Bus names niri
      implements. Delete the false "without this file … default-app lookups fail" claim. The
      file never worked, and lookups did not fail.
- [ ] `docs/skills/desktop.md` line 346, "No `config/xdg-portals.bst`-style routing file
      needed for umbriel": remove the niri comparison. Keep the umbriel fact (upstream ships
      `umbriel-portals.conf`) until #1029 changes it.
- [ ] `elements/desktop/xdg-desktop-portal-umbriel.bst` header lines 14–19: drop the
      "unlike niri's config/xdg-portals.bst …" clause the same way.
- [ ] `elements/stacks/desktop.bst` lines 54–56 ("unlike niri, below"): drop the comparison.
- [ ] New § in `docs/skills/desktop.md`, or a paragraph in the rewritten section: **a
      `portals/*.portal` file is a backend descriptor, and a file without `[portal]` is
      skipped with only a warning.** That is how this file sat dead from the start.
- [ ] `mise run docs-links`.

## Verify

- `mise run build`. It now ends in `portal-routing-check`, which passes, and its niri table
  is byte-identical to *Verified facts* above.
- `podman run --rm localhost/krytis:latest ls /usr/share/xdg-desktop-portal/portals/` →
  `gnome.portal gtk.portal umbriel.portal`.
- `mise boot-test`, then in a niri session on the VM:
  `/usr/libexec/xdg-desktop-portal --replace --verbose` shows the same table, with a backend
  actually activated. The issue's own Verify.
- Negative check for the task: put the deleted element back in a scratch build (or bind-mount
  a bogus `.portal` with `-v`) and see the task fail on `Error loading`.

## Out of scope, found while writing

- **niri routes GlobalShortcuts, RemoteDesktop, Clipboard and InputCapture to xdp-gnome**,
  and niri v26.04 implements none of the Shell/Mutter names xdp-gnome needs for them (see the
  `src/dbus/` list above and #1029's dependency table). It is the same failure class #1029
  fixes for Umbriel. Filed as #1054, with its upstream status. Not changed here, because this
  plan changes no routing.
