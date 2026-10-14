# Native messaging for a Flatpak browser — xdg-native-messaging-proxy

Status: **not in the image; deliberately deferred (2026-10-14).** Nothing krytis ships
needs it today. This records what adding it would take, so the work isn't re-derived
when something does need it.

## Problem

Browser extensions reach a desktop app through *native messaging*: the browser reads a
JSON manifest (`~/.mozilla/native-messaging-hosts/<name>.json` for Firefox-family
browsers) and spawns the host program it names, talking to it over stdio. Password
managers use this for desktop-app integration (KeePassXC, 1Password, Bitwarden's
biometric unlock), as do media helpers like ff2mpv.

A Flatpak browser can do neither half. The sandbox hides the host's manifest
directories, and the browser cannot exec a program on the host. Zen's own tracker
answers the KeePassXC report with "Cannot fix from Zen's end"
([zen-browser/desktop#11084](https://github.com/zen-browser/desktop/issues/11084),
open as of 2026-10-14).

The native `desktop/zen-browser.bst` has no such problem: it is unsandboxed and spawns
hosts itself, reading `~/.mozilla/native-messaging-hosts/` rather than a Zen-specific
directory ([zen-browser/desktop#10622](https://github.com/zen-browser/desktop/issues/10622)).

## The fix that exists upstream

[flatpak/xdg-native-messaging-proxy](https://github.com/flatpak/xdg-native-messaging-proxy)
is a session D-Bus service, `org.freedesktop.NativeMessagingProxy`, that runs outside
any sandbox, finds manifests in the standard Mozilla and Chromium locations, starts the
host, and hands the stdio file descriptors back to the browser. Firefox gained a client
for it in
[bug 1955255](https://bugzilla.mozilla.org/show_bug.cgi?id=1955255), fixed in Firefox
157. Zen 1.23.2b is built on it: `/usr/lib/zen-browser/platform.ini` reads
`Milestone=157.0.1`.

Ubuntu's Firefox snap enabled it in all channels on 2026-10-08 (Canonical's last comment
on that bug).
On the Flatpak side, Bazzite (`ublue-os/bazzite`,
`system_files/desktop/shared/usr/libexec/bazzite-flatpak-manager`) and Aurora
(`get-aurora-dev/common`) wire it up for `org.mozilla.firefox`, both checked
2026-10-14.

## Why it is deferred

- **Nothing in the image needs it.** The browser krytis ships is native, and the image
  ships no native-messaging manifests: none of `/usr/lib/mozilla/native-messaging-hosts`,
  `/usr/lib64/mozilla/native-messaging-hosts`, `/etc/chromium/native-messaging-hosts` or
  `/etc/opt/chrome/native-messaging-hosts` exists on image `26.08.202610131212`
  (`ls` on each, 2026-10-14).
- **Proton Pass, the one shipped app that writes a manifest, has no Linux host.** The
  desktop app writes `me.proton.pass.nm.json` to the Firefox, Chromium and Chrome
  user directories on every launch, on every OS
  (`applications/pass-desktop/src/lib/native-messaging/startup.ts` in
  ProtonMail/WebClients). On Linux the manifest's `path`,
  `/usr/lib/proton-pass/resources/assets/proton_pass_nm_host`, does not exist:
  `find /usr -name 'proton_pass_nm_host*'` returns nothing for 1.42.0. Upstream's
  `applications/pass-desktop/native/build.js` copies the host into `assets/` only on
  `darwin` and `win32`. The feature it serves, unlocking the extension with biometrics
  through the desktop app, is unimplemented on Linux too: `src/lib/biometrics/index.ts`
  falls through to `canCheckPresence: () => false`. All checked against WebClients
  `main` on 2026-10-14. A dangling `me.proton.pass.nm.json` in a home directory is
  normal and means nothing.
- **The service alone is inert.** No Flatpak can reach it without a per-app D-Bus grant,
  and Firefox does not try without a pref (both below). Shipping only the element is
  dead code.

## Revisit when

- krytis ships, recommends or preinstalls a Firefox-family browser as a Flatpak
  (`app.zen_browser.zen`, `org.mozilla.firefox`) **and** a user needs a host-side
  extension partner (KeePassXC, 1Password, Bitwarden desktop, ff2mpv); or
- Proton ships `proton_pass_nm_host` in its Linux package. Re-run the `find` above
  after a Proton Pass bump, then check the extension's `extension-preferences.json` in
  the Zen profile. `nativeMessaging` is an *optional* permission in the extension's
  manifest (1.41.1), so it must also be granted.

## What adding it takes

All three pieces are needed; any one alone does nothing.

1. **The service.** A new `kind: meson` element. Three C files; installs
   `libexecdir/xdg-native-messaging-proxy`, a D-Bus activation file and a systemd user
   unit, so nothing needs enabling.
   - Dependencies: glib and json-glib are already in the image (json-glib through the
     `components/json-glib.bst` → `gnome-build-meta.bst:sdk/json-glib.bst` override in
     `elements/freedesktop-sdk.bst`). libdex is not:
     `gnome-build-meta.bst:sdk/libdex.bst`, which also pulls `liburing` (already in
     the image) and `sdk/sysprof-minimal.bst`. No toolchain rebuild.
   - Size: Arch's `libdex` package is 1.0 MB installed, docs, headers and GIR included.
     The runtime `.so` files are a few hundred KB `[INFERENCE]`.
   - Upstream has one release, 0.1.0 (2025-03-26). Last push 2025-08-12 (as of
     2026-10-14). Use `kind: git_repo` with a tag `track:` glob and add the element to
     the `track-bst-sources.yml` matrix (AGENTS.md § Update path gate).
   - Upstream's `meson.build` always runs `subdir('tests')`, but that only looks up
     `tests/run-test.sh`; pytest is needed only if the test step runs `[INFERENCE]`.
2. **The D-Bus grant.** Each browser Flatpak needs
   `--talk-name=org.freedesktop.NativeMessagingProxy`; Zen's Flathub manifest does not
   request it. Set it with `flatpak override --system … <app-id>` from a boot-time
   oneshot, the way `files/bazaar/bazaar-host-etc.sh` sets Bazaar's `host-etc:ro`.
   Never symlink the override file into `/usr`; `docs/skills/bst.md` § Bazaar curated
   config and the host-etc permission explains the `EROFS` this causes.
3. **The pref.** `widget.use-xdg-desktop-portal.native-messaging-proxy` defaults to 0
   (never); 2 auto-detects. Under Flatpak, Gecko reads system prefs from
   `/app/etc/<app name>/defaults/pref/*.js` (`xpcom/io/SpecialSystemDirectory.cpp` in
   mozilla-firefox/firefox), and both Flatpaks mount a `*.systemconfig` extension there:
   `app.zen_browser.zen.systemconfig` → `/app/etc/zen`. Aurora's precedent copies a
   `.js` file into
   `/var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/<arch>/stable/defaults/pref/`.
   The same layout should work for Zen; untested.

## Security trade-off

This needs a Security Gate decision when it is picked up. The proxy's README is blunt:
any Flatpak granted the D-Bus name can launch **every** native-messaging host on the
host, without a prompt, and some hosts are sandbox escapes by design (GNOME Shell's
extension installer runs arbitrary code). Granting it makes the browser's sandbox only
as strong as the weakest host the user installs.

- Compared with today's native Zen: no regression. It is unsandboxed and launches the
  same hosts directly.
- Compared with a Flatpak Zen without the grant: it reopens what the sandbox closed.
- Mozilla's design doc
  (`toolkit/components/extensions/docs/native-messaging-portal-design.md`) requires that
  the confined browser cannot modify the manifests or the programs they name. Zen's
  Flatpak can write only to its persisted `.zen` directory and `xdg-download`, which
  satisfies that, provided no manifest points into `~/Downloads`.

## Verification, when built

- `busctl --user introspect org.freedesktop.NativeMessagingProxy /org/freedesktop/nativemessagingproxy`
  activates the service on demand. The object path is lowercase (`XNMP_OBJECT_PATH` in
  upstream's `src/xnmp-impl.h`).
- In the browser, `about:config` shows the pref at 2, and `MOZ_LOG=NativeMessagingProxy:5`
  logs the `GetManifest`/`Start` calls.
- End to end: a real host (KeePassXC-Browser with KeePassXC's "Browser Integration"
  enabled) connects from the Flatpak browser.
