# PAM & Keyring Skills

## systemd-homed users: FIDO2 login belongs to homed, not pam_u2f

Two independent things broke FIDO2 login for `systemd-homed`-managed users. Both were fixed in #409; keep them straight, because fixing only the first looks plausible and achieves nothing.

**1. `pam_u2f` structurally cannot serve homed *login*.**

In per-user mode (no `authfile=`) pam_u2f builds the path from the passwd entry — `resolve_authfile_path()` in `pam-u2f.c` does `dir = user->pw_dir` + `.config/Yubico/u2f_keys` — and `open()`s it during `pam_sm_authenticate` (`util.c:get_devices_from_authfile`). A homed user's home is an **unmounted encrypted image** at that moment: systemd's `home_activate()` (`src/home/homework.c`) only mounts it *after* `user_record_authenticate()` succeeds. So the `open()` returns `ENOENT` and pam_u2f returns **`PAM_AUTHINFO_UNAVAIL`** (not `PAM_USER_UNKNOWN` — that code is only used when the file parsed fine but held no line for this user). Upstream states the general case outright in pam-u2f's `README.adoc`: an authfile in an encrypted home makes login impossible.

Moving the authfile to a root-owned absolute path *would* make the `open()` succeed (`authfile=/etc/security/u2f_mappings/%u` + `expand`, no `openasuser` → read as root; note `expand` substitutes only `%u` and `%%`, there is no `%h`). **Do not do it.** For homed, the token's `hmac-secret` output *is* the key material that decrypts the home — `fido2_use_token()` in `src/home/homework-fido2.c` derives the LUKS/fscrypt passphrase from it. A `sufficient` pam_u2f success would end the auth stack before `pam_systemd_home` ever ran, landing the user in a session with no home mounted. FIDO2 for homed login is homed's job, via `homectl update <user> --fido2-device=auto` (rp_id `io.systemd.home`).

pam_u2f is still right for a homed user's **sudo/polkit**: by then the home is mounted, so the per-user authfile is readable. Hence `mise fido2:enroll` enrolls the key twice for homed users — once into the home record, once into `~/.config/Yubico/u2f_keys`.

**2. `/etc/pam.d/greetd` had no `pam_systemd_home.so` at all.**

Because greetd's stack is self-contained (it does not `include system-auth`), homed users got no `pam_systemd_home` there at all. tty `login` worked the whole time because it `include`s `system-auth`, which did carry the module. **Any new self-contained PAM service in this repo must carry `pam_systemd_home.so` in all four phases.**

**The failure mode is silent, not a denial — this is the part that is easy to get wrong.** The intuition "a homed user has no `/etc/shadow` entry, so `pam_unix` denies" is false here: `/etc/nsswitch.conf` has `shadow: files systemd`, so nss_systemd serves the record's privileged `hashedPassword` to root and `pam_unix` authenticates the user perfectly well. The greeter login *succeeds*, homed is never asked to activate anything, and the session comes up with the home unmounted. Confirmed on real hardware — with the home inactive, NSS rewrites the record:

```
$ getent passwd fido2test
fido2test:x:60097:60097:fido2test:/:/usr/bin/systemd-home-fallback-shell
$ userdbctl user fido2test | grep Shell
      Shell: /usr/bin/systemd-home-fallback-shell (fallback)
$ homectl list          # the record's real shell, for contrast
NAME       ... STATE    ... SHELL
fido2test  ... inactive ... /bin/bash
```

Home reported as `/`, shell swapped for the fallback. So the symptom to look for is **"logs in but `$HOME` is wrong / nothing persists"**, not "cannot log in" — and a smoke test that only checks *whether* login succeeds will pass on a completely broken configuration. Always assert the home is actually mounted (`mount | grep <user>`, or `getent passwd <user>` showing the real home and shell).

This is also the concrete instance of the hazard that rules out a central pam_u2f authfile for homed login (see above): a `sufficient` module succeeding before `pam_systemd_home` produces exactly this state.

**Use upstream's jump spec, not `sufficient`.** `pam_systemd_home` returns `PAM_USER_UNKNOWN` for classic `/etc/passwd` users — *not* `PAM_IGNORE` (`acquire_user_record` → `goto user_unknown`, also for `BUS_ERROR_NO_SUCH_HOME` and for homed not running). With plain `sufficient`, genuine homed auth failures also fall through and get silently retried against `pam_unix`. `pam_systemd_home(8)`'s EXAMPLE is what both `system-auth`/`password-auth` and `greetd` now use:

```
-auth      [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
```

`account`/`password` keep `-… sufficient`, and `session` keeps `-session optional` (that one takes a reference on the home so homed does not deactivate it mid-session — omit it and the home disappears under the running session).

**Verifying a PAM stack edit without root or a reboot.** Extract the heredoc from the `.bst` element, drop it into `/etc/pam.d/` inside a `podman run` of the built image, and drive real `pam_authenticate()`/`pam_acct_mgmt()` calls with a `ctypes` conversation function. Always include a **negative control** — corrupt one token in the jump spec (`authtok_err=bogus`) and confirm the run flips to `PAM_SERVICE_ERR (3)`; without it a "Success" proves nothing, since libpam happily ignores plenty of mistakes. Two ctypes gotchas: set `libc.calloc`/`libc.strdup` `restype` to `c_void_p` (the default `c_int` truncates the pointer and segfaults), and remember `strings` defaults to a 4-char minimum, so libpam's short action tokens `ok`/`bad`/`die` only show up under `strings -n 2`.

**Test against a LIVE homed, not just an absent one.** A plain `podman run` has no homed at all, so `pam_systemd_home` takes the *no-bus* path — `acquire_user_record` never reaches homed and returns `PAM_USER_UNKNOWN` early. That is a different code path from the one a real krytis box exercises, where homed **is** running (`vm/config/systemd-homed-firstboot.bst`) and returns `BUS_ERROR_NO_SUCH_HOME` for a non-homed user. Both end at `PAM_USER_UNKNOWN`, so `default=ignore` covers both — but proving the second one needs homed actually on the bus. You do not need PID-1 systemd, a VM, LUKS, a loop device, or a security key for that; a rootless container is enough:

```bash
mkdir -p /run/dbus /var/lib/systemd/home
dbus-daemon --system --fork --nopidfile
/usr/lib/systemd/systemd-userdbd &
/usr/lib/systemd/systemd-homed &
busctl --system status org.freedesktop.home1        # expect PID/Comm=systemd-homed
busctl --system call org.freedesktop.home1 /org/freedesktop/home1 \
  org.freedesktop.home1.Manager ListHomes           # expect: a(susussso) 0
```

`--cap-add=all` is needed; `Failed to allocate memory pressure watch` and the `Unknown group "netdev"` dbus warning are both benign in a container.

**`homectl` has a PID-1 guard that `busctl` does not.** Inside that container `homectl list` fails with `System has not been booted with systemd as init system (PID 1). Can't operate.` even though homed is live on the bus — which is why the liveness check above uses `busctl`. Krytis always boots systemd so `homectl` is fine in production, and `mise fido2:enroll`'s `is_homed_user()` degrades in the safe direction if it ever isn't (detection fails → classic path → you get the pam_u2f credential and notice the missing homed one). Do not "fix" this by switching detection to `busctl` parsing; the guard is not reachable on a real deployment.

**Also drive `sudo` and `login`, not just `system-auth` directly** — they `include` it, and an ordering mistake can show up only through the wrapper. One caveat: a `sudo` probe run as root returns `Success` for *any* password because `pam_rootok.so` is first, so that row proves nothing; test `sudo` as an unprivileged user, or rely on the `system-auth` row it includes.

**Known gap, not a regression:** `pam_systemd_home` sets `PAM_AUTHTOK` for downstream modules *only if a password was actually used*. A FIDO2-only homed login therefore leaves `pam_gnome_keyring`/`pam_oo7` with no token and the keyring locked — the same shape as the pam_oo7 problem below, tracked in #129.

## pam_oo7: null PAM_AUTHTOK does not unlock

`pam_oo7.so` called from `pam_sm_authenticate` with a null `PAM_AUTHTOK` (i.e. no password collected) does **not** unlock the Login collection. Null ≠ empty string — pam_oo7 treats null as "no credentials provided" and skips unlock entirely.

**FIDO2 impact:** `pam_u2f sufficient` short-circuits the PAM auth stack. If pam_u2f succeeds, pam_oo7's `auth` phase never runs. Reordering pam_oo7 before pam_u2f doesn't help — pam_oo7 auth runs but still receives null PAM_AUTHTOK (pam_u2f does not set it).

Result: on FIDO2 login, the oo7 Login collection stays locked all session.

## oo7 `default` alias requires an unlocked collection

oo7-daemon only loads keyring aliases (including `default`) when a collection is unlocked. If Login stays locked, `default` is never set on the D-Bus Secret Service. libsecret clients (e.g. Ghostty) that expect a `default` alias get an unexpected Prompt response and **crash at session start**.

This is the root cause of Ghostty instability on FIDO2 login with oo7.

### Revalidated 2026-08-12 against upstream `main` + Fedora's F45 rollout — still open, not a regression

Re-checked this against current `linux-credentials/oo7` `main` (post-0.7.0-alpha) while cross-referencing Fedora's [F45 "oo7 Secrets Service Provider" change](https://fedoraproject.org/wiki/Changes/oo7_Secrets_Service_Provider) (system-wide default for F45, FESCo-approved). The mechanics above are **not stale**:

- `pam/src/lib.rs::get_auth_token_internal` still returns `Err(PAM_SYSTEM_ERR)` on a null `PAM_AUTHTOK` pointer; `pam_sm_authenticate` still treats that as "nothing to stash" and returns `PAM_SUCCESS` without stashing, so `pam_sm_open_session` finds no stashed password and skips the unlock send entirely. Same behavior, verified against source, not inferred from the bug report.
- This is genuinely unresolved upstream, not just untriaged: [oo7#506](https://github.com/linux-credentials/oo7/issues/506) is a maintainer discussion on passwordless/FIDO2 keyring unlock, still active as of 2026-08-02. Maintainer's stance is to wait on `credentiald` and a systemd PR to mature before deciding a direction — there is no near-term fix in flight.
- **Not a regression vs. gnome-keyring** — the "Known gap, not a regression" note above already covers this: gnome-keyring has the identical gap on FIDO2-only login, since neither module gets a password to unlock with. Switching to oo7 does not make this worse; it also does not fix it.

**New gap found via oo7#506** (2026-08-03 comment, not previously documented here): the *unlocked* Login collection can re-lock with **no explicit `Lock()` call** if `oo7-daemon.service` restarts mid-session — the one-shot PAM helper's memfd doesn't survive the restart, and there is no FD-store/credential-based resume yet. Reporter's trigger was a package update restarting the daemon without ending the session. Lower risk for krytis specifically since bootc updates are reboot-driven rather than live in-place restarts, but still applies to `systemctl --user restart oo7-daemon` or a crash-restart mid-session — worth a boot-test scenario if #84 is re-attempted.

**Two corrections to carry into any future #84 attempt** (upstream `pam/README.md`, read 2026-08-12):
- ~~The PAM socket is `$XDG_RUNTIME_DIR/oo7/pam.sock` (`OO7_PAM_SOCKET`-configurable) — not `oo7-pam.sock` as ArchWiki has it.~~ **Wrong — corrected 2026-08-12.** ArchWiki was right. The socket is `/run/user/<uid>/oo7-pam.sock`, still `OO7_PAM_SOCKET`-configurable. Verified three ways: read from source on **both** the 0.6.0 tag (`server/src/pam_listener/mod.rs:59`, `pam/src/socket.rs:195`) and current `main` (`server/src/pam_listener/mod.rs:100`, `pam/src/socket.rs:273`) — both sides hardcode the same `format!("/run/user/{uid}/oo7-pam.sock")` default — and observed at runtime on a built krytis image: `INFO oo7_daemon::pam_listener: PAM listener started on /run/user/1000/oo7-pam.sock`. The daemon and the PAM module agree, which is what actually matters; the earlier note would have sent a debugger to a path that never exists.
- Upstream's own `password` stack example is `password optional pam_oo7.so`, with **no `use_authtok`**. Krytis's current gnome-keyring line is `-password optional pam_gnome_keyring.so use_authtok` — don't carry `use_authtok` over by habit; pam_oo7's password-stack path captures old+new tokens itself. Confirm whether it needs/uses the flag before porting.
- oo7 ships no ssh-agent component at all (repo layout: cargo-credential, cli, client, git-credential, pam, portal, server, kwallet — no ssh_agent crate). This isn't "a different SSH_AUTH_SOCK path to switch to" — whatever provides `SSH_AUTH_SOCK` today has to keep existing independent of this migration.

**`oo7-daemon` startup capability behaviour — the scary warning is the normal case.** On a
real user session the daemon logs
`WARN oo7_daemon::capability: No process capabilities, insecure memory might get used`
and carries on. That is expected and not a failure: `server/src/capability.rs`
`drop_unnecessary_capabilities()` branches on how many capabilities the process holds, and a
plain user session holds none → `CapabilityState::None` → warn and return `Ok`. The daemon
only wanted `CAP_IPC_LOCK` so it could `mlockall()` secrets out of swap.

The trap is the middle case. With a *partial* capability set that lacks `IPC_LOCK` — exactly
what `podman run` as root gives you (~11 caps, no `IPC_LOCK`) — the ≥10-caps heuristic picks
`CapabilityState::Full`, and `set_capabilities()` then fails trying to raise `IPC_LOCK` into
the permitted set:

```
ERROR oo7_daemon: Capability error Operation not permitted (os error 1)
Error: Capability(Os { code: 1, kind: PermissionDenied, ... })
```

So `podman run --rm <image> /usr/libexec/oo7-daemon` "proves" the daemon is broken when it is
fine. Reproduce daemon behaviour with `--user 1000` (zero caps, matching a real session), or
grant `--cap-add IPC_LOCK`. Verified on a built krytis image: as uid 1000 the daemon starts,
creates a locked `Login` collection, and owns `org.freedesktop.secrets`.

**No prompter on the bus means libsecret callers hang, not fail — confirmed on krytis, with
oo7.** Previously this was inferred from pop-os/cosmic-epoch#3453 (COSMIC, gnome-keyring).
Reproduced directly: with `oo7-daemon` running and nothing owning
`org.gnome.keyring.SystemPrompter`, `secret-tool store` against the locked `Login` collection
blocked until killed at 25s and printed nothing. oo7 logged only `Client :N connected` and,
on the timeout, `disconnected`. A bus trace shows what it was waiting on:

```
org.gnome.keyring.SystemPrompter · org.gnome.keyring.internal.Prompter · BeginPrompting
/org/gnome/keyring/Prompter      · /org/gnome/keyring/Prompt/p   (oo7's Callback object)
```

So oo7's `GNOMEPrompterProxy` really does drive the GCR prompter protocol, and a missing
prompter is not a degraded mode — it is an indefinite hang in every caller, with no error
anyone would think to file. Worth remembering when triaging "the keyring is stuck": check
`busctl --user list | grep SystemPrompter` before anything else.

## oo7's collection path is `…/collection/Login` — capital L, unlike gnome-keyring

gnome-keyring exposes the login keyring at `/org/freedesktop/secrets/collection/login`. oo7
derives the path from the keyring *label*, so it is **`/org/freedesktop/secrets/collection/Login`**.
Anything with the lowercase path hardcoded silently fails after the swap:

```
secret-tool: No such secret collection at path: /org/freedesktop/secrets/collection/login
```

`secret-tool lock --collection=` wants the bare name, not a path — `--collection=Login` works,
`--collection=login` and `--collection=default` both fail, and passing a full object path
trips `g_dbus_connection_signal_subscribe: assertion 'object_path == NULL || …' failed`
because secret-tool prepends the prefix itself.

**Check whether the keyring is unlocked** (the answer is `b false` when unlocked):

```shell
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/Login \
  org.freedesktop.Secret.Collection Locked
```

Portable version that does not care what the collection is called, resolving the `default`
alias first:

```shell
C=$(busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
      org.freedesktop.Secret.Service ReadAlias s default | awk '{gsub(/"/,"",$2); print $2}')
busctl --user get-property org.freedesktop.secrets "$C" \
  org.freedesktop.Secret.Collection Locked
```

`Collections` on `org.freedesktop.Secret.Service` lists everything; expect the ephemeral
`…/collection/session` (always `Locked=false`) alongside `…/collection/Login`.

**Partial data point on the `default`-alias claim above.** On oo7 0.6.0, when the daemon
*creates* the default keyring itself (`No default collection found, creating 'Login' keyring`
→ `Created default 'Login' collection (locked)`), `ReadAlias default` **does** resolve to the
Login path while it is still locked. That does not overturn § *oo7 `default` alias requires an
unlocked collection*: the original report concerns a keyring discovered on disk, and that path
could not be reached in testing because oo7 writes no keyring file until a secret is actually
stored — a restart just re-runs the create branch. Re-test the discovered-from-disk case
before relying on either statement.

## Re-locking a collection with oo7: `Lock` looks like a no-op, restart the daemon instead

`secret-tool lock --collection=Login` exits 0 and prints nothing, but the collection can stay
unlocked. Calling the D-Bus method directly shows why — oo7 0.6.0 reports **success for an
object it simultaneously says does not exist**:

```
$ busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
    org.freedesktop.Secret.Service Lock ao 1 /org/freedesktop/secrets/collection/Login
WARN oo7_daemon::service: Object: /org/freedesktop/secrets/collection/Login does not exist.
aoo 1 "/org/freedesktop/secrets/collection/Login" "/"
```

The path is returned in the "locked" array with no prompt object (`"/"`), i.e. "already
done" — while `get-property … Locked` on that same path answers fine, so the object plainly
does exist. Observed against an already-locked collection, so this is not proof that `Lock`
never works; it is enough to stop trusting a silent exit 0.

**Always confirm the state changed rather than assuming the command worked:**

```shell
secret-tool lock --collection=Login
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/Login \
  org.freedesktop.Secret.Collection Locked      # b true = it actually locked
```

**The dependable way to get back to a locked collection is to restart the daemon** —
`systemctl --user restart oo7-daemon.service`. oo7 has no FD-store/credential resume
(oo7#506), so a restart drops the unlocked state. That doubles as the mid-session re-lock
scenario worth testing anyway.

This matters when testing a prompter: **libsecret's `lookup` does request an unlock** — 
`on_lookup_searched` in `secret-methods.c` branches to the unlock path when the search returns
locked items — so "lookup did not prompt" almost always means the collection was never locked,
not that the prompter failed.

## A locked oo7 collection returns "no such secret", not a prompt

`secret-tool lookup` against a locked oo7 collection returns **not found in 0s** — no prompt,
no error. The item is there; oo7 will not admit it exists.
`server/src/collection/mod.rs::search_inner_items` returns an empty vec whenever the keyring
is locked (same on the 0.6.0 tag and current `main`), because oo7 encrypts item attributes at
rest and cannot match them without the collection key. `SearchItems` therefore reports
`(0 unlocked, 0 locked)`, and libsecret's `on_lookup_searched` — which would otherwise branch
to the unlock path — sees nothing to unlock and reports failure.

Consequences when debugging:

- **A silent "secret not found" on oo7 is a lock symptom first, a missing-secret symptom
  second.** Check `Locked` on the collection before believing the lookup.
- **`store` still prompts** (writing needs the collection open), so the prompter can look
  perfectly healthy while every read quietly fails. Do not conclude "prompting works" from a
  successful store alone.
- gnome-keyring does not behave this way: it keeps attributes searchable while locked, which
  is what lets a client discover a locked item and request an unlock.

Full reproduction, source references and the effect on the #84 decision:
`docs/design/secrets-service.md` § *New blocker found while testing*.

See `docs/design/secrets-service.md` for the decision this feeds. As of 2026-08-12 the hold on #84 needs **two** things, not one: oo7#506 resolved *and* oo7 reporting locked items from `SearchItems`. Accepting the FIDO2 gap is no longer sufficient on its own — a locked collection is reported as "no such secret", so the user never gets the chance to unlock.

## Manual unlock on niri needs `gcr-3` (gcr-prompter) — same for oo7 and gnome-keyring, easy to drop by accident

Traced through `linux-credentials/oo7`'s prompter backend selection (`server/src/service/mod.rs::prompter_type`, 2026-08-12) to answer "what shows the unlock dialog on niri, a non-GNOME/non-KDE compositor, when PAM auto-unlock doesn't apply?" (secondary/locked collections, `CreateCollection`, `ChangePassword`, or any manual `Unlock()` call).

**The backend choice is display-presence, not desktop-identity:**
```rust
let has_display = DISPLAY or WAYLAND_DISPLAY set;
if has_display {
    if plasma_feature_enabled && in_plasma_environment() { return Plasma; }
    return PrompterType::GNOME;   // ← default whenever a display exists and it isn't Plasma
}
PrompterType::Cli                 // ← only when there is NO display at all (headless/TTY)
```
niri sets `WAYLAND_DISPLAY`, so oo7 always resolves to `PrompterType::GNOME` there — **not** the `Cli`/`org.freedesktop.secrets.CliPrompter` fallback. There is no niri-native or generic-wlroots prompter upstream; "GNOME" is the only GUI path offered to any Wayland session that isn't detected as Plasma.

**"GNOME" here means `gcr-prompter`, not GNOME Shell.** The GNOME path calls `org.gnome.keyring.SystemPrompter` (`server/src/gnome/prompter.rs`), which is a D-Bus-activated well-known name owned by `gcr-prompter` — a standalone GTK binary shipped by GCR, not part of gnome-shell. It works on any Wayland compositor, D-Bus-activates on demand (no `no_autostart` on this proxy, unlike the CLI one), and shows a plain GTK dialog. Confirmed by community reports for Sway/Hyprland: it works, but fails with "No Gcr System Prompter available" if `WAYLAND_DISPLAY`/`DISPLAY` aren't visible to the D-Bus session when it activates.

**krytis already ships this, transitively — verify it stays if #84 is re-attempted.** `gnome-keyring.bst` (`gnome-build-meta.bst:core/gnome-keyring.bst`) has a **runtime** `depends: sdk/gcr-3.bst` (checked against the staged junction source, not a local grep — see AGENTS.md's transitive-dependency warning). That's how `gcr-prompter` gets into the image today. If oo7 replaces gnome-keyring in `stacks/desktop.bst`, that dependency disappears unless `oo7.bst` (or the stack) adds `sdk/gcr-3.bst` explicitly — gh178's plan never mentioned it, so the prior attempt would have shipped a manual-unlock path that silently fails.

**`gcr-4` (`sdk/gcr.bst`) is not a substitute for `gcr-3` here — by upstream design, not by accident.** GCR's own `NEWS` file says it outright: `gcr 3.90.0` — *"All deprecated API has been removed, as well as most UI-related code."* / `gcr 3.92.0` — *"gcr4 will no longer ship UI libraries, i.e. gcr-gtk3 or gcr-gtk4."* Confirmed by diffing the actual tarballs krytis's junction pins (`gcr-4.4.0.1.tar.xz` vs `gcr-3.41.2.tar.xz`): GCR3 has a `ui/` directory that builds `executable('gcr-prompter', 'gcr-prompter-tool.c', …)` plus `gcr/org.gnome.keyring.SystemPrompter.service.in` (`Exec=@libexecdir@/gcr-prompter`) — a generic, D-Bus-activatable, desktop-agnostic prompter binary. **GCR4 dropped the `ui/` directory and the `.service.in` file entirely**, keeping only the library-side base class (`gcr-system-prompter.c`/`.h`, exposed as `Gcr.SystemPrompter`) and the D-Bus interface XML.

**The prompter didn't disappear in GCR4 — it moved into each desktop shell, which is the part that matters for niri.** `gnome-shell`'s `js/ui/components/keyring.js` subclasses `Gcr.SystemPrompter` directly: `class KeyringPrompter extends Gcr.SystemPrompter`, and `enable()` calls `Gio.DBus.session.own_name('org.gnome.keyring.SystemPrompter', …)` itself — gnome-shell *is* the D-Bus service under real GNOME, built on top of GCR4 as a library, not a separate process. KDE Plasma has its own equivalent (this is exactly why oo7's `Plasma` prompter type is a separate code path from `GNOME` in `prompt/mod.rs`). **niri has no such component.** There is no third-party or generic shell-level `Gcr.SystemPrompter` implementation for wlroots/smithay compositors — the only thing standing in for it is the legacy GCR3 `gcr-prompter` binary, which upstream GNOME itself no longer builds by default (GCR4 is what ships in current GNOME; GCR3 survives only as a compatibility package for consumers — like gnome-keyring, and krytis — that still need the old prompter binary).

**This is not a theoretical risk — it is a confirmed, currently-open failure mode on a structurally similar non-shell compositor.** [pop-os/cosmic-epoch#3453](https://github.com/pop-os/cosmic-epoch/issues/3453) (COSMIC, wlroots-adjacent, no gnome-shell) reports exactly this: `gcr-prompter` (GCR3) *is* installed and its `.service` file *is* present, login-time PAM auto-unlock works fine, but a **mid-session** daemon restart (e.g. a package upgrade) leaves the login keyring locked with no path back — the prompter fails to activate in COSMIC's session D-Bus environment (reporter's suspected cause: missing `WAYLAND_DISPLAY`/`DISPLAY` in the D-Bus activation environment, unconfirmed), `gnome-keyring-daemon` times out after ~25s waiting on `create system prompt`, then **crashes**, leaving the libsecret caller wedged forever rather than returning a clean error. This downgrades the "Low risk" framing in the section above — the env-timing hazard is real and reproduced in the wild on a peer environment, not just theoretically low-probability from `import-environment` timing. **Do not ship #84 (or trust the current gnome-keyring setup) without an explicit boot test**: lock a non-login collection, kill/restart the keyring daemon mid-session, and confirm a GTK unlock dialog actually appears rather than hanging.

**Longer-term architectural question, not blocking today:** krytis's manual-unlock path depends indefinitely on a component (`gcr-3`/`gcr-prompter`) that upstream GNOME has already deprecated in favor of shell-owned prompters. There is no krytis-owned alternative today — building one would mean wiring `Gcr.SystemPrompter` (GCR4) into noctalia-greeter or a niri-adjacent component, mirroring what `keyring.js` does for gnome-shell. Not worth doing speculatively, but worth knowing this is the eventual answer if `gcr-3` ever stops being packaged upstream.

**The env-timing risk documented in `docs/skills/desktop.md` § Toolkit Vulkan / Wayland Environment mostly doesn't apply here.** That section warns `niri-session`'s `systemctl --user import-environment` fires too late for *early* D-Bus-activated services (pipewire, xdg-desktop-portal). `gcr-prompter` isn't early — it activates lazily whenever a prompt is actually needed, which in practice is well after session startup and therefore after `import-environment` has already run. Low risk, but worth an explicit boot-test assertion (`secret-tool lock` a non-login collection, then trigger `Unlock()` and confirm a GTK window actually appears) rather than assuming it from this reasoning alone.

## Writing an `org.gnome.keyring.SystemPrompter` provider: reply ordering is the whole game

The "eventual answer" above was built. A native prompter now exists on the noctalia fork
(`kitten-lily/noctalia`, branch `feat/system-prompter`, commit `ba821c7da`) — see
`docs/design/secrets-service.md` § Status for scope and verification. Lessons that will
outlive that branch:

**The `BeginPrompting` method reply MUST reach the bus before the `PromptReady` it triggers.**
This is the one non-obvious requirement, and a hand-written test client will not catch it. gcr's
real client (`GcrSystemPrompt`, what gnome-keyring and seahorse use) sets up its pending async
result only once `BeginPrompting` returns; a `PromptReady` that overtakes that reply trips
`prompt_method_ready: assertion 'G_IS_SIMPLE_ASYNC_RESULT (self->pv->pending)' failed` and the
session then dies with the misleading *"Another prompt is already in progress"*. gcr's own
prompter gets this right by calling `g_dbus_method_invocation_return_value()` *before*
`prompt_next_ready()`. With `sdbus-c++`, a plain value-returning handler sends the reply only
*after* the handler returns, so `BeginPrompting` and `StopPrompting` must take a deferred
`sdbus::Result<>` and call `returnResults()` explicitly before dispatching anything.

**Test against `GcrSystemPrompt`, not a mock.** The bug above passed a bespoke test client and
failed the real one. Driving gcr's client in a forked child (its sync API spins its own
`GMainLoop`, so it cannot share a thread with a hand-pumped sdbus connection) while the parent
pumps the service is a cheap way to get a genuine interop assertion.

**`gcr-4` still ships `GcrSystemPrompter`, the server-side machinery** — only the *binary* and
its `.service` file were dropped, not the library class. Using it means implementing the
`GcrPrompt` GObject interface (property-heavy, async vfuncs); the native route reimplements the
small D-Bus surface instead and links only `GcrSecretExchange` for the `sx-aes-1` handshake, so
the secret is never a plaintext D-Bus argument. Either way, read `gcr/gcr-system-prompter.c` —
it is the authoritative spec for the wire behaviour, including that a cancelled password prompt
still replies through `gcr_secret_exchange_send()` with a NULL secret, and that the reply
strings are `""` / `"yes"` / `"no"`.

**Owning the name is conditional.** A prompter must not claim
`org.gnome.keyring.SystemPrompter` when gnome-shell or a live `gcr-prompter` already holds it;
treat `requestName` failure as "stay out of the way", not as an error.

## oo7 v0→v1 keyring migration is destructive on rollback

When oo7-daemon first starts, it migrates the existing gnome-keyring `login.keyring` (v0 format) to `~/.local/share/keyrings/v1/login.keyring` (oo7 v1 format) and removes the original file.

**Rolling back to gnome-keyring after oo7 has run:**
1. `~/.local/share/keyrings/login.keyring` is gone — gnome-keyring sees no Login keyring.
2. The data is in `v1/login.keyring` in oo7's format — gnome-keyring cannot read it.
3. If the secrets are not important: `rm -rf ~/.local/share/keyrings/v1/` and log out/in — PAM recreates a fresh `login.keyring`.
4. If secrets matter: run oo7-daemon temporarily (e.g. from a container with the old image), unlock the Login collection, then `secret-tool search --all ""` to extract before deleting v1/.

## gnome-keyring-daemon rescan after new login.keyring

gnome-keyring-daemon may start before PAM writes a new `login.keyring` (race condition on first login after rollback). Symptom: `ReadAlias("login")` resolves to a path, but the object at that path doesn't exist on D-Bus — the collection is listed but not mounted.

Fix: `pkill -f gnome-keyring-daemon` — it restarts via D-Bus activation, rescans the keyrings directory, and mounts the Login collection.

Note: `pkill gnome-keyring-daemon` fails silently on Linux — the process name exceeds 15 chars. Always use `pkill -f`.

## oo7 CreateCollection panics on wrong property key

Upstream bug: passing the wrong property key to `CreateCollection` causes an `unwrap()` panic instead of returning an error. Originally seen at `client/src/dbus/api/properties.rs:84:78`; the file has since been restructured (deserialization now branches on `contains_key(COLLECTION_PROPERTY_LABEL)` first), but the underlying bug is unchanged as of 2026-08-12 — the wrong key falls into the item-properties branch and panics on `map.get(ITEM_PROPERTY_LABEL).unwrap()` instead, since neither the correct nor the attempted key is present there. Re-verify the exact panic line against current `main` before citing it, not this note.

Correct key: `org.freedesktop.Secret.Collection.Label` (capital S, singular Secret)  
Wrong key: `org.freedesktop.secrets.collection.Label` (lowercase, plural) → panic

## noctalia-greeter: PAM_TEXT_INFO (FIDO2 cue) display — fixed upstream

`driveAuthConversation` in `greeter_surface.cpp` used to ACK `Info` messages with an empty response but not call `updateStatus` for them — the "Please touch your security key" cue was silently dropped. Krytis carried a local patch (`files/noctalia-greeter/0001-show-pam-info-cue.patch`) fixing this via `updateStatus` for both Info/Error, a `layoutScene` `hasStatus` check, and a `commitImmediateFrame(true)` before the blocking `postAuthData("")` recv (same pattern as `tryAuthenticate()`).

Merged upstream in noctalia-dev/main commit `26865dae` ("always allow empty passwords and surface PAM info messages"). `desktop/noctalia-greeter.bst` is now pinned to upstream `main` directly — the local patch and fork pin are gone. If a future `bst source track` update on this element regresses the cue, check whether `26865dae`'s equivalent logic survived the change.

## noctalia polkit agent: FIDO2 works out of the box

Noctalia ships its own polkit agent (`src/dbus/polkit/`). The `show-info` signal (from `PAM_TEXT_INFO`) is wired to `showInfoCallback → setSupplementary(text, false)`, which `polkit_panel.cpp` displays in `promptLabel` when no input is required. Multi-round (PIN prompt) is handled via the `request` signal → `handleRequest` → input field shown. No krytis config change needed for polkit FIDO2. Verified by code audit against polkit `9e4894c` and noctalia `78e528b` (issue #137).

**PAM chain**: `polkit-1` → `system-auth` → `pam_u2f.so`. The polkit meson.build defaults to `system-auth` for non-SUSE/non-BSD Linux builds.

## PAM file path in Freedesktop SDK

fdsdk uses an arch-specific libdir: `/usr/lib/x86_64-linux-gnu`. PAM modules must be installed to `/usr/lib/x86_64-linux-gnu/security/`. In BST variables: `pam_moduledir=%{libdir}/security`.

Do not assume `/usr/lib/security/` — that path does not exist in fdsdk images.

## `UsePAM yes` keeps a password path open behind `PasswordAuthentication no`

`PasswordAuthentication no` on its own does **not** disable password login when
`UsePAM yes` and `KbdInteractiveAuthentication yes` are both set — which is the
shipped combination. sshd still advertises `keyboard-interactive`, and PAM answers
it with a password prompt from `pam_unix`. Measured on the krytis image:

```
# PasswordAuthentication no, KbdInteractiveAuthentication yes, UsePAM yes
debug1: Authentications that can continue: publickey,keyboard-interactive

# PasswordAuthentication no, KbdInteractiveAuthentication no, UsePAM yes
debug1: Authentications that can continue: publickey
```

So key-only SSH requires **both** to be `no`. krytis sets both in
`elements/config/ssh-auth-policy.bst` → `/etc/ssh/sshd_config.d/10-krytis-auth.conf`
(#408). Reproduce the check with `ssh -v` against a throwaway container sshd and
read the `Authentications that can continue:` line — do not infer it from the
config file.

krytis cannot drop `UsePAM yes`: it is what gives sshd `pam_u2f` and
`pam_systemd_home`, and `openssh.bst` is built `--with-pam-service=sshd` against
linux-pam's `/etc/pam.d/sshd`.

### Priority: SSH gaps are low priority — krytis is a desktop, not a server OS

Read this before spending effort on anything in the next two sections.

SSH is **opt-in and not shipped running**. `openssh.preset` contains `disable sshd.service`, nothing pulls it into `multi-user.target`, and there is no `sshd.socket` — so on a default install there is no listener at all. Verify rather than trust this note:

```bash
podman run --rm localhost/krytis:latest sh -c \
  'grep -rn sshd /usr/lib/systemd/system-preset/; ls /usr/lib/systemd/system/multi-user.target.wants/ | grep -i ssh'
```

Consequences for how you triage:

- **Never weaken a desktop-facing posture to fix an SSH-facing gap.** Re-enabling `KbdInteractiveAuthentication` to make homed-over-SSH work would trade a shipped, always-on security property for a path most users never enable. That trade is a Security Gate decision, not a default — and in the homed case it is not even necessary (see below).
- **Never reorder work to get SSH working.** Greeter, console, sudo and polkit are the paths every user hits on every boot; they come first. An SSH-only defect is not a release blocker.
- **Lockout recovery is via console**, which is why key-only SSH is an acceptable default here at all. Same reasoning already recorded in `elements/config/ssh-auth-policy.bst`.
- SSH still has to be *correct* when someone opts in — don't ship knowingly broken config, and don't delete SSH code paths as dead (see the `password-auth` note in `elements/config/u2f-config.bst`). Low priority means "do not let it set the agenda", not "do not care".

#422 (homed SSH fallback shell) is filed under exactly this policy: a real gap, correctly diagnosed, deliberately not urgent.

### Two consequences of key-only SSH

**Constrains homed-managed homes, but does NOT require keyboard-interactive back.**
`pam_systemd_home` cannot unlock the home from a pubkey-only login: `pam_sm_open_session`
issues `RefHome`, which can only take a reference on an *already-active* home, never
activate an inactive one — activation needs `AcquireHome` from the auth phase that
pubkey-only SSH skips. So the session starts with no `$HOME` mounted. This is the
*normal* case now, not a corner case: `docs/design/first-boot-setup.md` makes
`krytis-firstboot.service` (which runs `homectl firstboot`) the default path for
the initial account, so a fresh krytis install has a homed-managed user from boot
one, not a classic
`useradd` account (`useradd` still works for any additional accounts created
later, with plain home directories — see docs/skills/desktop.md § `/etc/skel`).

Upstream's answer is **`systemd-home-fallback-shell`**, not re-enabling
keyboard-interactive. `homectl.c` says so outright: *"if users log into a system via
ssh … SSH doesn't allow us to ask authentication questions from the PAM session stack,
and doesn't run the PAM authentication stack … homectl can be invoked as a multi-call
binary under the name 'systemd-home-fallback-shell'."* `pam_systemd_home` sets
`XDG_SESSION_INCOMPLETE=1` and, via `fallback_shell_can_work()`, `ACQUIRE_REF_ANYWAY`
when there is no `PAM_XDISPLAY` and `PAM_TTY` has no colon — i.e. exactly a TTY/SSH
login. The fallback shell then authenticates interactively, activates the home, and
execs the real shell.

**It needs no wiring — homed substitutes it automatically.** I first wrote that "nothing
in krytis wires it up, which is the actual gap"; that was wrong. While a home area is
inactive, nss_systemd rewrites the record it serves, swapping the user's real shell for
the fallback and reporting the home as `/`. Observed on real hardware:

```
$ getent passwd fido2test          # inactive home, via NSS
fido2test:x:60097:60097:fido2test:/:/usr/bin/systemd-home-fallback-shell
$ userdbctl user fido2test | grep Shell
      Shell: /usr/bin/systemd-home-fallback-shell (fallback)
$ homectl list                     # the record's real shell, for contrast
fido2test  ... inactive ... /bin/bash
```

So the open question for #422 is not "how do we install it" but "does it actually work
over pubkey-only SSH end to end, including the FIDO2 path" — which is a test, not an
implementation. Verified against systemd v258 source plus the live observation above; see
`## systemd-homed users` above and #422.

**No PAM-driven 2FA over SSH.** `pam_u2f` runs in the keyboard-interactive path,
so disabling it removes FIDO2-via-PAM for SSH specifically (console, sudo, polkit
and the greeter are unaffected — they do not go through sshd). The replacement is
native OpenSSH security-key auth: openssh is built `--with-security-key-builtin`
and advertises `sk-ssh-ed25519@openssh.com` and
`sk-ecdsa-sha2-nistp256@openssh.com`, which authenticate over **pubkey** and need
no keyboard-interactive path. `ssh-keygen -t ed25519-sk` is the intended second
factor for SSH.

### Key-only SSH also breaks password-driven *tooling* — override with a lower-numbered drop-in

Third consequence, found in #371: any external tool that drives krytis over SSH with a
password cannot work, including the live-ISO installer test. dakota-iso's E2E gate sets
`liveuser:live` with `chpasswd` and then logs in with `sshpass`; against a krytis live
session that fails, and the failure looks like a boot or network problem rather than a
policy decision:

```
$ ssh -o PreferredAuthentications=none liveuser@127.0.0.1 -p 2224
debug1: Remote protocol version 2.0, remote software version OpenSSH_10.3
debug1: Authentications that can continue: publickey
liveuser@127.0.0.1: Permission denied (publickey).
```

sshd was up and listening the entire time — `10-krytis-auth.conf`'s two `no`s simply left
`publickey` as the only method, so a readiness probe that logs in never succeeds and the
harness reports a timeout. **Read a "SSH timeout" against a krytis guest as an auth-policy
question first, not a boot failure.** Confirm with `PreferredAuthentications=none`, which
makes sshd list the methods it will actually accept.

The intended escape hatch is the one `10-krytis-auth.conf` documents itself: `sshd_config`
`Include`s `/etc/ssh/sshd_config.d/*.conf` at line 2 and first-obtained-value wins for
these keywords, so a **lower-numbered** drop-in overrides the hardened default. For the
live ISO that is a `05-live-debug.conf` written only when the ISO is built with
`--debug`, carrying *both* keywords (`PasswordAuthentication yes` +
`KbdInteractiveAuthentication yes` — the same pairing the hardening needed, for the same
`UsePAM yes` reason). It lands in the live squashfs, never in the payload, so an installed
system stays pubkey-only and a `DEBUG=0` production ISO is unaffected.

Do **not** relax `10-krytis-auth.conf` itself to make tooling work, and do not read this as
a reason to revisit § Priority above: the fix belongs in the debug-only live environment,
which is not a krytis release artifact.
