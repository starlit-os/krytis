# xdg-desktop-portal-gtk4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace xdg-desktop-portal-gtk (GTK3) with a four-interface build of upstream
xdg-desktop-portal-gtk4 for Access, Notification, Inhibit and Email, under both niri and
Umbriel. Then remove xdg-desktop-portal-gtk from the image.

**Architecture:** There are two PRs. PR 1 adds `desktop/xdg-desktop-portal-gtk4.bst`, built
with `--no-default-features`, and a krytis-owned `gtk4.portal` that declares only the four
interfaces. It also moves every gtk-routed interface to `gtk4` in both sessions'
`/etc/xdg/xdg-desktop-portal/*-portals.conf`. After PR 1 no interface resolves to `gtk`, but
xdp-gtk stays installed so that rollback is a routing revert. PR 2 deletes xdp-gtk from
`stacks/desktop.bst` and from the `gtk3-audit` floor.

**Tech Stack:** BuildStream 2 `kind: manual` element with `git_repo` + `cargo2` sources (same
shape as `desktop/krytis-prompter.bst`), Rust 2024 / gtk4-rs 0.11 / zbus 5, xdg-desktop-portal
1.22 routing, mise tasks in bash + Python (Gio).

**Spec:** GitHub issue #181 (body and its 2026-11-03 and 2026-11-10 comments) and
[`docs/plans/2026-09-30-gtk3-realistic-floor.md`](2026-09-30-gtk3-realistic-floor.md) § Step 6.
Routing semantics: [`docs/skills/desktop.md`](../skills/desktop.md) § xdg-desktop-portal routing.

## Global Constraints

- Source: `github:JohnRTitor/xdg-desktop-portal-gtk4.git`, upstream directly with no fork, `track: v*`, excluding `*rc*`/`*alpha*`/`*beta*`. The first pin is `v1.6.0` (`894a5a2`), which contains the notification fix `560cecb`.
- Cargo features, exactly: `--no-default-features --features access,email,inhibit,notification,systemd`.
- Backend name `gtk4`, D-Bus name `org.freedesktop.impl.portal.desktop.gtk4`, binary `%{libexecdir}/xdg-desktop-portal-gtk4`.
- `gtk4.portal` declares exactly: `org.freedesktop.impl.portal.Access;org.freedesktop.impl.portal.Notification;org.freedesktop.impl.portal.Inhibit;org.freedesktop.impl.portal.Email;`.
- Umbriel routing: `default=umbriel;gnome;gtk4;` with `Access=gtk4;` and `Notification=gtk4;`. Inhibit and Email fall through to gtk4 via `default`. Every existing `none` and `Secret` pin is unchanged.
- niri routing (a delta over niri's upstream `default=gnome;gtk;`): add `Access=gtk4;`, `Notification=gtk4;`, `Inhibit=gtk4;` and `Email=gtk4;`. There's no `default=`, and existing pins are unchanged.
- FileChooser, Print, AppChooser, Account, DynamicLauncher, Settings, Lockdown and Usb stay on `gnome`. Clipboard stays `none`.
- `gdk4-x11` stays linked. The image's `libgtk-4.so.1` exports `gdk_x11_display_get_type` (checked 2026-11-10), so it builds. Feature-gating X11 is an optional upstream patch and out of scope.
- Update path: gate option (a). The element is added to the `track` matrix in `.github/workflows/track-bst-sources.yml` under `group: manual-merge`.
- Not in scope: Background (#1038). Secret (#1028) is unaffected.

## Review Focus

1. **Notification with buttons from a sandboxed app**: noctalia shows the buttons. Clicking a plain-named button emits portal `ActionInvoked`, with the action and target. Clicking an `app.`-prefixed one calls `org.freedesktop.Application.ActivateAction` on the app with the prefix stripped, and emits no signal (`src/portals/notification/dbus.rs:894–902` at v1.6.0). This is the bug PR #1 fixed, and a dependency bump could silently regress it. Task 3 asserts both paths on the wire; Task 4 checks them in a live session.
2. **Parentless Access request** (`parent_window = ""`): a dialog appears and the answer is returned. The request must not fail, the way xdp-gnome fails without `org.gnome.Shell`. Task 4 covers both sessions.
3. **Inhibit when `org.freedesktop.ScreenSaver` has no owner**, as in a headless run or a crashed noctalia: the backend answers and keeps its bus name. It must not abort, because the release profile is `panic = "abort"` and an abort would kill every portal it serves. Task 3 has a case for this.
4. **Upstream renames the D-Bus name or the binary** in a future tag: the build fails. It must not ship a `gtk4.portal` that points at nothing, which xdp only reports as a warning. Task 1's install step enforces this.
5. **Email with no `mailto:` handler installed**: `ComposeEmail` returns response `2` (other) promptly, so the calling app doesn't hang (`src/portals/email/dbus.rs:61–70`). Task 3 has a case for this, and it first proves that no handler resolves.

---

## PR 1 — add the backend and route to it

### Task 1: `desktop/xdg-desktop-portal-gtk4.bst`

**Files:**
- Create: `elements/desktop/xdg-desktop-portal-gtk4.bst`
- Modify: `elements/stacks/desktop.bst`, adding it next to `gnome-build-meta.bst:core-deps/xdg-desktop-portal-gnome.bst` (around line 56)
- Modify: `.github/workflows/track-bst-sources.yml`, adding a `track` matrix row after `desktop/krytis-prompter.bst` (around line 991)
- Modify: `docs/design/image-inventory.md`, using `mise run image-inventory --write` and then filling in the description
- Modify: `docs/skills/desktop.md` § xdg-desktop-portal routing, adding the descriptor lesson in Step 5 (same commit as the element)

**Interfaces:**
- Produces: `/usr/libexec/xdg-desktop-portal-gtk4`; `/usr/share/xdg-desktop-portal/portals/gtk4.portal` (four interfaces); `/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.gtk4.service`; `/usr/lib/systemd/user/xdg-desktop-portal-gtk4.service` (`Type=dbus`, no `[Install]`).

- [ ] **Step 1: Write the element.** Copy the layout of `desktop/krytis-prompter.bst`:
  - `build-depends`: `freedesktop-sdk.bst:components/rust.bst`, `freedesktop-sdk.bst:public-stacks/buildsystem-make.bst`, `freedesktop-sdk.bst:components/pkg-config.bst`.
  - `depends`: `freedesktop-sdk.bst:public-stacks/runtime-gnu.bst`, `gnome-build-meta.bst:sdk/gtk.bst`.
  - `cargo-home` variable, same as krytis-prompter.
  - `build-commands`: `export CARGO_HOME="%{cargo-home}"`, then `cargo build --release --locked --no-default-features --features access,email,inhibit,notification,systemd`. Without the export, cargo ignores the crates `cargo2` staged (as at `krytis-prompter.bst:52`).
  - `install-commands`, in order:
    1. Guard: `grep -qx 'Name=org.freedesktop.impl.portal.desktop.gtk4' data/org.freedesktop.impl.portal.desktop.gtk4.service.in`, and `grep -q '^NAME := xdg-desktop-portal-gtk4$' Makefile`. Either failing fails the build (Review Focus 4).
    2. `make install DESTDIR=%{install-root} PREFIX=%{prefix} LIBEXECDIR=%{libexecdir} DATADIR=%{datadir} SYSTEMD_USER_UNIT_DIR=%{indep-libdir}/systemd/user`. Upstream's `install` target has no `build` prerequisite, so it installs the binary that the feature-limited build produced.
    3. Overwrite `%{install-root}%{datadir}/xdg-desktop-portal/portals/gtk4.portal` with a heredoc: `[portal]`, `DBusName=org.freedesktop.impl.portal.desktop.gtk4`, and the `Interfaces=` line from Global Constraints. Upstream's file always declares all 13 interfaces, whatever features are compiled in.
    4. `%{install-extra}`.
  - Sources: the `git_repo` entry from Global Constraints, then `kind: cargo2`, `url: crates:crates`.
  - Header comment: what the element serves and why (#181), why the `.portal` file is replaced, and the update path. Explain that it is D-Bus activated, so the global user preset has nothing to enable (`docs/skills/bst.md` § User units fall through too).

- [ ] **Step 2: Generate the refs.** Run `mise run bst source track desktop/xdg-desktop-portal-gtk4.bst`.
  Expected: `ref: v1.6.0-0-g894a5a2…` and a populated `cargo2` `ref:` list. If Cargo.lock contains `kind: git` crates, add `git-mirrors` the same way `desktop/oo7.bst` does.

- [ ] **Step 3: Build the element.** Run `mise run bst build desktop/xdg-desktop-portal-gtk4.bst`.
  Expected: success, with no `bootstrap/*` or `components/llvm.bst`/`rust.bst` compiling. If either compiles, stop: the Toolchain Gate applies. If cargo reports that the toolchain is older than `rust-version = "1.92"`, stop and report it.

- [ ] **Step 4: Verify the artifact.** Check it out with `mise run bst artifact checkout desktop/xdg-desktop-portal-gtk4.bst --directory <scratch>/a`, then:
  - The set of `org.freedesktop.impl.portal.*` names on the `Interfaces=` line of `<scratch>/a/usr/share/xdg-desktop-portal/portals/gtk4.portal` **equals** the four in Global Constraints. Compare it with `tr ';' '\n' | sort` against a sorted expected list. A subset check is not enough: `portal-routing-check` only flags interfaces missing from its table (`portal-routing-check:253–258`), so an extra one that gnome already serves would slip through.
  - `ls <scratch>/a/usr/libexec/xdg-desktop-portal-gtk4` succeeds.
  - In the unit file and the D-Bus service file, `grep -r '@libexecdir@'` finds nothing.

- [ ] **Step 5: Wire it into the image.** Add the stack entry with a comment (`# Access/Notification/Inhibit/Email backend (#181)`), and add the track row (`group: manual-merge`, branch `auto/track-xdg-desktop-portal-gtk4`). Its comment says that every release needs `mise run gtk4-portal-smoke` (Task 3). Run `mise run image-inventory --write`, write the row's description, then run `mise run image-inventory --check`. In `docs/skills/desktop.md` § xdg-desktop-portal routing, add the descriptor lesson: *upstream xdg-desktop-portal-gtk4's `data/gtk4.portal` declares all 13 interfaces whatever cargo features are built, so a feature-limited build must ship its own `.portal`, or `default=` routes interfaces the binary doesn't export.* Also add `portals/gtk4.portal` (krytis-written, four interfaces) to the "Who ships what" table. Run `mise run docs-links`.
  Expected: `--check` and `docs-links` pass.

- [ ] **Step 6: Commit.** Run `env -u SSH_AUTH_SOCK git commit` in a pty. Message: `feat(portal): package xdg-desktop-portal-gtk4 v1.6.0`.

### Task 2: Route to gtk4 in both sessions

**Files:**
- Modify: `mise/tasks/portal-routing-check`, the `EXPECTED` table and `UMBRIEL_KRYTIS`
- Modify: `files/xdg-desktop-portal/niri-portals.conf`, `files/xdg-desktop-portal/umbriel-portals.conf`
- Modify: `elements/config/xdg-desktop-portal-routing.bst`, the header comment only
- Modify: `docs/skills/desktop.md` § xdg-desktop-portal routing, specifically the "Who ships what" table (around line 1800) and the per-interface rationale table (around line 1835)

**Interfaces:**
- Consumes: the `gtk4` backend and its `gtk4.portal` from Task 1.

- [ ] **Step 1: Write the expectation first.** In `EXPECTED`, set Access, Notification, Inhibit and Email to `"gtk4"` under both `niri` and `Umbriel`. Set `UMBRIEL_KRYTIS` to `"krytis umbriel-portals.conf default=umbriel;gnome;gtk4"`. Each reason names the pin, for example `("gtk4", "krytis pin: xdp-gnome needs org.gtk.Notifications (#181)")`. For niri Inhibit and Email the reason is `"krytis key: gnome.portal lacks it (#181)"`.

- [ ] **Step 2: Run the check against the image from Task 1.** Run `mise run build`. It loads the image and then stops at its `portal-routing-check` gate.
  Expected: FAIL. There are 8 `mismatch` lines (4 interfaces × 2 desktops), each showing `gtk`. Nothing else fails.

- [ ] **Step 3: Edit the routing files.** Follow Global Constraints. In `umbriel-portals.conf`, change `default=` and the two pins, and update their comments, which currently name xdp-gtk. In `niri-portals.conf`, add the four keys under a comment that explains that niri's upstream `Access=gtk`/`Notification=gtk` keys and its `default=gnome;gtk` would otherwise reach xdp-gtk. Rewrite the element header paragraphs that say "Access and Notification on gtk".

- [ ] **Step 4: Rebuild and rerun the check.** Run `mise run build` (this runs `portal-routing-check` as part of the gates).
  Expected: PASS, with no `redundant` lines.

- [ ] **Step 5: Update `desktop.md`.** In the per-interface rationale table, change the Notification/Access/Inhibit/Email rows from gtk to gtk4. Record any routing behaviour that Steps 2–4 turned up which the section doesn't already explain. Then run `mise run docs-links`.

- [ ] **Step 6: Commit.** Message: `feat(portal): route Access/Notification/Inhibit/Email to gtk4`, with `Refs #181`.

### Task 3: `mise run gtk4-portal-smoke`

**Files:**
- Create: `mise/tasks/gtk4-portal-smoke` (bash, with an inline Python/Gio helper), modelled on `mise/tasks/umbriel-portal-smoke`. Reuse its `podman run` environment, its `/dev/dri` SKIP, its headless umbriel startup and its `dbus-update-activation-environment WAYLAND_DISPLAY`.

**Interfaces:**
- Consumes: the image built in Task 2 (`--image`, default `localhost/krytis:latest`).
- Produces: exit code 0 on PASS. Each case prints `PASS <case>` or `FAIL <case>: <reason>`.

The task calls the **impl** interfaces on `org.freedesktop.impl.portal.desktop.gtk4` directly at `/org/freedesktop/portal/desktop`. The frontend isn't needed because Task 2's check already proves the routing, and calling directly avoids host-app identity rules. One long-lived Python Gio helper does three things:
- It owns fakes for `org.freedesktop.Notifications`, `org.freedesktop.ScreenSaver` (it can claim and drop this one on command), and an `org.freedesktop.Application` at bus name `org.example.Smoke`, path `/org/example/Smoke`.
- It records every call to a JSON log.
- It makes every impl call over **one connection that stays open** for the whole run. Inhibit cancels a request when its caller disconnects (`src/portals/inhibit/dbus.rs:232–237`), so `gdbus call` one-shots would cancel their own requests.

Impl input signatures at v1.6.0: `AddNotification` `ssa{sv}`, `Inhibit` `ossua{sv}`, `ComposeEmail` `ossa{sv}`, `AccessDialog` `osssssa{sv}`. `Inhibit` returns before its work runs (`dbus.rs:250` spawns, `:324` returns `Ok`), so every Inhibit assertion waits for an observable effect, polling with a 5 s ceiling. It never checks right after the reply.

- [ ] **Step 1: Write the cases.** Each case is a function in the task, which fails on the first unmet assertion:
  - **A `exports`**: `gdbus introspect` on the gtk4 name (bus activation must start it). The set of `org.freedesktop.impl.portal.*` interfaces it exports **equals** {Access, Notification, Inhibit, Email}.
  - **B1 `notification-signal`**: `AddNotification('org.example.Smoke', 'n1', {'title': <'T'>, 'body': <'B'>, 'buttons': <[{'label': <'Reply'>, 'action': <'reply'>, 'target': <'thread-7'>}]>})`. Assert that the fake recorded one `Notify` whose `actions` array contains the label `"Reply"`. Make the fake emit `ActionInvoked(<id>, <that key>)`, then assert that the backend emits portal `ActionInvoked('org.example.Smoke', 'n1', 'reply', ['thread-7', <platform-data>])`.
  - **B2 `notification-app-action`**: as B1, with id `'n2'`, action `'app.reply'` and `'default-action': <'app.open'>`. Assert that `Notify`'s `actions` contains a `"default"` key. Invoke the Reply key, then assert that the fake application recorded `ActivateAction('reply', [<'thread-7'>], <platform-data>)` and that **no** portal `ActionInvoked` was emitted within 1 s.
  - **C1 `inhibit-no-screensaver-at-start`**: the ScreenSaver fake is unclaimed from before the backend first activates. `Inhibit(<h1>, 'org.example.Smoke', '', 8, {})`. Wait 2 s, then claim the fake and call `Inhibit(<h2>, …, 8, {})`. Assert that the fake records `Inhibit` for h2, which proves the backend survived the failed path and still works. Also assert that the gtk4 name has had the same owner throughout (compare unique names).
  - **C2 `inhibit-screensaver-lost`**: with the fake claimed, `Inhibit(<h3>, …)`. Wait for the recorded `Inhibit`, drop the fake's name, then `Close` h3. Assert that the backend still has the same owner, and that after re-claiming, a new `Inhibit(<h4>, …)` is recorded.
  - **D `inhibit-screensaver`**: with the fake claimed, `Inhibit(<h5>, …, 8, {})`. Wait for the recorded `Inhibit` and take its returned cookie, then call `org.freedesktop.impl.portal.Request.Close` on h5. Wait for `UnInhibit(<that cookie>)`.
  - **E `email-no-handler`**: premise first. Under the backend's activation environment, `gio mime x-scheme-handler/mailto` must report no default and no registered application. If the image lists any, write `$HOME/.config/mimeapps.list` with a `[Removed Associations]` line for those desktop IDs before the backend starts, and re-assert. Then `ComposeEmail(<h6>, 'org.example.Smoke', '', {'addresses': <['a@example.org']>})` must return response code `2` within 5 s.

- [ ] **Step 2: Run it against the pre-Task-1 image to see it fail.** Run `mise run gtk4-portal-smoke --image <an image built from origin/main>`.
  Expected: FAIL `exports`, because nothing owns the gtk4 name.

- [ ] **Step 3: Run it against the Task 2 image.** Run `mise run gtk4-portal-smoke`.
  Expected: seven `PASS` lines (A, B1, B2, C1, C2, D, E) and exit 0. If a C case shows a new owner for the gtk4 name, the backend aborted (`panic = "abort"`). That is an upstream bug: report it and don't work around it.

- [ ] **Step 4: Commit.** Message: `test(portal): add gtk4-portal-smoke`. Include the `desktop.md` routing section's pointer to the task.

### Task 4: Booted verification under both sessions, then open PR 1

This task ticks #181's checklist items 1 and 2 (routing log, parentless Access) against the new backend.

- [ ] **Step 1: Boot-test.** Run `mise run generate-disk` and then `mise run boot-test`, in a pty for the sudo prompts.
  Expected: PASS.

- [ ] **Step 2: Live checks.** In the VM, log in once under niri and once under Umbriel. Record the output of each item in the PR body.
  - `/usr/libexec/xdg-desktop-portal --replace --verbose 2>&1 | grep 'Using .*portal for'`: the four interfaces are on `gtk4.portal`, and nothing is on `gtk.portal`.
  - Notification: send through the **frontend** `org.freedesktop.portal.Notification.AddNotification` two buttons, one with action `reply` and one with `app.reply`. noctalia shows both. Clicking `reply` produces frontend `ActionInvoked` (`dbus-monitor --session "member='ActionInvoked'"`). Clicking `app.reply` produces `ActivateAction` on the app (`dbus-monitor --session "member='ActivateAction'"`) and no `ActionInvoked`. Then repeat once with a real Flatpak app that uses notification buttons.
  - Parentless Access: `gdbus call` on the impl `org.freedesktop.impl.portal.Access.AccessDialog` with `parent_window ''`. A GTK4 dialog appears, and Allow returns response `0`.
  - Inhibit: play a video in a Flatpak browser for longer than the idle timeout. The screen stays on, and `busctl --user status org.freedesktop.ScreenSaver` names the owner (niri under niri, noctalia under Umbriel; the latter has only been confirmed from source).
  - FileChooser and Print still open xdp-gnome dialogs, so there's no regression from Task 2.

- [ ] **Step 3: Write the skill entry back.** Write every non-obvious finding from Steps 1–2 into `docs/skills/desktop.md` in the same commit as any fix it caused. Tick #181's checklist items 1–2 in the issue body. Edit the `docs/plans/2026-09-30-gtk3-realistic-floor.md` Step 6 table row from "candidate" to "adopted (PR 1)".

- [ ] **Step 4: Open PR 1** titled `feat(portal): adopt xdg-desktop-portal-gtk4`, with body `Refs #181` and the evidence from Steps 1–2. Merging is a human decision (Design Gate and Merge Gate).

## PR 2 — remove xdg-desktop-portal-gtk

Start this only after PR 1 has merged and run on a daily-driven machine for a while.

### Task 5: Drop xdp-gtk from the image

**Files:**
- Modify: `elements/stacks/desktop.bst:55`, removing `gnome-build-meta.bst:core-deps/xdg-desktop-portal-gtk.bst`
- Modify: `mise/tasks/gtk3-audit`, deleting the `ELEMENTS` row for `core-deps/xdg-desktop-portal-gtk.bst` and the `FILES` row for `/usr/libexec/xdg-desktop-portal-gtk`, and changing the "or #181 replaces xdg-desktop-portal-gtk" sentence in the removal-tags comment
- Modify: `mise/tasks/portal-routing-check`, changing any reason string that still says `gtk`
- Modify: `docs/skills/desktop.md`, removing `portals/gtk.portal` from the "Who ships what" row
- Move: `docs/plans/2026-11-10-xdg-desktop-portal-gtk4.md` → `docs/plans/done/`; update Step 6 of the GTK3-floor plan

- [ ] **Step 1: Delete the expectation first.** Remove the two `gtk3-audit` rows. Then run `mise run gtk3-audit` against the current image.
  Expected: FAIL, reporting `xdg-desktop-portal-gtk.bst` and `/usr/libexec/xdg-desktop-portal-gtk` as unclassified GTK3 consumers.

- [ ] **Step 2: Remove the stack entry and rebuild.** Delete the line from `stacks/desktop.bst` and run `mise run build`.
  Expected: all gates pass, including `portal-routing-check`. Its routing is unchanged, because PR 1 already sends nothing to `gtk`.

- [ ] **Step 3: Rerun the audits.** Run `mise run gtk3-audit` and `mise run gtk4-portal-smoke`.
  Expected: both PASS. `podman run --rm --entrypoint ls localhost/krytis:latest /usr/share/xdg-desktop-portal/portals` doesn't list `gtk.portal`.

- [ ] **Step 4: Boot-test, then a one-pass repeat of Task 4 Step 2 under both sessions.**
  Expected: same results as PR 1.

- [ ] **Step 5: Commit and open PR 2.** Message: `feat(portal): drop xdg-desktop-portal-gtk`, with `Closes #181`. Archive this plan in the same PR.
