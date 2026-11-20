# credentialsd (WebAuthn / passkeys) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship [linux-credentials/credentialsd](https://github.com/linux-credentials/credentialsd)
so that apps and browsers in a krytis session can use FIDO2 security keys (USB, NFC) and
phone passkeys (CTAP2 hybrid over BLE) through the xdg-desktop-portal **Credential**
portal.

**Architecture:** Three new elements and one replaced component. libnfc (new C library),
credentialsd (Rust daemon + GTK4 UI, systemd user services, D-Bus activated), and an
xdg-desktop-portal built from the first upstream release that contains the Credential
portal, replacing freedesktop-sdk's 1.22.1 through a junction override. A user-unit
drop-in enables the experimental portal, and a routing key sends
`org.freedesktop.impl.portal.experimental.Credential` to credentialsd in both sessions.
Browser integration is a separate, later phase (§ Phase 3).

**Tech Stack:** BuildStream 2 `kind: meson` + `cargo2` (same shape as `desktop/oo7.bst`,
`desktop/krytis-prompter.bst`), freedesktop-sdk 26.08.4 Rust 1.99.1, gnome-build-meta
`core-deps/libdex.bst` 1.2.0.

**Spec:** #1573 (body and comments). This plan answers the issue's evaluation questions in
§ Evaluation; the go/no-go is the owner's, at the gates below.

## Status and gates

Nothing here can land until the owner signs off at:

- **Security Gate:** a new D-Bus service handling authentication credentials and typed
  PINs; credentialsd's trust model (below); ~480-crate Cargo graph.
- **Design Gate:** a new subsystem with user-visible prompts.
- **Breakage Gate:** Task 2 replaces xdg-desktop-portal, which is on the session path for
  every Flatpak and both sessions.

**Hard blocker (as of 2026-11-20):** no xdg-desktop-portal *release* contains the
Credential portal. It merged to `main` as
[flatpak/xdg-desktop-portal#1889](https://github.com/flatpak/xdg-desktop-portal/pull/1889)
on 2026-11-06 (`987607a`). The newest tag is 1.22.1 (2026-06-17), and `main`'s
`meson.build` says `version: '23.0'`. Task 2 starts at the first tag that contains
`987607a`. Pinning an untagged `main` of a session-critical component isn't acceptable.

**Soft blocker:** credentialsd 0.4.0 (2026-11-05) predates the upstream merge. Since then,
credentialsd `main` (37 commits past `v0.4.0` at `829f52e`, 2026-11-20) has followed
upstream's final shape: the `ui_backend` option (#273) and the activation token
(xdg-desktop-portal#2209 ↔ credentialsd #262). Pin the first credentialsd release
after 0.4.0, and confirm it against the xdg-desktop-portal tag in Task 5 before trusting it.

## Evaluation (answers to #1573's questions, checked 2026-11-20)

1. **Maturity.** Still 0.x and pre-release on GitHub, and the portal interface is
   `…experimental.Credential`. Upstream's experimental-portal rules
   (`doc/experimental-portals.rst`) allow breaking changes at any time, signalled by a numeric
   suffix on the interface name. Expect at least one more breaking change before the portal
   goes stable. It's usable for opt-in testing, not as something users rely on.
2. **The patched-portal question has gone away.** We don't need the
   linux-credentials fork (`credentials-portal` branch, last commit 2026-07-14). Upstream
   merged the frontend, the `impl` (UI backend) and the new `handler` interface. We'd ship an
   *unpatched* upstream release, so there's no row in `carried-patches.md`. The remaining
   cost is replacing freedesktop-sdk's portal (Task 2) until freedesktop-sdk itself ships 23.x.
   Its 26.08 branch probably won't, because 23.0 adds new hard dependencies (libdex ≥ 1.2,
   wireplumber, pipewire ≥ 1.3.81, glib ≥ 2.88). All four are already on the image:
   gbm `core-deps/libdex.bst` 1.2.0, wireplumber 0.5.18, pipewire 1.6.8, glib 2.90.1.
3. **Update path and toolchain.** freedesktop-sdk 26.08.4 ships Rust **1.99.1**
   (`include/rust-source.yml`), above credentialsd's `rust-toolchain.toml` pin of 1.97.1.
   BuildStream's cargo ignores `rust-toolchain.toml` anyway. Update path gate (a) for all three
   elements: `git_repo` + release-tag `track:`, plus `cargo2` crates regenerated on
   each bump the way `desktop/oo7.bst` does it.
4. **UI.** Ship upstream `credentialsd-ui` first. It's a separate D-Bus-activated process
   (`xyz.iinuwa.credentialsd.UiControl`), which xdg-desktop-portal now chooses through
   `credentialsd.portal`. That's the same seam a krytis-native prompt (sharing style or code
   with `desktop/krytis-prompter.bst`) would plug into later, without touching the daemon.
   That's a follow-up issue, not this plan.
5. **Web extension.** Don't ship it in Phase 1 (`-Dfeature_web_extension=disabled`). It
   needs a Python `dbus-next` native host and is allowlisted to demo sites. Browser
   integration is § Phase 3.

Other facts the tasks depend on:

- **libnfc is a hard dependency.** credentialsd enables libwebauthn's
  `nfc-backend-libnfc` and `nfc-backend-pcsc` unconditionally (`credentialsd/Cargo.toml`).
  `nfc1` is pulled with `default-features = false`, so `nfc1-sys` is built **without**
  `vendored` (`cargo tree -e features -i nfc1-sys` lists no `nfc1-sys` feature). It links
  the system libnfc through pkg-config and runs `bindgen` against its headers. Neither
  freedesktop-sdk nor gnome-build-meta packages libnfc. Upstream
  [nfc-tools/libnfc](https://github.com/nfc-tools/libnfc) is quiet: its last tag is
  `libnfc-1.8.0` (2020), and `master`'s last commit is 2025-03-05.
- **pcscd is already on the image** (`pcscd.socket` enabled, `components/pcsc-lite.bst`
  2.5.3), so the PC/SC NFC path needs nothing new. The #1573 body's "pcscd that krytis
  doesn't ship today" is out of date.
- **hidapi** is built `linux-static-hidraw` (needs libudev ✓). **btleplug** talks to BlueZ
  over D-Bus (bluez is on the image ✓).
- **The experimental flag is case-sensitive.** xdg-desktop-portal checks
  `g_hash_table_contains (…, "Credential")` (`desktop-portal/xdp-context.c:642` at `3152e60`),
  so the variable must be `XDG_DESKTOP_PORTAL_ENABLE_EXPERIMENTAL=Credential`. credentialsd's
  own `BUILDING.md` says `=credential`, which would silently enable nothing.
- **The handler's D-Bus name is hard-coded** in the portal: `CREDENTIALSD_HANDLER_DBUS_NAME
  "xyz.iinuwa.credentialsd.Credentials"` (`desktop-portal/credential.c:119`). Only the UI
  backend is chosen through `.portal` routing.
- **Trust model.** The daemon accepts requests only from a caller whose executable is
  `/usr/libexec/xdg-desktop-portal` (or the `/usr/local` one) **and** whose pidfd is in
  `xdg-desktop-portal.service` (`credentialsd/src/gateway/mod.rs:281-313`). Callers that may
  assert any origin ("privileged", i.e. browsers) are a hard-coded app-ID list:
  `org.mozilla.firefox`, `firefox`, `firefox-developer-edition`, `firefox-esr` and the demo
  client (`mod.rs:369-376`). Every other app is unprivileged and its origin is verified.
  The `CREDSD_TRUSTED_*` overrides only exist with `-Denable_trusted_client_overrides=true`,
  which we must **not** set.

## Global constraints

- **credentialsd meson options, exactly:** `-Dprofile=release -Dcargo_offline=true
  -Dcargo_locked=true -Dfeature_daemon=enabled -Dfeature_gui=enabled
  -Dfeature_web_extension=disabled -Dfeature_demo_client=disabled
  -Denable_trusted_client_overrides=false -Denable_core_dumps=false`.
  `cargo_home` points at the `cargo2` vendor dir.
- **No forks, no patches.** If a task seems to need one, stop and ask (it becomes a carry
  with a row in `docs/design/carried-patches.md` and `upstream-ai-policies.md`).
- **Routing:** an explicit `org.freedesktop.impl.portal.experimental.Credential=credentialsd;`
  key in krytis's Umbriel and niri `/etc/xdg/xdg-desktop-portal/*-portals.conf`. Every
  existing key stays unchanged. Don't rely on `default=` fallthrough: no listed backend
  implements the interface, so lookup would fall to the next file
  (`docs/skills/desktop.md` § xdg-desktop-portal routing).
- **Opt-out must stay cheap:** removing the drop-in from Task 4 turns the whole feature off
  without a rebuild of anything else. Document that in the design doc.

## Phase 1: the service, opt-in testers only

### Task 1: `desktop/libnfc.bst`

**Files:** `elements/desktop/libnfc.bst`, `.github/workflows/track-bst-sources.yml`,
`docs/design/image-inventory.md` (runtime-dep row via `mise run image-inventory --write`).

- [ ] `kind: cmake` (upstream ships CMake and autotools; CMake is the maintained one),
  source `github:nfc-tools/libnfc.git`, `track: libnfc-*`, first pin `libnfc-1.8.0`.
- [ ] Depends: `components/libusb.bst`. Build only the library: no examples, no utils, no
  `nfc-*` binaries on the image. Check the CMake option names at the pinned tag.
- [ ] Ship the default driver set only. Every `nfc1-sys` default driver is a USB or serial
  reader, and PC/SC readers go through pcscd instead.
- [ ] Add the `track` matrix row (update path gate (a)).
- [ ] `mise run bst --pull build desktop/libnfc.bst`.

### Task 2: xdg-desktop-portal 23.x override (Breakage Gate)

**Files:** `elements/core/xdg-desktop-portal.bst`, `elements/freedesktop-sdk.bst` (override
entry), `.github/workflows/track-bst-sources.yml`, `docs/design/image-inventory.md`
(replacement row).

- [ ] Start only once a tag containing `987607a` exists (`git tag --contains 987607a` in a
  clone of flatpak/xdg-desktop-portal).
- [ ] Mirror freedesktop-sdk's `components/_private/xdg-desktop-portal-base.bst` and
  `components/xdg-desktop-portal.bst` at the 26.08.4 pin (meson options, split rules,
  the `flatpak-interfaces` and `systemd` options) into `core/xdg-desktop-portal.bst`. Change
  only the source (`github:flatpak/xdg-desktop-portal.git`, `track:` the 23.x tag series) and
  add `gnome-build-meta.bst:core-deps/libdex.bst` plus `components/wireplumber.bst` to the
  build-depends.
- [ ] Override in `elements/freedesktop-sdk.bst` beside `components/openssh.bst: core/openssh.bst`.
  Decide whether the override target is `components/xdg-desktop-portal.bst` or the
  `_private` base, by checking which one the stacks that pull it reference
  (`mise run bst show --deps all stacks/desktop.bst | grep xdg-desktop-portal`).
- [ ] Gates: `mise run build --pull` (portal-routing-check must still pass, unchanged
  routing), `mise run boot-test`.
- [ ] Regression check in **both** sessions on hardware: a Flatpak file-chooser (xdp-gnome),
  screenshot and screencast (umbriel backend), Settings (dark-style follows), and the
  camera. 23.0 moved the camera to wireplumber. Write the results into the PR.
- [ ] This can merge **alone**, before credentialsd. It's useful on its own and leaves the
  rest of the stack (Tasks 3–5) as additive.

### Task 3: `desktop/credentialsd.bst`

**Files:** `elements/desktop/credentialsd.bst`, `elements/stacks/desktop.bst`,
`.github/workflows/track-bst-sources.yml`, `docs/design/image-inventory.md`.

- [ ] `kind: meson`, source `github:linux-credentials/credentialsd.git`, `track: v*`, first pin
  the first release after `v0.4.0` (see soft blocker). `cargo2` sources from its
  `Cargo.lock`, following `desktop/oo7.bst`'s regeneration step.
- [ ] Depends: `components/gtk4.bst` (via gnome-build-meta), `components/libdbus.bst`,
  `components/openssl.bst`, `components/pcsc-lite.bst`, `components/systemd-libs.bst`
  (libudev), `desktop/libnfc.bst`; build-depends add `components/rust.bst`, `components/llvm.bst`
  (libclang for `bindgen`), `components/gettext.bst`.
- [ ] Meson options per § Global constraints.
- [ ] Verify the install: `credentialsd` and `credentialsd-ui` in `%{libexecdir}`, both
  `xyz.iinuwa.credentialsd.*.service` in `%{datadir}/dbus-1/services` **and** the systemd user
  units, and `credentialsd.portal` in `%{datadir}/xdg-desktop-portal/portals/`.
- [ ] Add a `strings`/`objdump` check that the shipped daemon doesn't contain
  `CREDSD_TRUSTED_CALLERS` handling, i.e. the overrides feature is off (`cargo` feature
  `trusted-client-overrides` absent).

### Task 4: enable and route the portal

**Files:** `elements/config/credentialsd-portal.bst` (new), `elements/config/xdg-desktop-portal-routing.bst`,
`mise/tasks/portal-routing-check` (expectations).

- [ ] Ship `%{indep-libdir}/systemd/user/xdg-desktop-portal.service.d/50-krytis-credential.conf`:
  `[Service]` / `Environment=XDG_DESKTOP_PORTAL_ENABLE_EXPERIMENTAL=Credential` (capital
  C, see § Evaluation).
- [ ] Add the `org.freedesktop.impl.portal.experimental.Credential=credentialsd;` key to both
  sessions' routing.
- [ ] Teach `portal-routing-check` the new interface and expected backend, so a routing
  regression fails the build like every other interface.
- [ ] Decide with the owner (Design Gate): is the drop-in **on by default**, or shipped
  disabled for testers to enable with `systemctl --user edit`? This plan's default is
  *on for everyone*, because it does nothing until an app calls the portal.

### Task 5: verification

**Files:** `mise/tasks/credentialsd-test` (new), `docs/skills/desktop.md`.

- [ ] `credentialsd-test`, run inside a booted image (boot-test SSH or a local session):
  1. `busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop`
     lists `org.freedesktop.portal.experimental.Credential`.
  2. `busctl --user status xyz.iinuwa.credentialsd.Credentials` activates the daemon.
  3. The portal journal has `Enabling experimental Credential portal`.
- [ ] Hook step 1 into `boot-test`'s health assertions (no hardware key needed).
- [ ] Hardware, on adora: register and authenticate on <https://webauthn.io> with a USB
  security key **while** FIDO2 LUKS and `pam-u2f` are enrolled on the same key, and confirm
  both still work (the #1573 "fighting over hidraw" question). Then repeat with NFC through
  a PC/SC reader if one is available, and with a phone over hybrid (BLE). Without the
  extension or a patched browser, the client for this test is upstream's demo client, built
  locally from the same tag (not shipped).
- [ ] Record the results in the design doc.

### Task 6: docs

- [ ] a new design doc, `webauthn-credentials.md` in the design directory: the decision, the trust model, the opt-out,
  the experimental-interface risk, and the re-check triggers (portal goes stable, a stock
  browser ships support, credentialsd 1.0).
- [ ] `docs/skills/desktop.md`: experimental portals (the case-sensitive flag, the
  hard-coded handler name, routing an `experimental.*` interface).
- [ ] Close #1573 when Phase 1 merges. Open follow-ups for Phase 2 and Phase 3.

## Phase 2: krytis-native prompt (follow-up issue)

Replace `credentialsd-ui` with a `UiControl`/`impl.portal.experimental.Credential` backend
styled like krytis-prompter (gtk4-layer-shell, noctalia look). Only the `.portal` file and
routing change; the daemon is untouched. Wait until the UI controller API settles: it
broke in 0.4.0 and again on `main`.

## Phase 3: browser integration (Zen)

Without a client, Phase 1 only serves the demo client. The browser on the image is Zen
(`desktop/zen-browser.bst`), shipped as upstream's **prebuilt tarball**, 1.24.3b on
Firefox 160.0.1 (as of 2026-11-20).

### Can we ship credentialsd's Firefox patches in our Zen? Feasible, not worth it now.

- **The patches.** credentialsd's patched Firefox is OBS
  `home:MSirringhaus:webauthn_devel/MozillaFirefox`, 159.0.1 linked to `mozilla:Factory`. It carries two
  patches for [Mozilla bug 1983767](https://bugzilla.mozilla.org/show_bug.cgi?id=1983767),
  which was REOPENED as of 2026-11-20:
  - **Part 1 (topOrigin in `nsIWebAuthnArgs`, D333210) has landed** and is in Firefox 160. Zen
    already has it.
  - **The main patch, D261536 (`webauthn_xdg_portal.patch`, ~65 KB, ~1,300 added lines), is "Needs
    Revision"** and now depends on bug 2088324. It adds `dom/webauthn/XdgPortalWebAuthnService.{cpp,h}`,
    a new Rust crate, and `widget/gtk` window-handle export plumbing. It also adds the pref
    `security.webauthn.use-xdg-desktop-portal`.
- **It applies to Zen's base.** A `patch --dry-run` of the main patch against Firefox
  160.0.1 applied every hunk (offsets, plus fuzz 1 on `dom/webauthn/moz.build`). That's not a
  compile test. Zen's own 283 patches don't touch `dom/webauthn`.
- **But nothing can turn it on at runtime.** The backend has to be compiled in, so shipping it means
  **building Zen from source** in BuildStream instead of repackaging the tarball. That needs:
  - Firefox's build with an offline toolchain. `mach bootstrap` and Zen's npm `surfer`
    tooling fetch from the network, which the sandbox forbids.
  - Zen's release flags: cross-LTO, two-stage PGO, Rust 1.95, Node 22.
  - An estimated 1–3 h and ~16–32 GB RAM per build. This is an estimate, not measured.
  - A rebuild on Zen's **weekly** releases, plus a rebase of an unmerged ~1,300-line patch on every
    4-weekly Firefox bump.
  - A new update path replacing `mise run zen-browser-update`, and a `carried-patches.md` row.

  That's a large permanent cost for a feature still behind an experimental interface.
- **Upstream routes (Upstream Gate: the owner's call, nothing to file unprompted).**
  1. D261536 lands in Firefox, and Zen inherits it at its next rebase.
  2. Zen imports it early through its own `src/external-patches/manifest.json`, which supports
     `"type": "phabricator"` entries. That's Zen's decision to make. No Zen issue mentions credentialsd as of
     2026-11-20.

### Recommended: the web extension, system-wide in Zen (separate PR, after Phase 1)

- The README still says the extension is allowlisted to demo sites. That's out of date: upstream commit
  `5fa1cb5` (2026-08-21) runs its content scripts on `<all_urls>`. The v0.4.0 release
  XPI (`credentialsd-helper@iinuwa.xyz`) is Mozilla-signed, which matters because Zen keeps
  `xpinstall.signatures.required`.
- Install with no browser rebuild:
  - Force-install the XPI through `ExtensionSettings` (`installation_mode: force_installed`,
    `file://` `install_url`) in the `distribution/policies.json` that `desktop/zen-browser.bst`
    already writes.
  - Put the native-messaging manifest in `/usr/lib/mozilla/native-messaging-hosts/`. Zen reading
    the system `mozilla` directory is inferred from issue #10622, not tested.
  - Package the shim's Python `dbus-next` as a new element.
- That means enabling `-Dfeature_web_extension=enabled` in `desktop/credentialsd.bst` (Task 3) or using
  the release XPI. Decide by whether the build output is signed. An unsigned self-built XPI won't
  load in Zen.

### Zen isn't a privileged client, whichever route we take

credentialsd's hard-coded privileged list (§ Evaluation, Trust model) has no Zen app ID.
Zen therefore gets same-origin WebAuthn only: a cross-origin iframe can't pass a top origin.
Two ways to fix it:

- A one-line credentialsd change upstream (Upstream Gate).
- A carried patch adding Zen's app ID (Security Gate, plus a `carried-patches.md` row).

**First measure which app ID xdg-desktop-portal actually assigns Zen** on krytis (a host
app, so it comes from the systemd scope or desktop file: expect `zen-browser` from
`zen-browser.desktop`) before proposing either.

### Phase 3 tasks

- [ ] Measure Zen's portal app ID under Umbriel and niri.
- [ ] Owner decision: credentialsd upstream change vs. carry vs. accept unprivileged.
- [ ] `desktop/python-dbus-next.bst` (update path gate (a)).
- [ ] XPI + native-messaging manifest + `policies.json` `ExtensionSettings` entry.
- [ ] Hardware: register and sign in on webauthn.io and on a real site (GitHub passkeys) in Zen.
- [ ] Re-check trigger for the native route: D261536 landing in mozilla-central. Then Zen's
  next Firefox rebase brings it with no work here, and the extension can be dropped.
