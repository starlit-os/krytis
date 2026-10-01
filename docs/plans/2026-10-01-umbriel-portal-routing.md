# Route Umbriel portals through xdp-gnome

**Issue:** #1029 · **Branch:** `1029-fix-umbriel-portal-routing-gaps` · **Worktree:**
`krytis.worktrees/fix/gh1029-fix-umbriel-portal-routing-gaps` · **Status: ready, waiting on the
Design Gate.** Flatpak apps under Umbriel get different dialogs and settings (see § Visible
changes), so a human signs off on § Decisions before step 1.

**Depends on** [#1027's plan](2026-10-01-niri-portal-routing-cleanup.md) step 1
(`mise run portal-routing-check`) and its *Verified facts*: the headless resolution command,
xdp's per-interface fall-through, and the `none` semantics. This plan does not repeat them.
It does not depend on [#1028](2026-10-01-oo7-secret-portal.md). Whichever of #1028 and #1029
lands first creates the element in step 1. The other adds its file or its line.

## Today (measured 2026-10-01, image built 2026-09-30, xdg-desktop-portal 1.22.1)

Under `XDG_CURRENT_DESKTOP=Umbriel`, xdp loads only upstream's
`/usr/share/xdg-desktop-portal/umbriel-portals.conf` (`default=umbriel;gtk`):

| Backend | Interfaces |
|---|---|
| umbriel | ScreenCast, Screenshot |
| gtk | Access, Account, DynamicLauncher, Email, FileChooser, Inhibit, Notification, Print |
| none | AppChooser, Background, Clipboard, GlobalShortcuts, InputCapture, Lockdown, RemoteDesktop, Secret, Settings, Usb, Wallpaper |

This is the issue's table, reproduced with #1027's headless command. It is also the initial
Umbriel table for `portal-routing-check`.

## Checked while writing (beyond the issue)

- **Umbriel provides no GNOME Shell or Mutter D-Bus names.** `noctalia-dev/umbriel` `main` @
  `26cd1fc` (2026-09-30) has no `org.gnome.Shell`/`org.gnome.Mutter` string anywhere. So
  every row the issue marks "broken" really is broken under Umbriel: Background
  (`org.gnome.Shell.Introspect`), GlobalShortcuts, RemoteDesktop, Clipboard, InputCapture.
  The issue's "presumably" for Background is now settled.
- **Wallpaper via xdp-gnome would be a silent no-op.** noctalia `main` @ `fd9759c` contains no
  `org.gnome.desktop.background` or `picture-uri` reference. The krytis fork
  (`kitten-lily/noctalia`, `feat/system-prompter`) adds only the prompter. So pin it to `none`,
  which is what it is today.
- **Settings via xdp-gnome does work.** noctalia writes
  `org.gnome.desktop.interface color-scheme` itself (`src/app/application_services.cpp:133`).
  xdp-gnome's Settings serves that key to Flatpaks.
- **xdp-gnome's FileChooser is Nautilus.** `src/filechooser.c` (xdp-gnome `a4f6ed6`) forwards
  to `org.gnome.Nautilus`. Nautilus already ships (`core/nautilus.bst`), and niri's
  FileChooser already goes this way.
- **xdp-gnome starts without Mutter.** libgxdp `gxdp_wayland_init` (`df896e34`, the revision
  xdp-gnome's wrap pins) falls back to plain GTK Wayland with a warning
  ("Compositor service channel missing, portal dialogs may misbehave") when
  `org.gnome.Mutter.ServiceChannel` is absent. The display-state and introspect trackers only
  watch their names. So routing to gnome under Umbriel does not take the whole backend down.
- **Umbriel parents portal dialogs itself.** umbriel#214 ("center dialogs over their parent and
  support xdg-foreign", merged 2026-09-10 as `936fb9c562`) is already in krytis's pinned ref
  `229d64a`. xdp-gnome and xdp-gtk dialogs should therefore open centred over the requesting
  app's window, whether or not the Mutter service channel exists. umbriel#215 (attach modal
  dialogs to their parent: shade the parent and follow it as it moves) is still open. Step 4
  checks what actually happens.
- **Nobody upstream is tracking any of the `none`-pinned interfaces.** As of 2026-10-01,
  `xdg-desktop-portal-umbriel`'s README lists only ScreenCast and Screenshot, and all 14 of its
  issues/PRs concern those two. In `noctalia-dev/umbriel`'s 353 issues/PRs, the only related
  one is umbriel#259 (forward XWayland global key grabs, e.g. Discord push-to-talk). It is
  open with no comments, and it covers X11 clients only, not the GlobalShortcuts portal.
  umbriel ships no libei/EIS. Any new interface would have to come from
  xdg-desktop-portal-umbriel itself, and `SCOPE.md` puts wallpaper handling in the shell, so
  Wallpaper will never come from umbriel. Expect these pins to stay for a long time. That
  is why step 2 makes their removal automatic. #1055 tracks getting real backends for them.

## Decisions (Design Gate)

| # | Question | Recommendation |
|---|---|---|
| D1 | Accept the visible changes below for Flatpak apps in Umbriel | yes. The niri session already behaves this way, so the two sessions converge |
| D2 | `Wallpaper=none` (today's state) instead of a gnome no-op | yes, see *Checked while writing* |
| D3 | Carry the routing downstream, or propose it to `noctalia-dev/xdg-desktop-portal-umbriel` | carry it. Upstream's file can't assume xdp-gnome is installed, and krytis's choice depends on krytis shipping xdp-gnome. Proposing it upstream is an **Upstream Gate** call: nothing is opened without an explicit instruction |

**Visible changes for Flatpak apps under Umbriel:**

- **File chooser:** xdp-gtk's GTK3 dialog becomes Nautilus's chooser (GTK4).
- **Settings:** dark/light and accent now reach Flatpak libadwaita apps. Today they get no
  Settings backend at all.
- **Print:** the GTK3 dialog becomes GTK4.
- **New backends:** AppChooser (the "open with" dialog), Lockdown and Usb gain one.
- **Unchanged:** Access, Notification, Inhibit and Email stay on xdp-gtk.

## Step 1 — Ship a krytis `umbriel-portals.conf`

- [ ] `files/xdg-desktop-portal/umbriel-portals.conf`:

  ```ini
  # krytis routing for XDG_CURRENT_DESKTOP=Umbriel. Loaded before upstream's
  # /usr/share/xdg-desktop-portal/umbriel-portals.conf (default=umbriel;gtk).
  # Because of the default= below, upstream's file is never reached for an
  # interface umbriel, gnome or gtk implements.
  # Why each pin: docs/skills/desktop.md § xdg-desktop-portal routing. krytis#1029.
  [preferred]
  default=umbriel;gnome;gtk;
  # xdp-gnome falls back to org.gnome.Shell for parentless requests.
  org.freedesktop.impl.portal.Access=gtk;
  # xdp-gnome forwards to org.gtk.Notifications (gnome-shell only); xdp-gtk
  # uses org.freedesktop.Notifications, which noctalia owns.
  org.freedesktop.impl.portal.Notification=gtk;
  # Umbriel provides no org.gnome.Shell / org.gnome.Mutter names. Leave these
  # unserved rather than route them to a backend that fails at call time.
  org.freedesktop.impl.portal.Background=none;
  org.freedesktop.impl.portal.GlobalShortcuts=none;
  org.freedesktop.impl.portal.RemoteDesktop=none;
  org.freedesktop.impl.portal.Clipboard=none;
  org.freedesktop.impl.portal.InputCapture=none;
  # xdp-gnome only writes org.gnome.desktop.background, which noctalia doesn't read.
  org.freedesktop.impl.portal.Wallpaper=none;
  ```

  xdp parses the file with `GKeyFile`, which treats `#` lines as comments. If a comment ever
  breaks parsing, xdp stops loading the file and `portal-routing-check` fails.
- [ ] `elements/config/xdg-desktop-portal-routing.bst`. Copy the shape of
      `config/xdg-terminals-list.bst`: `kind: manual`, `kind: local` source
      `files/xdg-desktop-portal`, and an install loop over `*-portals.conf` into
      `%{install-root}%{sysconfdir}/xdg/xdg-desktop-portal/`, so #1028 only adds a file.
      The element header carries the longer rationale:
  - `/etc/xdg` is the `$XDG_CONFIG_DIRS` tier, which a user can still override in
    `~/.config` (same reasoning as `xdg-terminals-list.bst`).
  - xdp falls through config files per interface.
  - A file here holds only what krytis changes. niri's will be a pure delta (#1028). This
    Umbriel file's `default=` shadows upstream's file for everything umbriel, gnome or gtk
    implements.
- [ ] `elements/stacks/desktop.bst`: add the element under `# ── XDG portals`, with a
      one-line comment.
- [ ] `files/fakecap-manifest.tsv`: add
      `/./etc/xdg/xdg-desktop-portal/umbriel-portals.conf	config/xdg-desktop-portal-routing.bst	monthly`
      (same form as the `xdg-terminals.list` row), and keep the file `LC_ALL=C`-sorted.

**Why `default=umbriel;gnome;gtk` and not an explicit allowlist (`default=none` + one key per
interface).** An allowlist would stop a *future* xdp-gnome interface from landing silently.
But `portal-routing-check` already catches that: it fails on any interface with no row. So
the allowlist would only add per-interface churn. Same shape as niri's file.

**One gap that portals.conf can't close.** If umbriel's backend ever drops ScreenCast or
Screenshot, the `default=` sends those to xdp-gnome, which calls Mutter/Shell and fails.
`Screenshot=umbriel;none` doesn't help, because `none` anywhere wins (#1027 plan). The routing
check's expected table is the guard: that change turns `build` red.

## Step 2 — Update the expected table

- [ ] `mise/tasks/portal-routing-check`, Umbriel table:

| Backend | Interfaces |
|---|---|
| umbriel | ScreenCast, Screenshot |
| gnome | Account, AppChooser, DynamicLauncher, FileChooser, Lockdown, Print, Settings, Usb |
| gtk | Access, Notification (pinned); Email, Inhibit (gnome lacks them) |
| none | Background, Clipboard, GlobalShortcuts, InputCapture, RemoteDesktop, Wallpaper (pinned); Secret (until #1028) |

Before the change, run the task against a scratch image with the conf bind-mounted
(`-v files/xdg-desktop-portal:/etc/xdg/xdg-desktop-portal:ro,Z` on the same `podman run`).
That confirms the table before paying for a build.

- [ ] Add a **stale-`none`** rule to `portal-routing-check`. The table above can't catch the
      case where umbriel grows one of the pinned interfaces: a `none` pin wins whatever is
      installed (#1027 plan), so the effective backend stays `none` and the check stays
      green.
  - Keep an `OWN_BACKEND` map in the task, `{"Umbriel": "umbriel"}`.
  - For each `<interface>=none` key in `/etc/xdg/xdg-desktop-portal/<d>-portals.conf`, fail
    when that desktop's own backend's `.portal` file lists the interface in `Interfaces=`,
    with "umbriel now implements <iface>: drop the pin". The task already reads every
    `.portal` file.
  - niri has no entry. It isn't a portal backend, and its gaps close inside niri itself
    (#1054), where no `.portal` file can show it.
  - `gnome` is deliberately not checked. It declares every pinned interface and is the
    reason for the pins.
  - **Negative check:** bind-mount a copy of `umbriel.portal` with `GlobalShortcuts` appended
    over `/usr/share/xdg-desktop-portal/portals/umbriel.portal`. The rule must fail.

## Step 3 — Docs

Every place that claims Umbriel routes `default=umbriel;gtk`:

- [ ] `docs/skills/desktop.md` lines 284–286 (Umbriel env port) and the line-346 paragraph
      as #1027 left it: Umbriel now has a krytis-owned delta in `/etc/xdg`.
- [ ] `files/umbriel/config.toml` lines 85–86 comment.
- [ ] `elements/desktop/xdg-desktop-portal-umbriel.bst` header (lines 14–19 as #1027 left
      them) and `elements/stacks/desktop.bst` lines 54–56: upstream's file is shipped but
      shadowed.
- [ ] `docs/plans/2026-09-30-gtk3-realistic-floor.md` lines 484–486 (*umbriel session*
      bullet). That plan is still live, and its step 6 (#181) reads this result. After this
      PR, Umbriel's xdp-gtk surface is the same as niri's: Access, Notification, Inhibit,
      Email.
- [ ] `docs/skills/desktop.md` § xdg-desktop-portal routing (#1027): add the "xdp-gnome
      outside GNOME" table from #1029, with source line references. Add the facts from
      *Checked while writing*, each with its upstream commit. This is the durable learning;
      the issue body is not where people look.
- [ ] `mise run docs-links`.

## Step 4 — Verify

- [ ] `mise run build`. `portal-routing-check` passes with the new table.
- [ ] `mise boot-test`, then log into an Umbriel session on the VM or real hardware
      (`compositor-smoke` doesn't exercise portals):
  - `/usr/libexec/xdg-desktop-portal --replace --verbose` loads
    `/etc/xdg/xdg-desktop-portal/umbriel-portals.conf` first, with the table above.
  - `busctl --user list | grep -E 'org.gnome.Shell|org.gnome.Mutter'` → empty (the static
    finding, confirmed live).
  - A Flatpak libadwaita app follows the noctalia dark/light toggle **live**, without a
    restart.
  - A Flatpak file chooser opens (Nautilus) and returns a file. Because of umbriel#214, expect
    it centred over the app's window. Expect it not to be modal yet: umbriel#215 is still
    open, so the parent can still be focused. If it isn't centred, record that in the
    desktop.md section. It is not a blocker.
  - `journalctl --user -u xdg-desktop-portal-gnome` shows startup warnings only, nothing
    failing.
  - A Flatpak notification still appears through noctalia (Notification stayed on gtk).

## Upstream candidate (Upstream Gate, nothing opened)

`noctalia-dev/xdg-desktop-portal-umbriel`'s `umbriel-portals.conf` could pin `Access` and
`Notification` to gtk and list gnome after umbriel when xdp-gnome is present. That's a
proposal to raise only on instruction. Report it in the PR description.
