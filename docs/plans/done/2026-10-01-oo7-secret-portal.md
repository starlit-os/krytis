# Ship the oo7 Secret portal backend

**Issue:** #1028 · **Branch:** `1028-ship-oo7-secret-portal-backend` · **Worktree:**
`krytis.worktrees/fix/gh1028-ship-oo7-secret-portal-backend` · **Status: blocked on the
Security Gate.** This is secrets handling (AGENTS.md § Human Decision Points). Step 1 is a
measurement that informs the decision. Nothing ships until a human answers § Decisions.

**Depends on** [#1027's plan](done/2026-10-01-niri-portal-routing-cleanup.md) step 1
(`mise run portal-routing-check`) and its *Verified facts*: xdp falls through config files per
interface, which is what makes a one-key niri delta work. It does not depend on
[#1029](2026-10-01-umbriel-portal-routing.md). Whichever of #1028 and #1029 lands first
creates `config/xdg-desktop-portal-routing.bst` as that plan's step 1 describes.

## Facts (oo7 pinned at `bf367dca`, 2026-09-28)

**What upstream builds.** `portal/` is its own meson project in the same cargo workspace:

| Installed | Path |
|---|---|
| `oo7-portal` | `libexecdir` (cargo `custom_target`) |
| `oo7-portal.portal` | `datadir/xdg-desktop-portal/portals/`: `DBusName=org.freedesktop.impl.portal.desktop.oo7`, `Interfaces=org.freedesktop.impl.portal.Secret;`, `UseIn=gnome` |
| `org.freedesktop.impl.portal.desktop.oo7.service` | `dbus_service_dir`: `Exec=/bin/false`, `SystemdService=dbus-org.freedesktop.impl.portal.desktop.oo7.service` |
| `oo7-portal.service` + `dbus-….service` symlink | `systemduserunitdir`: `Type=dbus`, `Requisite=`/`PartOf=graphical-session.target` |
| `oo7-portal.desktop` | `datadir/applications`, `NoDisplay=true` |

- The meson options (`dbus_service_dir`, `systemd`, `systemduserunitdir`, `profile`) and the
  `meson_version: '>= 1.7'` requirement are the same as `server/`'s.
- **No new sources.** The element's `cargo2` list matches the workspace `Cargo.lock`'s
  registry packages exactly. Checked: the set of `name version` pairs from every
  `source = "registry…"` lock entry equals the set from the element's `name:`/`version:`
  pairs. The lock covers every workspace member, `portal` included, and ashpd 0.13.13 with
  `backend`/`secret`/`tracing` resolves within it.
- **Build cost.** The cargo `custom_target` builds with `--target-dir <builddir>/src`, so
  `portal/` compiles the dependency graph a third time (`server/` and `pam/` each already do
  so). Step 3 measures it.
- **Routing name.** Routing values match the `.portal` file's basename, so the value is
  `oo7-portal`. niri `main`'s line uses the same value. `UseIn=gnome` doesn't matter here:
  xdp only consults `UseIn` when no portals.conf resolves the interface, and both sessions
  have a portals.conf.
- **Both sessions satisfy `Requisite=graphical-session.target`.** `niri.service` has
  `BindsTo=` it, and `umbriel-session.target` has `BindsTo=` it (unit files read from the
  image).
- **niri's fix is unreleased.** niri `02fdd8e758` ("portals: add oo7 as secret portal",
  2026-09-15) changes `Secret` to `oo7-portal;gnome-keyring;`. The newest release is still
  `v26.04` (2026-04-25), which says `gnome-keyring`.

**What the backend does** (`portal/src/main.rs`, 172 lines). For each
`RetrieveSecret(handle, app_id, fd)` call:

1. It rejects an empty `app_id`, so host apps get `InvalidArgument`.
2. `Service::new()` → `default_collection()`. If the collection is locked, it calls
   `unlock(None)`, which prompts through the session prompter (noctalia's `SystemPrompter`)
   with no parent window.
3. It runs `search_items([("app_id", id)])`. If an item is found, it writes that item's
   secret to `fd`.
4. Otherwise it generates `oo7::Secret::random()`, calls
   `create_item("Secret Portal token for <id>", attrs, secret, replace=true)`, and writes the
   new secret.

Inside the sandbox, libsecret's file backend uses that secret as the key for the app's own
encrypted keyring file. [INFERENCE: the file is `$XDG_DATA_HOME/keyrings/default.keyring`,
i.e. `~/.var/app/<id>/data/keyrings/` under Flatpak. Confirm in step 5.]

## Risks the Security Gate must weigh

**R1 — the portal can silently mint a new master key, which loses the app's data.** The token
is the only key to the app's sandboxed keyring file. If step 3 ever comes back empty for an
app that already has a token, step 4 makes a fresh one, and everything the app stored before
becomes undecryptable. No error appears anywhere. There are two ways to get an empty result:

- **R1a — the `default` alias is unresolved.** `default_collection()` is
  `with_alias_or_create("default", "Default")` (`client/src/dbus/service.rs:149–174`).
  `docs/skills/pam.md` § oo7 `default` alias requires an unlocked collection says the daemon
  only loads aliases for unlocked collections. The same file then records a contradicting
  data point for a collection created locked, and leaves the *discovered-from-disk* case
  explicitly untested. If the alias is unresolved while Login is locked, the portal
  **creates a second collection called "Default" and gives it the `default` alias**, which
  prompts for a new password. After that, every token lookup goes to the new collection, and
  so does every host libsecret write that targets `default`. Login still holds the original
  token, but nothing looks there.
- **R1b — #585.** A locked collection's `SearchItems` returns empty. The portal unlocks first,
  so this needs the collection to re-lock between `unlock` and `search_items`. That is a
  narrow window, but a mid-session `oo7-daemon` restart or crash re-locks Login
  (`docs/design/secrets-service.md` § Current decision, "residual risk").

On krytis today, Login can be locked mid-session after an `oo7-daemon` restart or crash, or
after an autologin with no credential. The live ISO covers that case with #911's credential.
FIDO2 login would also leave it locked, but it is disabled.

**R2 — token visibility.** Tokens are ordinary items in Login. Any unconfined host process,
and any Flatpak with `--talk-name=org.freedesktop.secrets`, can read every app's token. This
is inherent to the portal design, not specific to oo7.

**R3 — prompt attribution.** If Login is locked, an app's first portal use raises a noctalia
unlock prompt that comes from oo7-portal (`unlock(None)`, no window id), not from the app.

## Decisions (Security Gate)

| # | Question | Options | Recommendation |
|---|---|---|---|
| D1 | Ship oo7-portal at all? | yes / no. If no, sandboxed libsecret users keep getting no backend; close #1028 | yes, if D2 is (b) or step 1 shows R1a doesn't occur |
| D2 | R1a handling | **(a)** ship upstream as is and accept R1a like #585, documented and gated; **(b)** carry `patches/oo7/portal-never-create-default.patch`: look up `default` with `with_alias()`, fail the request on `None`, and fail instead of minting if the collection still reports locked after `unlock` | **(b)**. It turns silent data loss into a failed request the app can retry. Upstream-able, but proposing it to `linux-credentials/oo7` is an **Upstream Gate** call |
| D3 | Route Secret in which sessions? | both / niri only | both |

## Step 1 — `mise run oo7-portal-test` (measure, then keep as a gate)

Lands in the implementation PR and runs before D2 is answered. Its result on unpatched
upstream decides between D2 (a) and (b).

Follow `mise/tasks/oo7-login-race-test`: check out the `desktop/oo7.bst` artifact (with
`--artifact <dir>` to reuse one), run on a private `dbus-run-session` with its own
`XDG_DATA_HOME` and `OO7_PAM_SOCKET`, and refuse to run if the real rendezvous socket exists.
Unlock Login at daemon start through the login-helper path that test already drives.

Drive the **impl** interface directly, because it takes `app_id` as an argument:
`busctl --user call org.freedesktop.impl.portal.desktop.oo7 /org/freedesktop/portal/desktop
org.freedesktop.impl.portal.Secret RetrieveSecret osha{sv} <handle> <app_id> <fd> 0`, with
the read end collected from a pipe. [INFERENCE: busctl's `h` argument sends the numbered fd.
If it doesn't, use python3 `gi` `Gio.DBusConnection.call_with_unix_fd_list_sync`.]

- **T1 (unlocked).** Two calls with app id `org.krytis.Test` return identical bytes. A call
  with `org.krytis.Other` returns different bytes. Login holds exactly two
  `Secret Portal token for …` items.
- **T2 (discovered from disk, locked, no prompter on the private bus).** Restart the daemon
  without the helper and call again. The call must **fail**. Afterwards the collection list
  must be unchanged (no new `Default` collection), and `org.krytis.Test`'s token item in
  Login must be byte-identical. This also answers pam.md's open "discovered-from-disk"
  question; record the answer there.

Expected on unpatched upstream: T1 passes. T2 [INFERENCE] fails if R1a is real. Quote the A/B
in the PR, the way oo7-prompter-test's section in pam.md does.

## Step 2 — Gate sign-off

- [ ] Present the step 1 result with § Risks and § Decisions. Wait for answers.
- [ ] Record the answers in `docs/design/secrets-service.md` under a new § Secret portal
      (oo7-portal): the decision, R1–R3, the test, and the revisit triggers in step 6.

## Step 3 — Build and install `portal/` in `desktop/oo7.bst`

- [ ] A third `build-commands` block, mirroring `server/`'s options:

  ```
  meson setup portal/_build portal \
    --prefix=%{prefix} \
    --libexecdir=%{libexecdir} \
    -Dprofile=default \
    -Dsystemd=enabled \
    -Dsystemduserunitdir=%{indep-libdir}/systemd/user \
    -Ddbus_service_dir=%{datadir}/dbus-1/services
  ninja -v -j$(nproc) -C portal/_build
  ```

  Then `DESTDIR=%{install-root} ninja -C portal/_build install` in `install-commands`.
- [ ] Update the header (lines 1–7): three sub-projects, and the portal's D-Bus activation
      (unlike the server, the portal does ship a D-Bus `.service` file, which hands off to
      systemd).
- [ ] If D2 is (b): add the patch as a `kind: patch` source after
      `login-helper-connect-retry.patch`, with a header paragraph in the style of that one
      (what it fixes, why it is carried downstream first, its exit condition).
- [ ] Record the element's build time before and after in the PR.
- [ ] `files/fakecap-manifest.tsv`: add `desktop/oo7.bst` rows for every new file, read off
      `mise run bst artifact checkout desktop/oo7.bst`, not from this table. Keep the file
      `LC_ALL=C`-sorted.

## Step 4 — Route Secret to `oo7-portal`

- [ ] `files/xdg-desktop-portal/niri-portals.conf`, a pure delta:

  ```ini
  # krytis delta over niri's /usr/share/xdg-desktop-portal/niri-portals.conf.
  # xdp falls through to that file for every interface not listed here.
  # Remove once desktop/niri.bst pins a release containing niri 02fdd8e758
  # ("portals: add oo7 as secret portal"); portal-routing-check fails then. krytis#1028.
  [preferred]
  org.freedesktop.impl.portal.Secret=oo7-portal;
  ```

- [ ] `files/xdg-desktop-portal/umbriel-portals.conf`: add
      `org.freedesktop.impl.portal.Secret=oo7-portal;`. If #1029 hasn't landed, create the
      file with only this key: the fall-through keeps the rest of upstream's routing.
- [ ] `mise/tasks/portal-routing-check`:
  - Secret → `oo7-portal` in both tables.
  - Add the **redundant-override** rule: for each key in
    `/etc/xdg/xdg-desktop-portal/<d>-portals.conf`, fail when
    `/usr/share/xdg-desktop-portal/<d>-portals.conf` resolves that interface to the same
    backend. This makes a niri bump that carries `02fdd8e758` go red with "delete the
    delta", instead of leaving a dead override behind like #1027's.
- [ ] fakecap row for `/./etc/xdg/xdg-desktop-portal/niri-portals.conf`.

## Step 5 — Verify

- [ ] `mise run build`. `portal-routing-check` shows Secret → oo7-portal for both desktops.
- [ ] `mise run oo7-portal-test` (T1, T2). Also `mise run oo7-login-race-test` and
      `mise run oo7-prompter-test`, because the element changed.
- [ ] `mise boot-test`, then in a niri session and an Umbriel session:
  - Pick a Flatpak **without** `--talk-name=org.freedesktop.secrets`
    (`flatpak info --show-permissions`), so libsecret takes the portal path. Store a secret,
    restart the app, and read it back. This is the issue's Verify.
  - `busctl --user list | grep portal.desktop.oo7` shows the backend activated.
  - `secret-tool search app_id <id>` shows one `Secret Portal token for <id>` item in Login.
    Confirm the sandbox keyring file path from *Facts*.
  - **Negative:** `systemctl --user restart oo7-daemon`, then relaunch the app. Expect a
    noctalia unlock prompt (and with D2 (b), a failed request if it is dismissed). Never
    accept a new token. Compare the token item's secret before and after.
  - The host libsecret path is unchanged: Ghostty starts, `secret-tool store/lookup` works.

## Step 6 — Docs

- [ ] `docs/design/secrets-service.md` § Secret portal (oo7-portal), from step 2. Add
      revisit triggers to § Revisit trigger: the niri bump (delete the delta, gated); oo7
      upstream adopting the D2 (b) behaviour (drop the patch).
- [ ] `docs/skills/pam.md` § oo7 `default` alias requires an unlocked collection: replace
      the open "re-test the discovered-from-disk case" with T2's measured answer, in place.
- [ ] `docs/skills/desktop.md` § xdg-desktop-portal routing (#1027): Secret row, the delta
      file, and its removal condition.
- [ ] `docs/skills/mise.md`: `oo7-portal-test` row next to the other oo7 gates.
- [ ] `mise run docs-links`.

## Outcome (2026-10-05)

**Security Gate, answered 2026-10-02:** D1 ship; **D2 (a): upstream as-is, no patch**; D3
route Secret in both sessions. Recorded in `docs/design/secrets-service.md` § Secret portal
(oo7-portal) — shipping since #1028.

- **Step 1 measurement** (unpatched oo7 `bf367dca`: the image's daemon plus a portal built from
  the same pin). `mise run oo7-portal-test` passed T1 and T2. **R1a does not occur:** a Login
  keyring discovered on disk and left locked still answers `ReadAlias default` with
  `/org/freedesktop/secrets/collection/login`, because `load_keyring` assigns the alias before
  unlocking. With no prompter, T2's call never answers instead of failing (`unlock(None)`
  waits for a prompt), so the test closes the request after 5 s. Closing aborts the task
  cleanly (`Aborting active request`). T3 was added: after a restart into an unlocked Login,
  the first app gets its T1 token back. **Negative control:** a throwaway portal whose lookup
  never matches fails T1 and T3, while the item count stays at 2 (`replace=true` overwrites
  silently).
- **Step 3.** `desktop/oo7.bst` builds `portal/` as a third meson sub-project. Its build took
  12m03s (key `f46f97a9`, 2026-10-05). No before figure was recorded: the plan asked for one,
  but the artifact log of main's key does not carry the element's build span. On the bst
  artifact, `oo7-portal-test`, `oo7-login-race-test` and `oo7-prompter-test` passed.
  `files/fakecap-manifest.tsv` gained 9 rows read off the two artifacts (`--deps none`), none
  removed.
- **Step 4.** `config/xdg-desktop-portal-routing.bst` installs one-key `/etc/xdg` deltas for
  niri and Umbriel. `portal-routing-check` expects `oo7-portal` for Secret and gained the
  `REDUNDANT` rule. Probe images: pass with the deltas; `REDUNDANT` once upstream's niri file
  routes Secret to oo7-portal; `MISMATCH … got none` without the deltas.
- **Step 5.** `mise run build --pull` passed in 47 min: lint, both image gates, and
  `portal-routing-check` (niri 21/21, Umbriel 11/21, Secret → oo7-portal in both). The
  toolchain was pulled from bow; nothing was rebuilt. `mise boot-test` passed. **Not run
  here:** the in-session checks (Flatpak secret store and restart under niri and Umbriel,
  `busctl --user list | grep portal.desktop.oo7`, and the `systemctl --user restart
  oo7-daemon` negative). They need a real graphical session, so they are listed in the PR's
  test plan.
- **Step 6.** As listed. `docs/skills/pam.md` § oo7 `default` alias on a locked collection
  replaces the old claim in place, with its citers updated.
