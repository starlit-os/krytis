# Proton Pass as a Flatpak (`me.proton.Pass`)

Status: **native element stays; the switch to the Flathub build is deferred (2026-10-15).**
Click-to-copy is the reason. The Flathub fix for it relies on Xwayland passing the copy on
to the Wayland clipboard, and both of krytis's Xwayland bridges refuse to do that for this
app. Flathub also lags Proton's releases. This doc records the evidence, what would change
the decision, and the verification and removal steps, so none of it has to be re-derived.

`desktop/proton-pass.bst` (#206) ships Proton's `.deb`. Flathub's
[`me.proton.Pass`](https://github.com/flathub/me.proton.Pass) is **not** the same binary,
unlike Zen (#1237). It is built from `ProtonMail/WebClients` source and bundles its own
Electron (39.8.10 at 1.41.1) and its own libsecret.

## Why it is deferred

### Click-to-copy depends on an Xwayland path krytis's compositors refuse

[flathub/me.proton.Pass#37](https://github.com/flathub/me.proton.Pass/issues/37) ("Unable
to copy/paste from Pass to anything else") was closed on 2026-09-15 by
[#128](https://github.com/flathub/me.proton.Pass/pull/128). The cause and the fix, from
that thread:

- Click-to-copy goes through the `arboard` crate, not Electron. On Wayland, arboard uses
  the `wlr`/`ext` data-control protocols. Compositors that recognise a client as sandboxed
  (through `security-context-v1`) refuse it those protocols; niri is named as one of them
  in the thread. The app still shows its "copied" toast, and the clipboard keeps its old
  contents.
- #128 grants `--socket=x11` next to `--socket=wayland`. Electron stays on Wayland, and
  arboard falls back to writing the X11 clipboard. That only reaches Wayland apps if the
  Xwayland bridge passes it on.

**Neither of krytis's Xwayland bridges passes a copy on unless an X11 window has keyboard
focus.** The Pass window is a Wayland window, so no X11 window has focus when you click
copy. This conclusion comes from reading the source; it hasn't been run:

- **niri** runs `desktop/xwayland-satellite.bst` (v0.8.3). Satellite forwards an X11
  selection with `wl_data_device.set_selection` and its last keyboard serial
  (`set_selection_source` in
  [`src/server/selection.rs`](https://github.com/Supreeeme/xwayland-satellite/blob/v0.8.3/src/server/selection.rs)).
  smithay drops `SetSelection` from a client that doesn't have keyboard focus: "denying
  setting selection by a non-focused client"
  ([`src/wayland/selection/data_device/device.rs`](https://github.com/Smithay/smithay/blob/master/src/wayland/selection/data_device/device.rs),
  `master` on 2026-10-15). niri pins its own smithay revision `[INFERENCE: same check]`.
- **Umbriel** uses wlroots' built-in Xwayland (`desktop/wlroots.bst`, 0.20.2).
  [`xwayland/selection/incoming.c`](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/0.20.2/xwayland/selection/incoming.c)
  returns early when `xwm->focus_surface == NULL`: "denying write access to clipboard: no
  xwayland surface focused". The primary selection doesn't have that check
  (`wlr_seat_set_primary_selection` in the same file), so middle-click paste may work even
  though Ctrl+V doesn't.
- As of 2026-10-15, no one on #37 has said whether the fix works. The last report, from
  2026-09-12 on COSMIC, came before it.

The native build doesn't have this problem because it isn't sandboxed. niri gives it
data-control, so arboard's Wayland path works.

**The X11-only workaround isn't a good default.** Running the whole app under X11 puts the
Pass window on X11, so it has focus when you click copy and both bridges pass the copy on.
`flatpak override --env=XDG_SESSION_TYPE=x11 me.proton.Pass` does that. Electron 38
replaced `ELECTRON_OZONE_PLATFORM_HINT` with Chromium's `XDG_SESSION_TYPE` check, and
38.2.0/39.0.0 wired it up
([electron#48301](https://github.com/electron/electron/pull/48301)). It has three costs:

- The app renders through Xwayland, with satellite's scaling instead of fractional Wayland
  scaling.
- A password manager would share an X11 socket with every other X11 client. That is a
  Security Gate question.
- The image can't ship it cleanly. In a live session, `XDG_DATA_DIRS` lists both Flatpak
  export directories before `/usr/share` (checked on krytis 2026-10-15), so a `.desktop`
  override in the image would lose to the Flatpak's own. Overrides live under
  `/var/lib/flatpak/overrides/` or `~/.local/share/flatpak/overrides/`, and a bootc image
  doesn't manage either after install.

### Flathub lags Proton's releases

Proton released 1.42.0 on 2026-10-07. Flathub still serves 1.41.1
(`flatpak remote-info flathub me.proton.Pass`, 2026-10-15), and its four bot PRs for 1.42.0
([#132–#135](https://github.com/flathub/me.proton.Pass/pulls)) had all failed
`builds/x86_64` as of 2026-10-15. Building a monorepo from source breaks whenever upstream
reshuffles it, so the lag will recur. `mise run proton-pass-update` follows Proton's own
`version.json` and takes no extra work.

## What the switch would gain

- The GTK3 floor in `mise/tasks/gtk3-audit` loses one entry. With #1237 as well, only
  `xdg-desktop-portal-gtk` and Solaar remain (#641).
- `mise run proton-pass-update` and the `track-proton-pass` CI job go away.
- Pass updates through `flatpak update` instead of an image rebuild, `bootc upgrade` and a
  reboot.
- The app gets a sandbox. The native build runs with full user privileges.

Not a factor either way:

- **Autotype** doesn't work in either build. Both use enigo's libei backend
  (`applications/pass-desktop/native/napi/Cargo.toml` in WebClients:
  `features = ["libei_tokio"]`), which needs the RemoteDesktop portal. krytis routes that
  portal to `none` under niri (#1054) and Umbriel (#1029). niri's own RemoteDesktop
  implementation, [niri-wm/niri#1966](https://github.com/niri-wm/niri/pull/1966), was
  still open as of 2026-10-15.
- **Browser-extension integration** (native messaging) isn't a factor either:
  `docs/design/native-messaging-proxy.md`.

## Revisit when

Any one of these should reopen the decision:

- Someone confirms on #37 that click-to-copy works on niri or a wlroots compositor, or
  Proton Pass starts copying through a path that works inside a sandbox. One candidate is
  arboard's [1Password/arboard#209](https://github.com/1Password/arboard/pull/209)
  (smithay-clipboard backend), open as of 2026-10-15; whether it helps a sandboxed app
  needs testing.
- The Flathub build keeps up with Proton's releases for a while.
- The native element breaks in a way that's expensive to fix.

Then run the verification below. If it passes, do the removal.

## Verification (no repo changes)

Run this on a krytis machine with a real session. Do every clipboard step under both niri
and Umbriel. Paste into a Wayland-native text field such as seance or Zen's address bar.

1. **Baseline the native build.** Click-copy a username, a password and a TOTP code, and
   paste each with Ctrl+V and with middle-click. If native already fails somewhere, the
   Flatpak failing there isn't a regression.
2. **Install the Flatpak.** Quit native Pass from its tray first (it holds
   `~/.config/Proton Pass/SingletonLock`), then:
   ```shell
   flatpak install --user flathub me.proton.Pass
   flatpak info --user me.proton.Pass                     # record version + commit
   flatpak info --user --show-permissions me.proton.Pass  # expect sockets=wayland;x11
   flatpak run me.proton.Pass                             # log in fresh
   ```
3. **Clipboard matrix.** Repeat the baseline with the Flatpak. The prediction above: Ctrl+V
   fails under both compositors, and middle-click may work under Umbriel.
4. **If anything fails, try the X11 workaround:**
   `flatpak override --user --env=XDG_SESSION_TYPE=x11 me.proton.Pass`, then relaunch.
   `niri msg windows` should show the window coming through satellite. Repeat the matrix
   and check scaling on a HiDPI output. Afterwards, run
   `flatpak override --user --reset me.proton.Pass`.
5. **Other differences:**

   | Item | Native | Flatpak | Check |
   |---|---|---|---|
   | Window rules | `files/niri/rules.kdl` and `files/umbriel/rules.toml` match the app_id `Proton Pass` | The manifest runs `patch-electron-desktop-filename` on `app.asar`, so the app_id should become `me.proton.Pass` `[INFERENCE]` | `niri msg windows` |
   | Staying logged in | system libsecret → oo7-daemon | bundled libsecret, `--talk-name=org.freedesktop.secrets` → oo7-daemon directly, not the Secret portal. Flathub's #7 was a logout loop | Restart the app, then reboot; still logged in |
   | Tray | StatusNotifierItem | `--talk-name=org.kde.StatusNotifierWatcher` | Icon and menu appear in noctalia's tray |
   | Links | `shell.openExternal` → `xdg-open` | OpenURI portal | A link in an item opens the browser |
   | Clipboard auto-clear | arboard | arboard, same bridges | Clears after the configured delay |
   | Security-key login | host `/dev/hidraw*` | `--device=all` | Only if the account uses a key |
   | Native-messaging host | not in the `.deb` | The manifest builds `native/host`; whether it ships isn't known | `flatpak run --command=sh me.proton.Pass -c 'find /app -name "proton_pass_nm_host*"'`; record the result in `docs/design/native-messaging-proxy.md` |

6. **Write down the result here** with the date and versions. If it fails, run
   `flatpak uninstall --user --delete-data me.proton.Pass`.

## Removal

Follow `docs/skills/bst.md` § Removing an element touches more than the element. The
lists below came from a grep for `proton-pass`, `Proton Pass`, `me.proton.Pass` and
`proton_me` on 2026-10-15. Grep again before relying on them.

**Delete**
- the element, and its "Password manager" block in `elements/stacks/desktop-apps.bst`
- `mise/tasks/proton-pass-update`
- in `.github/workflows/track-bst-sources.yml`: the `proton-pass` `group` option and the
  `track-proton-pass` job
- the element's rows in `files/fakecap-manifest.tsv` (105 on 2026-10-15)
- the two `proton-pass` floor rows in `mise/tasks/gtk3-audit`
- `me.proton.Pass` in `files/bazaar/blocklist.yaml`
- the `proton_me` alias in `include/aliases.yml`. The element is its only user; grep
  `mise/` again first.

The element's other runtime deps stay in the image: `desktop/xdg-utils.bst` is in
`stacks/desktop.bst`, seance uses libnotify, and noctalia uses libsecret. Diff
`mise run bst -- show --deps run stacks/desktop-apps.bst` before and after to confirm
nothing else leaves.

**Update**
- the Proton Pass window rules in `files/niri/rules.kdl` and `files/umbriel/rules.toml`:
  match the app_id measured during verification
- the comment in `elements/config/proton-pass-keyring.bst` that says the image ships the
  Electron GUI. The element itself stays, because it's for pass-cli.
- `docs/design/image-inventory.md`, `docs/design/bazaar-curated-candidates.md` (the
  "ships natively" blocklist rationale), `docs/design/native-messaging-proxy.md`, and the
  floor list in `docs/plans/2026-09-30-gtk3-realistic-floor.md`
- the open issue bodies that state the floor or cite the `.deb`: #641 and #1237
- how users get it: add it to `APPS` in `files/flatpak-preinstall/flatpak-preinstall.sh`,
  add a Bazaar tile, or ship a release note. The preinstall script stops running once
  `/var/lib/flatpak/.krytis-preinstall-done` exists, so existing installs would never get
  it. Whichever route is chosen, `/usr/bin/proton-pass` disappears on the next
  `bootc upgrade`.

**Re-scope to past tense** (the way #1005 and #1194 did it), citing the element by its
bare name `desktop/proton-pass.bst`. In `docs/skills/bst.md`: the GTK3-audit example,
§ .deb extraction in BST sandbox, § Electron self-updaters on a read-only image (whose
preamble calls the element "the live example"), and the runtime-deps examples after it.

**Leave alone.** These are about pass-cli and the vault, not the GUI: `fnox.toml`, the
`pass-cli` pin in `mise.toml`, `.github/renovate.json5`, the `PROTON_PASS_PAT` step in
`publish.yml`, the secure-boot design docs, `docs/skills/mise.md` § Secret retrieval via
fnox (Proton Pass), and `docs/skills/fido2.md`.

**Migration.** Native Pass keeps its data in `~/.config/Proton Pass/`; the Flatpak keeps its
own under `~/.var/app/me.proton.Pass/`. Log in fresh rather than copying, because
Flathub's older release would be reading newer data. Afterwards, delete the native data
directory and the `me.proton.pass.nm.json` files native Pass writes on every launch, in
`~/.mozilla/native-messaging-hosts/`, `~/.config/chromium/NativeMessagingHosts/` and
`~/.config/google-chrome/NativeMessagingHosts/`. They point into `/usr/lib/proton-pass/`.
