# PAM & Keyring Skills

## noctalia native SystemPrompter: pinning a fork branch, not a tag — and why gcr-3 is no longer a fallback

`elements/desktop/noctalia.bst` is pinned to `kitten-lily/noctalia`'s
`feat/system-prompter` branch (not upstream `noctalia-dev/noctalia`) for a native
`org.gnome.keyring.SystemPrompter` provider. It went in as an interim step over the
*then*-shipping gnome-keyring backend (PR #574) and shipped for real alongside the oo7
cutover in #594 (2026-08-15); #84 was closed as completed on 2026-09-04. The branch is still unupstreamed. Two non-obvious
mechanics from doing this:

**`git_repo` sources can pin `track:` to a branch name, not just a tag glob.**
BuildStream doesn't care whether the `track:` value resolves to a tag or a
branch ref — `bst source track` follows whatever it names. Pinning
`track: feat/system-prompter` means `bst source track` starts following that
branch's head instead of `v*` release tags, so auto-track PRs land more often
while the pin is in effect. There's history for this exact pattern in this
element already (`fix/wifi-persist-polkit-async`, dropped once upstream
shipped the equivalent fix independently) — same playbook: pin, test, drop
once upstreamed or supersede.

**gcr-3 and gcr-4 coexist without conflict — but gcr-3 is no longer in the image.** The
coexistence finding was real, and it is what made the interim step possible: different
sonames (`libgcr-base-3.so`/`libgcr-3.so` vs `libgcr-4.so`), different D-Bus surface, so
adding `sdk/gcr.bst` (gcr-4) for noctalia's `GcrSecretExchange` link alongside
gnome-keyring's transitive `sdk/gcr-3.bst` broke nothing. **That arrangement lasted one
commit.** The next commit in the same PR (#594) swapped gnome-keyring for oo7 in
`stacks/desktop.bst`, taking gcr-3 — and with it the `gcr-prompter` binary and its
`org.gnome.keyring.SystemPrompter.service` D-Bus activation file — out of the image
entirely. Confirmed against `files/fakecap-manifest.tsv`: `/usr/libexec/gcr-ssh-agent`
and `/usr/libexec/gcr4-ssh-askpass` are present (both from `sdk/gcr.bst`, gcr-4),
`gcr-prompter` is not.

**So noctalia's prompter owns the name outright; it is not a first-come overlay on an
inert fallback.** The handoff mechanic itself still holds — noctalia's `SecretPrompter`
constructor calls `requestName()` and throws if the name is already owned, so it declines
gracefully rather than forcing a takeover — but on krytis there is nothing left to
decline to. If noctalia's prompter is disabled, crashes, or loses a startup race, nothing
answers `org.gnome.keyring.SystemPrompter` at all, and per § *No prompter on the bus means
libsecret callers hang* below that is an indefinite hang in every libsecret caller, not a
degraded mode. Both `elements/stacks/desktop.bst` and `elements/desktop/noctalia.bst`
carry that warning in-tree. The startup race is still a non-issue in krytis specifically:
`files/niri/startup.kdl` only `spawn-at-startup`s `noctalia`, and every manual-unlock
scenario (secondary keyring, `CreateCollection`, `ChangePassword`) is an interactive,
mid-session action — noctalia has been running the whole session by the time any of those
fire.

**`secret_prompter = true` in `/etc/skel` reaches new accounts only — every existing user
silently keeps the prompter off.** `noctalia-skel.bst` says so in a comment ("one-shot copy,
not a synced default: it only reaches newly-created accounts"), and this option is the first
time that limitation has real consequences: an upgraded machine ships the prompter binary,
ships the skel default, and still has nothing owning `org.gnome.keyring.SystemPrompter`.

Observed on a live upgraded system: `~/.local/state/noctalia/settings.toml` carried
`polkit_agent = true` from an older skel copy but no `secret_prompter`, `busctl --user list`
showed no `org.gnome.keyring.*` owner at all, and noctalia was running the whole time. There
is no warning; the feature is simply absent.

Fix per existing account — noctalia's config watcher picks it up live, no restart needed
(verified: the running process acquired the name within ~4s of the file changing, which also
exercises the `syncSecretPrompter` reload path):

```shell
# under [shell] in ~/.local/state/noctalia/settings.toml
secret_prompter = true
```

Confirm with `busctl --user list | grep SystemPrompter` — the owner should be noctalia's PID.

**Verified end to end on a live niri session** (with oo7 as the backend, but the prompter path
is backend-independent): store a secret, `secret-tool lock --collection=Login`, then store
again. noctalia's panel appears, and the daemon log shows an 11-second gap between the client
connecting and `Successfully created item` — the prompt being read and answered — after which
a secret stored *before* the lock read back correctly. So the unlock genuinely restored access
rather than just letting the new write through.

## systemd-homed users: FIDO2 login belonged to homed, not pam_u2f — until #759/#532 retired it

Two independent things broke FIDO2 login for `systemd-homed`-managed users. Both were fixed in #409; keep them straight, because fixing only the first looks plausible and achieves nothing.

**1. `pam_u2f` structurally cannot serve homed *login*.**

In per-user mode (no `authfile=`) pam_u2f builds the path from the passwd entry — `resolve_authfile_path()` in `pam-u2f.c` does `dir = user->pw_dir` + `.config/Yubico/u2f_keys` — and `open()`s it during `pam_sm_authenticate` (`util.c:get_devices_from_authfile`). A homed user's home is an **unmounted encrypted image** at that moment: systemd's `home_activate()` (`src/home/homework.c`) only mounts it *after* `user_record_authenticate()` succeeds. So the `open()` returns `ENOENT` and pam_u2f returns **`PAM_AUTHINFO_UNAVAIL`** (not `PAM_USER_UNKNOWN` — that code is only used when the file parsed fine but held no line for this user). Upstream states the general case outright in pam-u2f's `README.adoc`: an authfile in an encrypted home makes login impossible.

Moving the authfile to a root-owned absolute path *would* make the `open()` succeed (`authfile=/etc/security/u2f_mappings/%u` + `expand`, no `openasuser` → read as root; note `expand` substitutes only `%u` and `%%`, there is no `%h`). **Do not do it.** For homed, the token's `hmac-secret` output *is* the key material that decrypts the home — `fido2_use_token()` in `src/home/homework-fido2.c` derives the LUKS/fscrypt passphrase from it. A `sufficient` pam_u2f success would end the auth stack before `pam_systemd_home` ever ran, landing the user in a session with no home mounted. FIDO2 for homed login is homed's job, via `homectl update <user> --fido2-device=auto` (rp_id `io.systemd.home`).

**Was stale, corrected by #784:** this paragraph used to read "pam_u2f is still right for a homed user's sudo/polkit: by then the home is mounted, so the per-user authfile is readable." True but irrelevant, and not what determines whether pam_u2f actually runs — see the dedicated #784 section below. Authfile *reachability* was never the blocker; module *reachability* was. `mise fido2:enroll` enrolls only this per-user authfile for homed users now (see below) — it used to also enroll a homed login credential, retired by #759/#532.

**Retired by #759/#532 (see the dedicated section below).** homed's own FIDO2 login credential is what this subsection describes, and it worked exactly as designed — but "as designed" turned out to mean *always* trying that credential first, with no way to check the key is present before prompting for its PIN, and no way to let a successful FIDO2-only login also populate `PAM_AUTHTOK` for the keyring. Both are structural to how `pam_systemd_home`/`homework-fido2.c` work, not bugs in this wiring. krytis's answer is to stop enrolling this credential at all: `mise fido2:enroll` no longer creates it and actively removes any it finds, so homed login is password-only and pam_u2f keeps covering that user's sudo/polkit exactly as this section still describes. The mechanics above remain correct background for *why* pam_u2f can never take over login duty either — read them as history, not as the current login story.

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

**Test against a LIVE homed, not just an absent one.** A plain `podman run` has no homed at all, so `pam_systemd_home` takes the *no-bus* path — `acquire_user_record` never reaches homed and returns `PAM_USER_UNKNOWN` early. That is a different code path from the one a real krytis box exercises, where homed **is** running (freedesktop-sdk's `vm/config/systemd-homed-firstboot.bst`, pulled in by `elements/stacks/base-system.bst`; krytis's own `elements/config/systemd-firstboot.bst` only drops a `10-krytis.conf` override on top of it) and returns `BUS_ERROR_NO_SUCH_HOME` for a non-homed user. Both end at `PAM_USER_UNKNOWN`, so `default=ignore` covers both — but proving the second one needs homed actually on the bus. You do not need PID-1 systemd, a VM, LUKS, a loop device, or a security key for that; a rootless container is enough:

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

**Known gap, not a regression — but NOT moot for homed login, contrary to what this section used to say (see #782).** `pam_systemd_home` sets `PAM_AUTHTOK` for downstream modules *only if a password was actually used*. A FIDO2-only homed login therefore left `pam_gnome_keyring`/`pam_oo7` with no token and the keyring locked — the same shape as the pam_oo7 problem below, tracked in #129. #759/#532 close the FIDO2-specific case by retiring the homed FIDO2 login credential entirely, so a homed login is always a password login and `PAM_AUTHTOK` is always set on the pam handle. That much was verified against `pam_systemd_home.c` source. What #759/#532 did **not** fix, and what this file previously claimed it did: `pam_oo7.so`'s own `auth`-phase line *still* never ran for a homed user, because `-auth [success=done …] pam_systemd_home.so` terminated the whole auth phase on success regardless of *why* it succeeded — password or FIDO2 makes no difference to that jump. #782 fixed that separately by moving greetd's jump to `success=1`; see the dedicated section below for the mechanics. The general pam_oo7-needs-a-password gap tracked in #129 still applies to anything else that can authenticate without one.

## #759/#532 — retired the homed FIDO2 login credential; homed login is password-only

**Decision applied 2026-09-07.** Two issues turned out to be the same root cause: #759 (systemd-homed prompts for a FIDO2 PIN before checking the key is even plugged in, both at the greeter and for `sudo`) and #532 (a FIDO2-only homed login leaves the login keyring locked because `pam_unix` never runs to populate `PAM_AUTHTOK`). Both trace to the same thing — a homed user having a FIDO2 *login* credential enrolled at all (`homectl update <user> --fido2-device=auto`, added by #411). Fixing either symptom without removing the credential just trades one bad UX for the other.

**Root cause, source-verified against systemd 261.2** (`src/home/homework-fido2.c:fido2_use_token()`):

```c
if (salt->client_pin > 0) {
        if (strv_isempty(secret->token_pin))
                return -ENOANO;      // returns BEFORE any libfido2 call
        flags |= FIDO2ENROLL_PIN;
}
...
r = fido2_use_hmac_hash(NULL, "io.systemd.home", ...);   // device enumeration happens in here
```

The `-ENOANO` short-circuit fires off enrollment metadata alone — no USB/HID enumeration happens until *after* a PIN has been collected via the pam conversation. Reproduced live (`lily`, homed, `fido2HmacCredential` enrolled, `fido2-token -L` empty):

```
$ sudo -k -v
[sudo] Please confirm presence on security token of user lily.
[sudo: authenticate] Security token PIN: ****
[sudo error] Security token of user lily not inserted.
[sudo: authenticate] Try again with password:
```

There is no `pam_systemd_home(8)` option to change this, and it is not unique to homed — [systemd/systemd#32615](https://github.com/systemd/systemd/issues/32615) is the same ask against `systemd-cryptsetup`, closed as not-easy by Poettering (USB enumeration timing at boot). `pam_u2f`, by contrast, checks device presence (`fido_dev_info_manifest`) before ever prompting for a PIN (`util.c:do_authentication()`) — confirmed empirically too, it never triggered a prompt with no device present.

**Fix: stop enrolling the homed login credential; remove any that already exist.** `files/fido2-tasks/fido2/enroll` no longer runs `homectl update --fido2-device=auto` at all. Instead, if it finds an existing `fido2HmacCredential` on the user's home record (left over from before this decision, or hand-enrolled against the grain), it removes it with `homectl update "$USER" --fido2-device=` — an empty value is homed's remove syntax (`parse_fido2_device_field()` unconditionally calls `drop_from_identity("fido2HmacCredential", "fido2HmacSalt")`, then only re-adds if the value is non-empty). Removal needs **no** account password — unlike enrollment, it does not re-key the LUKS/fscrypt slots (`and_change_password` is only set when `arg_fido2_device` ends up non-empty), so this is safe for a script to do unprompted. Verified live: `homectl update lily --fido2-device=` returned immediately with no prompt, `fido2HmacCredential` was gone from the JSON record afterward, and a follow-up `sudo -k -v` went straight to `Password:` with no PIN/presence detour at all.

**Consequence, accepted deliberately:** systemd-homed users lose "touch key to log in" at the greeter entirely — login is password-only. This is not a new restriction in practice: `config/greetd-config.bst`'s `pam_u2f` line has been commented out since #585 anyway (a different keyring-lock hazard), so the greeter has been password-only for everyone already. What changes is that a homed user's login can no longer even *attempt* FIDO2 and hit the PIN-before-presence detour. `sudo`/polkit are unaffected either way — that FIDO2 factor comes from `pam_u2f` on `system-auth`, a completely separate credential that already does device-presence checking correctly.

**`docs/skills/fido2.md`'s enrollment table drops the homed-login row** accordingly — see that file. No PAM-stack change was needed for any of this: `pam_systemd_home`'s jump line in `greetd`/`system-auth` is unchanged, because the fix is entirely at the enrollment layer (never create the credential that made it try FIDO2 at all).

**Update, #784:** "`sudo`/polkit are unaffected either way" above is true only in the narrow
sense that #759/#532 didn't make anything worse for them — it does not mean pam_u2f actually
worked for sudo/polkit before this decision either. That was a separate, pre-existing bug
(module ordering, not the FIDO2-login-credential issue this section is about) — see the
dedicated #784 section below.

## #782 — pam_oo7's auth phase was still unreachable on homed success, even password-only

**Found 2026-09-09, on a live homed login.** #759/#532 made homed login password-only, and
`docs/skills/pam.md` (this file) claimed that made the pam_oo7-needs-a-password gap "moot" for
homed users. It didn't check the actual `Locked` property. It was still `b true` for the whole
session:

```
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked
b true
```

Audit trail for the login showed why: `op=PAM:authentication grantors=pam_systemd_home` —
`pam_unix` and `pam_oo7` are absent from the grantor list. The greetd auth stack read, at
that point (the relevant lines only — `auth required pam_nologin.so` sits above them):

```
-auth  [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
auth   required   pam_unix.so
auth   optional   pam_oo7.so
```

`success=done` terminates the **entire** auth phase immediately on any homed success —
password or FIDO2 makes no difference to that jump, so retiring the FIDO2 credential in
#759/#532 never touched this. `pam_unix.so` and `pam_oo7.so`'s auth line simply never execute
for a homed user.

**Why that breaks the unlock even though `PAM_AUTHTOK` gets set.** Source-verified against
`systemd/src/home/pam_systemd_home.c:acquire_home()`: on a successful password login it does
call `sym_pam_set_item(pamh, PAM_AUTHTOK, *secret->password)`, so the token really is on the
pam handle. But oo7's session-phase module (`session optional pam_oo7.so auto_start`) does not
read `PAM_AUTHTOK` live — per the existing note below (§ pam_oo7: null PAM_AUTHTOK does not
unlock, and `pam/src/lib.rs`), `pam_sm_open_session` looks for a stash that `pam_sm_authenticate`
creates for the transient login helper. If the auth-phase module never runs, there is nothing to
stash, and `auto_start` only starts the daemon — it can't unlock with a token it never receives.

**Fix: `success=1`, not `success=done`.** PAM's numeric skip action skips exactly N modules
that follow, then continues the stack — unlike `done`, which ends the phase outright. With
`pam_unix.so` as the only module between `pam_systemd_home.so` and `pam_oo7.so`, `success=1`
skips just that one (same as `done` did — a homed user's password is already verified by
homed, and nss_systemd would let `pam_unix` pass too via the privileged hash, so re-running it
is redundant at best) and falls through naturally to `pam_oo7.so`, which is the last real line
in the stack anyway. Net effect: `pam_unix.so` still never runs for a homed login (unchanged
behavior), and `pam_oo7.so` now does (the fix).

**Scope note: the password stack has the identical shape and was deliberately left alone
here.** `-password sufficient pam_systemd_home.so` also short-circuits past
`-password optional pam_oo7.so` on a homed password change (`sufficient` ≈
`[success=done new_authtok_reqd=done default=ignore]`) — so a homed user who changes their
password via `homectl`/`passwd` would have their login keyring silently left encrypted under
the *old* password, re-locking it on every subsequent login. Same mechanism, different
trigger (password change, not login), not verified live, and not part of #782's fix. Worth its
own issue if anyone hits it.

## #784 — pam_u2f was unreachable for sudo/polkit too, via the same `success=done` short-circuit

**Found 2026-09-09, right after #782, on the same live system.** A homed user's `sudo su` went
straight to a password prompt with **no FIDO2 attempt at all**, despite a key enrolled
(`mise fido2:status` showed `lily: 1 key(s)` under pam_u2f). `docs/skills/pam.md` (this file,
line 79 as it read before this section) claimed pam_u2f "is still right for a homed user's
sudo/polkit: by then the home is mounted, so the per-user authfile is readable." Never
checked live.

Journal correlated exactly with the `sudo` attempt:
```
systemd-homed: lily: changing state active → authenticating-for-acquire
systemd-homework: Discovered used LUKS device /dev/mapper/home-lily, and validated password.
systemd-homework: Successfully re-activated LUKS device.
systemd-homed: Home lily is signed exclusively by our key, accepting.
```
`pam_systemd_home` was doing full homed/LUKS verification on every `sudo` call —
`pam_u2f` never got a turn.

**Root cause: same `success=done` short-circuit as #782, different file
(`elements/config/u2f-config.bst`'s `system-auth`/`password-auth`), different mechanism.**
`pam_systemd_home` ran *first*, ahead of `pam_u2f.so`:
```
-auth  [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
auth   sufficient   pam_u2f.so cue pinverification
```
For a homed user it always succeeds via password (no homed FIDO2 login credential exists
post-#759/#532), and `success=done` ends the whole auth phase immediately — `pam_u2f.so`, the
very next line, never runs. Unlike #782, there was nothing to skip *past* to reach it —
`pam_u2f.so` was already the immediately-following module, so a numeric `success=N` skip
would not help here. The fix is a **reorder**, not a skip-count change.

**Fix: `pam_u2f.so` now runs before `pam_systemd_home.so`.**
```
auth   sufficient   pam_u2f.so cue pinverification
-auth  [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
```
Safe on all three paths this stack serves, verified against each:

- **sudo/polkit** (home already mounted): `pam_u2f` now actually gets a chance and can succeed
  alone on a key touch — the intended UX, previously impossible for any homed user.
- **console `login`** (home not yet mounted): per § *pam_u2f structurally cannot serve homed
  login* above, `pam_u2f`'s per-user authfile lives inside the still-unmounted home, so
  `open()` fails with `ENOENT` → `PAM_AUTHINFO_UNAVAIL` regardless of stack position. It falls
  through to `pam_systemd_home` exactly as before. `pam_u2f` also checks device presence
  (`fido_dev_info_manifest`) before ever prompting for a PIN, so reordering does not
  reintroduce the PIN-before-presence detour #759/#532 removed.
- **classic (non-homed) users**: `pam_systemd_home` returns `PAM_USER_UNKNOWN` →
  `default=ignore` → falls through to `pam_unix` exactly as before; `pam_u2f` running first
  changes nothing for them since it already ran before `pam_systemd_home` in relative terms —
  the only line that moved is `pam_systemd_home`'s.

**Why `system-auth` keeps `success=done` while `greetd` moved to `success=1` (#782).** The two
stacks now differ deliberately. `greetd` needs the phase to *continue* after a homed success so
`pam_oo7.so` gets its auth turn; `system-auth`/`password-auth` have no pam_oo7 line at all, and
everything after `pam_systemd_home.so` there (`pam_unix.so`, `pam_deny.so`) is exactly what a
successful homed auth should skip. Do not "harmonise" the two jump specs — see #782 above for
what `success=1` is buying, and note that its skip count is tied to `pam_unix.so` being the one
module between homed and oo7.

**Not covered by this fix: `greetd`.** No reorder was applied there because `pam_u2f` is
commented out entirely (#585, unrelated keyring-lock hazard) — nothing to reorder. If #585 is
ever resolved and pam_u2f re-enabled at the greeter, the unmounted-home fail-closed behavior
should make its position moot (same reasoning as the console-`login` bullet above), but verify
live before assuming — and mind #782's `success=1`: re-inserting `pam_u2f.so` *between*
`pam_systemd_home.so` and `pam_unix.so` would silently change which module the skip count
lands on, letting `pam_unix.so` run on homed success instead of being skipped.

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

**New gap found via oo7#506** (2026-08-03 comment, not previously documented here): the *unlocked* Login collection can re-lock with **no explicit `Lock()` call** if `oo7-daemon.service` restarts mid-session — the one-shot PAM helper's memfd doesn't survive the restart, and there is no FD-store/credential-based resume yet. Reporter's trigger was a package update restarting the daemon without ending the session. Lower risk for krytis specifically since bootc updates are reboot-driven rather than live in-place restarts, but still applies to `systemctl --user restart oo7-daemon` or a crash-restart mid-session. oo7 shipped in #594 and #84 is closed, so this is a live property of the image, not a hypothetical — it is still not covered by a boot-test scenario.

**Three corrections, carried into the #594 cutover** (upstream `pam/README.md`, read 2026-08-12; written while #84 was still open, kept because each one is still the live answer):
- ~~The PAM socket is `$XDG_RUNTIME_DIR/oo7/pam.sock` (`OO7_PAM_SOCKET`-configurable) — not `oo7-pam.sock` as ArchWiki has it.~~ **Wrong — corrected 2026-08-12.** ArchWiki was right. The socket is `/run/user/<uid>/oo7-pam.sock`, still `OO7_PAM_SOCKET`-configurable. Verified three ways: read from source on **both** the 0.6.0 tag (`server/src/pam_listener/mod.rs:59`, `pam/src/socket.rs:195`) and current `main` (`server/src/pam_listener/mod.rs:100`, `pam/src/socket.rs:273`) — both sides hardcode the same `format!("/run/user/{uid}/oo7-pam.sock")` default — and observed at runtime on a built krytis image: `INFO oo7_daemon::pam_listener: PAM listener started on /run/user/1000/oo7-pam.sock`. The daemon and the PAM module agree, which is what actually matters; the earlier note would have sent a debugger to a path that never exists.
- Upstream's own `password` stack example is `password optional pam_oo7.so`, with **no `use_authtok`**. This was the correction to make: the gnome-keyring line it replaced was `-password optional pam_gnome_keyring.so use_authtok`, and `config/greetd-config.bst` now ships `-password optional pam_oo7.so` with no `use_authtok` and a comment saying why (pam_oo7's password-stack path captures old+new tokens itself; `use_authtok` would only constrain where it may read from).
- oo7 ships no ssh-agent component at all (repo layout: cargo-credential, cli, client, git-credential, pam, portal, server, kwallet — no ssh_agent crate). This was never "a different SSH_AUTH_SOCK path to switch to", and after the cutover the agent is still gcr's — `/usr/libexec/gcr-ssh-agent` from gcr-4 (`sdk/gcr.bst`), reached transitively via `desktop/noctalia.bst`, listening on `/run/user/<uid>/gcr/ssh`. See `docs/skills/fido2.md` § Point `user.signingkey` at the handle file.

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

### 2026-09-08 investigation: "keyring won't unlock" — cause missed, corrected 2026-09-10

> **CORRECTION (2026-09-10).** The eliminations below are sound and worth keeping. The
> **headline is wrong.** The locked login collection was never explained by the
> `podman-restart.service` subuid noise — that is a real but entirely separate bug with no
> connection to the keyring. The actual cause is the `oo7-daemon-login` handoff race in
> § *Login auto-unlock is lost to a race between `oo7-daemon.service` and `pam_oo7`'s login
> helper* below, which has broken auto-unlock on **every fresh-boot login since 2026-08-14**.
>
> Why it was missed: ruling out a mid-session daemon restart (correctly) left exactly one
> hypothesis standing — *it was never unlocked in the first place* — and that hypothesis was
> never tested. The single log line that settles it is the daemon-side
> `oo7_daemon::pam_listener: Received unlock request for user:`, and the investigation only
> ever read the **pam-side** `Successfully sent secret to oo7 daemon`, which is emitted
> unconditionally and is false on the helper path. Checking a success claim against the
> receiver's own log, not the sender's, is the habit that would have caught it.

Investigated a live-system report of `gh auth status` intermittently seeing the login
collection as locked. Journal evidence from a fresh boot (`journalctl -b`), ruling things in
and out:

- **`oo7-daemon.service` did not restart mid-session** (`systemctl --user status` showed a
  single PID since login, `Invocation` ID unchanged) — the documented oo7#506 "unlocked
  collection re-locks with no explicit `Lock()` call on daemon restart" gap above does **not**
  apply to this instance.
- **No residual homed FIDO2 login credential** — `mise fido2:status` reported `lily: none`
  under "systemd-homed login credentials", confirming #759/#532's retirement (see below) is
  correctly applied on this account. Ruled out as a cause.
- **The greeter's first `pam_systemd_home` "failure" in the log is not a failure** — it is
  greetd's normal `create_session` handshake (auth attempted with no credential yet, homed
  replies "None of the supplied plaintext passwords unlock…", greetd relays the `Password:`
  prompt, the real password arrives via `post_auth_data` and succeeds a second later). Do not
  mistake this pair of lines for an authentication regression.
- **Real bug found, unrelated to the keyring:** at every login, `podman[…]: cannot find
  UID/GID for user lily: no subuid ranges found for user "lily" in /etc/subuid` — logged by
  the user's own `podman-restart.service`/`podman-auto-update.service` (started automatically
  at session start). The identical line repeats for `greeter` moments later when the greeter
  session tears down. Same root cause as `docs/skills/ci-runner.md` § Rootless podman
  subuid/subgid, except this fires unconditionally on **every boot for every account**, not
  just when a contributor happens to run `mise run runner/build`/`renovate-check`. Neither
  `lily` nor the `greeter` service account had a `/etc/subuid`/`/etc/subgid` entry on this
  system — systemd-sysusers/homed account creation does not assign one the way classic
  `useradd` does. **Fixed image-side in #780** (`elements/config/subuid-provision.bst`,
  `krytis-subuid-provision.service`) — see the dedicated entry below for what that fix
  covers and the UID-range gap in it that #852 closed.
- **Separate, noisy-but-likely-harmless bug found in passing:** every `sudo` invocation spins
  up a full `user@0.service` (root's own systemd user manager) that tries to start
  `oo7-daemon.service` for root and crash-loops it 5× in under a second — `Capability error
  Operation not permitted (os error 1)` — before hitting `start-limit-hit`. Root has no
  practical use for a Secret Service, so this is journal noise on every `sudo` call rather
  than a functional break, but it points at `oo7-daemon`'s systemd unit not handling uid 0
  cleanly. Not investigated further.

## `krytis-subuid-provision.service` excluded every systemd-homed account — the exact population it was built for (#852)

**Found 2026-09-15**, re-reading `files/subuid-provision/subuid-provision.sh` (added in #780
/ commit `9bb344b`, see the investigation above) while diagnosing an unrelated SSH wedge
(#848). The service's own commit message says it exists because a homed user hit "no subuid
ranges found" — but the script only ever provisioned accounts inside `UID_MIN..UID_MAX` from
`/etc/login.defs`, which krytis never overrides from the shadow-utils stock default:
`UID_MIN=1000`, `UID_MAX=60000`. systemd-homed's own reserved "regular home user" range —
visible via `userdbctl`'s boundary markers ("begin/end systemd-homed users") — starts at
**UID 60001**, one past that ceiling. So the range check silently skipped every homed
account, every boot, since the feature merged: the fix never actually fixed the case it was
written for.

**Fix:** a second branch for UIDs at or above 60001, gated on `userdbctl user <name>
--output=json` reporting `"disposition": "regular"` — the same field that distinguishes a
real homed identity from an NSS-only pass-through account (system services, `DynamicUser=yes`
units report no disposition at all here, so they fall through unassigned same as before).
Needs its own subuid anchor too: reusing the classic formula's `sub_uid_min=100000` base with
a ~60000 UID offset overflows `SUB_UID_MAX` almost immediately
(`(60001-1000)*65536 ≈ 3.9 billion` against a 600 million ceiling) — anchor on systemd's
separately-reserved "container users" range floor instead (524288, also visible via
`userdbctl`'s boundary markers), which has over a billion UIDs of headroom for the ~500-UID
homed range.

**Why not just extend `UID_MAX`:** the systemd-homed range (60001-60513) isn't contiguous
with the classic range and isn't guaranteed to stay a fixed width — querying `userdbctl` for
the property that actually means "this is a human login account" is correct regardless of
where systemd places the numeric boundary, rather than re-encoding a second hardcoded range
and hoping it never drifts.

**Verified** by dry-running the selection+arithmetic against this workstation's real
`getent passwd`/`userdbctl` output (a systemd-homed account, UID 60339) and against synthetic
passwd lines covering a classic account, a homed-range UID with no userdb record, and a
system account — each selected/excluded exactly as expected, with the homed account's
computed range matching the anchor formula by hand.

## Login auto-unlock is lost to a race between `oo7-daemon.service` and `pam_oo7`'s login helper

**Symptom.** After an ordinary password login the `login` collection is locked for the entire
session. Every libsecret caller is told the secret does not exist rather than being offered an
unlock (krytis#585 — there is no oo7#585; this cited the wrong tracker until #860), so `gh` fails with `HTTP 401`, `flatpak` logs `Unable to unlock default
keyring`, and nothing in the journal reads as an error — `pam_oo7` reports success.

**Confirmed on hardware 2026-09-10** against oo7 pinned at `da576e43`. The window is ~38 ms:

|Time (`journalctl -b`)|Event|
|---|---|
|`17.021573`|user manager, just spawned by `pam_systemd.so`, starts `oo7-daemon.service` (`WantedBy=default.target`)|
|`17.022609`|`pam_oo7.so auto_start` — the **next module in the same stack** — connects `/run/user/1000/oo7-pam.sock`|
|`17.022621`|`Socket not found, starting login helper`|
|`17.022960`|`oo7-daemon-login` forked|
|`17.023235`|`Successfully sent secret to oo7 daemon for user: lily` — **false**|
|~`17.060`|daemon's one-shot connect to the helper's socket fails, silently|
|`17.060742`|daemon binds `oo7-pam.sock` — 38 ms after `pam_oo7` gave up|
|`17.062261`|`Setting up collection 'login'` — locked, and stays locked|

**Neither side retries, and the failure is silent on both.**

- `pam/src/socket.rs`: `Err(e) if auto_start && e.kind() == NotFound => { start_login_helper(…)?; return Ok(()) }`. Fire-and-forget — it then reports success to PAM whether or not anything ever collects the secret.
- `server/src/main.rs`: `read_secret_from_login_helper()` runs **once**, inside `inner_main` ahead of `Service::run`. Its failure arm is `Err(_) => return None` — no log, no retry. Absence of `Connected to login helper at …` in the daemon's log is the only trace.
- `server/src/login.rs`: the helper binds `/run/user/<uid>/oo7-daemon-login.sock` and polls for `HELPER_TIMEOUT_SECS = 120`, then logs `Timed out after 120s, no daemon connected` and exits 0. **That log never reaches the journal** — the helper is `execv`'d from greetd's PAM child with stderr discarded, so the process leaves no trace at all. Do not conclude from a silent journal that the helper never ran.

So the secret is handed to a helper the daemon has already stopped looking for.

**This is not intermittent, it only looks that way.** `Socket not found, starting login helper`
appears on every fresh-boot login from 2026-08-14 onward. On the same machine the daemon logged
`pam_listener: Received unlock request for user: lily` exactly twice across four weeks of boots
— both times on re-logins into a boot where `user@1000` still lingered, so `oo7-pam.sock`
already existed and `pam_oo7` took the direct path (`Connected to daemon socket`, no helper, no
race). **Same-boot re-logins work; first login after a boot never does.**

Builds before 2026-08-14 had a fallback that worked: `Socket not found, attempting to start
daemon` → poll → `Connected to daemon socket` ~100 ms later. Upstream replaced that
start-and-wait with the fire-and-forget helper; that is the regression.

**Triage in one command** — check the *receiver's* log, never `pam_oo7`'s success claim:

```shell
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login \
  org.freedesktop.Secret.Collection Locked          # b true  => never unlocked
journalctl --user -b -u oo7-daemon.service | grep pam_listener
```

`PAM listener started on …` alone means no secret ever arrived. A working login also shows
`Received unlock request for user:` and `Unlocked collection:`.

**Do not "fix" this by restarting the daemon.** `systemctl --user restart oo7-daemon` cannot
help: there is no secret left anywhere to pick up, and per oo7#506 a restart drops unlocked
state anyway. Mid-session recovery is the interactive prompter only.

Ordering `pam_oo7` **before** `pam_systemd` is not a fix either: `/run/user/<uid>` does not
exist until logind registers the session, so the helper would have nowhere to bind.

### The fix krytis ships (#806)

Two halves, deliberately independent, because either can be lost on its own:

- **`patches/oo7/login-helper-connect-retry.patch`** — replaces the daemon's single connect
  with a bounded 500 ms retry (`connect_to_login_helper`), and logs the give-up at debug
  instead of swallowing it. This is the half that would go upstream; it is carried downstream
  first to verify in real use (Upstream Gate). If it stops applying after an oo7 re-pin, check
  whether upstream has grown its own retry before re-basing it.
- **`oo7-daemon.service.d/10-krytis-login-helper-wait.conf`**, installed by
  `elements/desktop/oo7.bst` — an `ExecStartPre` that waits up to 500 ms for
  `%t/oo7-daemon-login.sock`. Ordering at the unit level, so the guarantee survives an oo7
  bump that silently drops the patch.

500 ms is an order of magnitude more than the observed 38 ms skew. The two budgets stack only
when no helper is coming at all — a manual `systemctl --user restart oo7-daemon` pays up to 1 s
before the bus name appears. Nothing blocks on that unit, and the login path pays neither,
because the helper binds within tens of milliseconds.

### `mise run oo7-login-race-test` gates it

The symptom is invisible — no error is logged on either side, and a same-boot re-login masks
it entirely — so this is a task on the built artifact, not an investigation to redo. It makes
the daemon *win* the race deliberately: the daemon starts first, the helper appears 150 ms
later. That is well outside a single connect attempt and well inside the 500 ms budget.

Unpatched artifact:

```
==> FAIL: daemon never received the login secret (krytis#806)
    helper log:
      INFO oo7_daemon_login: Listening on /run/user/1000/oo7-daemon-login.sock
      INFO oo7_daemon_login: Timed out after 120s, no daemon connected
==> login collection Locked = b true
```

Patched artifact:

```
    INFO oo7_daemon: Connected to login helper at /run/user/1000/oo7-daemon-login.sock
    INFO oo7_daemon: Received login secret from helper
==> PASS: daemon collected the secret despite winning the race
==> login collection Locked = b false
==> oo7-login-race-test passed.
```

Two traps the task had to work around, both worth knowing before writing anything similar:

- **`OO7_PAM_SOCKET` is mandatory for isolation.** Without it the daemon under test binds the
  real `/run/user/<uid>/oo7-pam.sock`, unlinking the live daemon's listener and breaking PAM
  handoff for the rest of the boot. `XDG_DATA_HOME` alone is not enough. The rendezvous socket
  `oo7-daemon-login.sock` has no such override — both binaries hardcode it — so the task
  refuses to run when one already exists and removes its own on exit.
- **Waiting for the bus name is too early.** The daemon owns `org.freedesktop.secrets` before
  `Service::run` has set the login collection up, so a name-only wait reads back
  `Unknown object '/org/freedesktop/secrets/collection/login'`. Poll the property itself.

## oo7's collection path: `Login` on 0.6.0, `login` from 0.7.0.alpha

**Version-specific — check before hardcoding either.** On **0.6.0** oo7 derived the collection
object path from the keyring *label*, giving `/org/freedesktop/secrets/collection/Login` with a
capital L. **0.7.0.alpha uses lowercase `login`**, matching gnome-keyring, and logs
`Setting up collection 'login' (alias: default)` at startup.

**krytis is on the lowercase one.** `elements/desktop/oo7.bst` tracks `refs/heads/main`
(`ref: v0.6.0-alpha-256-g886813eb…`; that describe prefix is misleading — 0.7.0.alpha is a
lightweight tag git-describe ignores, and the element says so), which is well past
0.7.0.alpha. So on a current image the path is `/org/freedesktop/secrets/collection/login`
and `secret-tool lock --collection=login`, which is what every command elsewhere in this
file uses. **The rest of this section is the 0.6.0 behaviour, kept as version history** —
read `Login` as `login` when running any of it against a current krytis, and read the
capital-L examples as what you will see if you ever attach to a 0.6.0-pinned image.

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

## oo7's prompter detection, and the patch krytis no longer needs

oo7 chooses between the GNOME prompter (`org.gnome.keyring.SystemPrompter`) and a CLI
prompter. When it guesses wrong, every libsecret caller gets:

```
CLI prompter failed: NameHasNoOwner: Name "org.freedesktop.secrets.CliPrompter" does not exist
```

krytis ships only oo7's `server/` and `pam/` sub-projects, not `cli/`, so nothing ever owns
that name — picking `Cli` is always fatal here, never merely suboptimal.

The old text here claimed this could not be dodged by starting the daemon later, "because the
daemon must already exist to take the login secret from the transient `oo7-daemon-login`
helper." **That is backwards, corrected 2026-09-10.** The daemon connects to the *helper*, once,
at its own startup (`server/src/main.rs`, `read_secret_from_login_helper()` ahead of
`Service::run`), and the helper holds the secret for 120 s (`server/src/login.rs`,
`HELPER_TIMEOUT_SECS`). A *modest* delay on `oo7-daemon.service` — just enough to let the helper
bind — therefore costs nothing and is one of the candidate fixes for the race in § Login
auto-unlock is lost to a race … above. Only a delay past 120 s would actually lose the login
secret.

**oo7 has now got this wrong twice, in two different ways. krytis patched the first, and
upstream fixed the second — so the tree carries no prompter-detection patch today.** All
three attempts below are history; what survives is `mise run oo7-prompter-test`, the gate.

### Attempt 1 — the daemon's own environment (`0.7.0.alpha`)

Detection read `DISPLAY`/`WAYLAND_DISPLAY` from the daemon's own process environment. Those
arrive only when the compositor imports them into the systemd user manager, but
`oo7-daemon.service` is `WantedBy=default.target`, so the manager starts it at session open —
concurrently with the compositor. A service inherits the manager environment *at start*, so
the daemon spent the whole session believing it was headless.

### Attempt 2 — the peer's logind session (upstream `9f4de634`, closing oo7#530)

Upstream replaced that with the *calling client's* session type, resolved via logind
`GetSessionByPID` → `Session.Type`. Better in principle — it answers per-caller, so a real tty
client correctly gets a CLI prompter — but **it resolves to nothing at all on a
systemd-managed session**, which is exactly what krytis runs.

A login session's cgroup (`session-N.scope`) holds only the session *leader*. The compositor
and everything it launches are user units under `user@<uid>.service`, outside that scope, so
logind cannot attribute them:

```
$ loginctl show-session 8 -p Scope -p Type
Scope=session-8.scope
Type=wayland
$ cat /proc/$(pgrep -x niri)/cgroup
0::/user.slice/user-1000.slice/user@1000.service/session.slice/niri.service
$ busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager GetSessionByPID u $(pgrep -x niri)
Call failed: PID 39347 does not belong to any known session
```

Measured on a booted krytis system: the lookup succeeds **only** for PIDs inside
`session-8.scope` (greetd's `--session-worker`, → `"wayland"`) and fails for `niri`,
`noctalia` and `oo7-daemon` alike. `SessionType::from_logind` returns `None`,
`.unwrap_or(SessionType::Unspecified)` makes it non-graphical, and the CLI prompter is chosen
again. There is no environment fallback left in `server/src/` — the rework deleted every
`DISPLAY`/`XDG_SESSION_TYPE` reference.

**Generalise this beyond oo7:** `GetSessionByPID` is the wrong question to ask about a client
of a systemd user session. Any daemon that branches on it will mis-classify every graphical
app on a session where the compositor is a user unit (krytis, GNOME OS, uwsm-style setups).
`loginctl show-session -p Scope` versus the client's cgroup is the two-command check that
settles it.

### Attempt 3 — upstream fixed it, and krytis's patch is gone (2026-08-27)

krytis carried `patches/oo7/prompter-detect-session-type.patch` from 2026-08-16 until
2026-08-27, adding a `SessionType::from_env()` fallback that read `XDG_SESSION_TYPE`.
**It was deleted in #647 and that path no longer exists in the tree.** Upstream solved the same problem, better, in `f6a8624a`
("server: detect graphical sessions under systemd --user compositors", oo7#558).

`SessionType::detect()` now cascades, stopping at the first check that places the peer in a
session at all:

| step | source | why it exists |
|---|---|---|
| `from_logind(pid)` | `GetSessionByPID` | correct when the peer really is in a session scope |
| `from_environ(pid)` | `/proc/<pid>/environ` | per-peer `WAYLAND_DISPLAY`/`DISPLAY`, no logind needed |
| `from_systemd_user_environment()` | systemd `--user` manager's exported environment over D-Bus | session-wide last resort — exactly krytis's case |

Upstream's is strictly better than what krytis carried: it asks the *peer* first
(`/proc/<pid>/environ`) and only falls back to a session-wide answer, where krytis's patch
jumped straight to the daemon's own `XDG_SESSION_TYPE`. Their third step's doc comment
describes krytis's setup almost verbatim — "systemd-integrated compositors import
`WAYLAND_DISPLAY`/`DISPLAY` into it on startup … only consulted once `logind` can't place the
peer anywhere".

**How the patch's removal was noticed:** it stopped applying, and the `track-oo7` CI job went
red. A patch that suddenly refuses to apply is worth reading as a signal that upstream
reworked the same code, not just as a rebase chore — here the right move was to delete it,
not rebase it for a third time.

### What krytis used to carry

The patch added `SessionType::from_env()` (reading `XDG_SESSION_TYPE`, set by pam_systemd at
session open and inherited by the user manager) and used it **only** as a fallback:
`from_logind(pid).unwrap_or_else(SessionType::from_env)`. Kept here because the reasoning
still explains why the naive fix is wrong, and because the tty case below still applies.

| peer resolution | session type | prompter chosen |
|---|---|---|
| logind resolves the peer (tty scope) | `Tty` | `CliPrompter` |
| logind fails, `XDG_SESSION_TYPE=wayland` | `Wayland` | `BeginPrompting` → `org.gnome.keyring.SystemPrompter` |
| logind fails, `XDG_SESSION_TYPE` unset | `Unspecified` | `CliPrompter` |

Consequence worth knowing: an **ssh** client *does* land in a real session scope, so it now
resolves to `Tty` and gets the `CliPrompter` error instead of raising noctalia's panel on the
local desktop. That is upstream's intent and arguably correct; it is a behaviour change from
the attempt-1 patch, and it only bites if a secret is requested over ssh.

### `mise run oo7-prompter-test` gates it

Because oo7 has now broken this twice and then fixed it once, all via unrelated mechanisms,
the check is a task rather than an investigation. It runs the built `oo7-daemon` on a private
D-Bus session (`dbus-run-session`) with its own `XDG_DATA_HOME`/`XDG_RUNTIME_DIR`, stands a
stub in noctalia's place as the owner
of `org.gnome.keyring.SystemPrompter`, and stores a secret into the fresh (locked) `login`
collection to force a prompt. A pass is the stub being called; a fail is `CliPrompter`
appearing in the daemon or client log.

The isolation matters: it never takes `org.freedesktop.secrets` on the real session bus and
never locks the live login collection — which would make every read return "no such secret"
for the rest of the session (#585).

Measured A/B on the `c2aa2315` artifact, same session, only the patch differing — this is the
historical record from when the patch was still needed:

```
# without patches/oo7/prompter-detect-session-type.patch
==> FAIL: the GNOME prompter was never called
==> FAIL: daemon fell back to the CLI prompter (krytis#588)
    secret-tool: org.freedesktop.DBus.Error.Failed: CLI prompter failed:
    org.freedesktop.DBus.Error.NameHasNoOwner: Name
    "org.freedesktop.secrets.CliPrompter" does not exist

# with it
==> PASS: oo7-daemon reached org.gnome.keyring.SystemPrompter
```

**Current state, 2026-08-27, at ref `e830f53d` with no patch at all:**

```
==> Session: XDG_SESSION_TYPE=wayland
==> PASS: oo7-daemon reached org.gnome.keyring.SystemPrompter
==> oo7-prompter-test passed.
```

That is what made dropping the patch safe rather than hopeful: the same task that proved the
patch was *needed* now passes without it. Keep the task — it is the regression gate for a
behaviour upstream has already broken twice, and its value does not depend on krytis carrying
a patch.

krytis#588 was closed on this, 2026-08-27. The Upstream Gate note that used to sit here — reporting
the gap to oo7 needing an explicit go-ahead — is moot: upstream found and fixed it
independently in oo7#558.

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

**Shipped anyway, deliberately (2026-08-14).** krytis moved to oo7 with this bug accepted, on the basis that FIDO2 login is disabled so `pam_oo7 auto_start` unlocks at login and the collection is never locked in normal use. That removes the *usual* route to a locked collection, not the only one: a mid-session `systemctl --user restart oo7-daemon`, an explicit `secret-tool lock`, or an oo7 crash all re-lock it, and from that point every read is a silent "no such secret" until the session restarts. **When triaging "my saved passwords vanished", check `Locked` on the collection first.** See `docs/design/secrets-service.md` § *Decision* — for the accepted-risk table and the exit conditions.

## Manual unlock on niri needs a GCR SystemPrompter — and since #594 nothing upstream provides one

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

**krytis used to ship `gcr-prompter` transitively; since #594 it does not.** `gnome-keyring.bst` (`gnome-build-meta.bst:core/gnome-keyring.bst`) has a **runtime** `depends: sdk/gcr-3.bst` (checked against the staged junction source, not a local grep — see AGENTS.md's transitive-dependency warning), and that is how `gcr-prompter` reached the image for as long as gnome-keyring was the Secret Service. #594 replaced gnome-keyring with oo7 in `stacks/desktop.bst` and deliberately did **not** add `sdk/gcr-3.bst` back, so gcr-3 and `gcr-prompter` are out of the image — confirmed against `files/fakecap-manifest.tsv`, which carries no `gcr-prompter` binary. The hazard this paragraph used to warn about was real (gh178's plan never mentioned the dependency, so that attempt would have shipped a silently-failing manual-unlock path); it was closed not by re-adding gcr-3 but by shipping noctalia's native provider in the same PR. See § *Writing an `org.gnome.keyring.SystemPrompter` provider* below.

**`gcr-4` (`sdk/gcr.bst`) is not a substitute for `gcr-3` here — by upstream design, not by accident.** GCR's own `NEWS` file says it outright: `gcr 3.90.0` — *"All deprecated API has been removed, as well as most UI-related code."* / `gcr 3.92.0` — *"gcr4 will no longer ship UI libraries, i.e. gcr-gtk3 or gcr-gtk4."* Confirmed by diffing the actual tarballs krytis's junction pins (`gcr-4.4.0.1.tar.xz` vs `gcr-3.41.2.tar.xz`): GCR3 has a `ui/` directory that builds `executable('gcr-prompter', 'gcr-prompter-tool.c', …)` plus `gcr/org.gnome.keyring.SystemPrompter.service.in` (`Exec=@libexecdir@/gcr-prompter`) — a generic, D-Bus-activatable, desktop-agnostic prompter binary. **GCR4 dropped the `ui/` directory and the `.service.in` file entirely**, keeping only the library-side base class (`gcr-system-prompter.c`/`.h`, exposed as `Gcr.SystemPrompter`) and the D-Bus interface XML.

**The prompter didn't disappear in GCR4 — it moved into each desktop shell, which is the part that matters for niri.** `gnome-shell`'s `js/ui/components/keyring.js` subclasses `Gcr.SystemPrompter` directly: `class KeyringPrompter extends Gcr.SystemPrompter`, and `enable()` calls `Gio.DBus.session.own_name('org.gnome.keyring.SystemPrompter', …)` itself — gnome-shell *is* the D-Bus service under real GNOME, built on top of GCR4 as a library, not a separate process. KDE Plasma has its own equivalent (this is exactly why oo7's `Plasma` prompter type is a separate code path from `GNOME` in `prompt/mod.rs`). **niri has no such component.** There is no third-party or generic shell-level `Gcr.SystemPrompter` implementation for wlroots/smithay compositors — the only thing standing in for it is the legacy GCR3 `gcr-prompter` binary, which upstream GNOME itself no longer builds by default (GCR4 is what ships in current GNOME; GCR3 survives only as a compatibility package for consumers like gnome-keyring that still need the old prompter binary — krytis was one of those until #594, and is not any more).

**This is not a theoretical risk — it is a confirmed, still-open failure mode on a structurally similar non-shell compositor** (re-checked 2026-09-24). [pop-os/cosmic-epoch#3453](https://github.com/pop-os/cosmic-epoch/issues/3453) (COSMIC, wlroots-adjacent, no gnome-shell) reports exactly this: `gcr-prompter` (GCR3) *is* installed and its `.service` file *is* present, login-time PAM auto-unlock works fine, but a **mid-session** daemon restart (e.g. a package upgrade) leaves the login keyring locked with no path back — the prompter fails to activate in COSMIC's session D-Bus environment (reporter's suspected cause: missing `WAYLAND_DISPLAY`/`DISPLAY` in the D-Bus activation environment, unconfirmed), `gnome-keyring-daemon` times out after ~25s waiting on `create system prompt`, then **crashes**, leaving the libsecret caller wedged forever rather than returning a clean error. This downgrades the "Low risk" framing in the section above — the env-timing hazard is real and reproduced in the wild on a peer environment, not just theoretically low-probability from `import-environment` timing. **The boot test this asks for is still owed**, and post-#594 it is a test of noctalia's prompter, not of gcr-prompter or gnome-keyring: lock a non-login collection, restart `oo7-daemon` mid-session, and confirm an unlock panel actually appears rather than hanging.

**Longer-term architectural question, since answered by building one.** The reasoning above lands on "krytis would depend indefinitely on a component upstream GNOME has already deprecated in favour of shell-owned prompters", and the answer krytis took was to stop depending on it: noctalia reimplements the small `org.gnome.keyring.SystemPrompter` D-Bus surface itself and links only `GcrSecretExchange` from gcr-4 — see § *Writing an `org.gnome.keyring.SystemPrompter` provider* below. What stays true is the *diagnosis*: there is still no third-party or generic shell-level `Gcr.SystemPrompter` implementation for wlroots/smithay compositors, so anything that disables noctalia's has nothing to fall back to.

**The env-timing risk documented in `docs/skills/desktop.md` § *Toolkit Vulkan / Wayland Environment* does not reach the prompter krytis actually ships.** That section warns `niri-session`'s `systemctl --user import-environment` fires too late for *early* D-Bus-activated services (pipewire, xdg-desktop-portal). The original argument here was about `gcr-prompter`, which activated lazily and so ran long after `import-environment`; that binary is no longer in the image. noctalia's prompter is not D-Bus-activated at all — `files/niri/startup.kdl` `spawn-at-startup`s `noctalia`, so it is already running and already owns the bus name before any prompt can happen. The boot-test assertion that paragraph asked for is still worth having: `secret-tool lock` a non-login collection, trigger `Unlock()`, and confirm noctalia's panel actually appears.

## Writing an `org.gnome.keyring.SystemPrompter` provider: reply ordering is the whole game

The "eventual answer" above was built. A native prompter now exists on the noctalia fork
(`kitten-lily/noctalia`, branch `feat/system-prompter`, commit `ba821c7da`) — see
`docs/design/secrets-service.md` § *Status: implemented on a fork* — for scope and verification. Lessons that will
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

`driveAuthConversation` in `greeter_surface.cpp` used to ACK `Info` messages with an empty response but not call `updateStatus` for them — the "Please touch your security key" cue was silently dropped. Krytis carried a local patch at `files/noctalia-greeter/0001-show-pam-info-cue.patch` (#133/#202; **deleted in #254, that directory no longer exists**) fixing this via `updateStatus` for both Info/Error, a `layoutScene` `hasStatus` check, and a `commitImmediateFrame(true)` before the blocking `postAuthData("")` recv (same pattern as `tryAuthenticate()`).

Merged upstream in noctalia-dev/main commit `26865dae` ("always allow empty passwords and surface PAM info messages"), and #254 dropped both the patch and the `kitten-lily` fork pin. `desktop/noctalia-greeter.bst` then briefly pinned upstream `main`; since #299 it uses `git_repo` with `track: v*`, i.e. upstream **release tags** — `ref: v1.5.0-0-g5a450b89` as of this writing. If a future `bst source track` update on this element regresses the cue, check whether `26865dae`'s equivalent logic survived the change.

## polkit's sandboxed PAM helper hides the FIDO2 token (polkit ≥ 127)

**PAM chain**: `polkit-1` → `system-auth` → `pam_u2f.so`. The polkit meson.build defaults to `system-auth` for non-SUSE/non-BSD Linux builds. `/etc/pam.d/polkit-1` does not exist in krytis — the file lives at `/usr/lib/pam.d/polkit-1` (pam 1.7 vendor dir); look there before concluding the service file is missing.

**polkit 127 runs that chain inside a systemd sandbox, and the sandbox makes `pam_u2f` incapable of succeeding.** Since upstream polkit#501, polkitd no longer fork/execs the setuid helper per authentication: it hands the conversation to a socket-activated unit, `polkit-agent-helper.socket` → `polkit-agent-helper@.service`. Two of that unit's hardening options are fatal for `pam_u2f`:

|Option|Effect on `pam_u2f`|
|---|---|
|`PrivateDevices=yes` (+ `DevicePolicy=strict`, `DeviceAllow=/dev/null rw`)|Private `/dev` with pseudo devices only. `/dev/hidraw*` is absent, libfido2 enumerates **zero** tokens, `pam_u2f` returns `PAM_AUTHINFO_UNAVAIL`.|
|`ProtectHome=yes`|systemd chases the `/home -> var/home` symlink when building the namespace, so **`/var/home` is inaccessible too** — the per-user authfile `~/.config/Yubico/u2f_keys` cannot be opened.|

Both fail silently. The auth phase falls through to `pam_unix` and the user sees a password prompt; `pam_u2f` itself logs nothing either way (see lesson 3 below), so the only trace is the fallthrough:

```
polkit-agent-helper-1[16850]: pam_unix(polkit-1:auth): authentication failure; ... user=lily
polkitd[912]: Operator of unix-session:3 FAILED to authenticate to gain authorization for
              action org.freedesktop.systemd1.manage-units for system-bus-name::1.165 [run0]
```

Reproduce either blocker without touching polkit, by running something under the unit's own options:

```bash
systemd-run --user -P -p PrivateDevices=yes -p DevicePolicy=strict \
    -p DeviceAllow='/dev/null rw' fido2-token -L        # no output = zero tokens
systemd-run --user -P -p ProtectHome=yes \
    wc -c ~/.config/Yubico/u2f_keys                     # Permission denied
```

**Fix (#871): `elements/config/polkit-agent-sandbox.bst`** ships `/usr/lib/systemd/system/polkit-agent-helper@.service.d/50-krytis-fido2.conf` with `PrivateDevices=no`, `DevicePolicy=closed`, `DeviceAllow=char-hidraw rw`, `ProtectHome=read-only` — and nothing else. `PrivateDevices=no` is unavoidable (a cgroup `DeviceAllow` cannot re-materialise a node that a private `/dev` never created); `DevicePolicy=closed` keeps a whitelist instead of opening `/dev` wholesale; `read-only` is all `pam_u2f` needs, since it only reads the authfile. `NoNewPrivileges`, `SystemCallFilter=@system-service`, `ProtectSystem=strict`, `RestrictAddressFamilies=AF_UNIX`, `PrivateNetwork` and the rest stay as upstream ships them. Confirm a candidate relaxation with a real CTAPHID transaction, not just enumeration: `fido2-token -I /dev/hidraw2` under the same `-p` flags.

`mise run boot-test` asserts the four merged properties on the booted image (`systemctl show 'polkit-agent-helper@boottest.service' -p PrivateDevices -p ProtectHome -p DevicePolicy -p DeviceAllow`; a template instance resolves without being started). The VM has no token, so the merged unit properties *are* the testable contract — and a drop-in is silently dead if upstream renames or restructures the unit.

**Scope of the blast radius.** Only the polkit path is affected: `sudo`, `run0`'s own PAM stack, the greeter and console login do not go through this helper. So a key that works for `sudo` looks broken for polkit, for `run0` (which authorizes via polkit), and for every GUI privilege prompt. The same sandbox breaks any PAM module needing devices, `$HOME` or an agent socket — upstream polkit#633 was filed for `pam_ssh_agent`, #622/#623 for neighbouring cases. Upstream acknowledges the class, has no fix, and recommends a unit override in the meantime; `SSH_AUTH_SOCK` in particular is dropped deliberately and will not come back.

**Retiring the override is gated on #874**, not on the next polkit bump. Two changes look like the fix and are not: polkit dropping the setuid helper entirely (polkit#704, setuid-less `pkexec`) removes the *fallback* while leaving the sandbox, and anything that merely stops `polkit-agent-helper.socket` being enabled just routes prompts back down the setuid path by accident of preset ordering. The override is what makes FIDO2 work on **both** paths. #874 carries the real removal condition and the watch points (junction bumps that move polkit past 127, a second PAM module needing devices/`$HOME`/a socket, NFC tokens that `char-hidraw` does not cover).

**Which path a prompt takes is decided in the agent, not in polkitd.** noctalia's polkit agent calls `polkit_agent_session_new()` / `polkit_agent_session_initiate()` (`src/dbus/polkit/polkit_agent.cpp`), i.e. libpolkit-agent-1 — and since polkit 127 that library connects to `/run/polkit/agent-helper.socket` when it is there, falling back to exec'ing the setuid `/usr/lib/polkit-1/polkit-agent-helper-1` only when it is not. So the sandbox applies exactly when the socket unit is running. On krytis it always is: the socket has an `[Install]` section and no preset rule, so the image build's `preset-all` enables it — the symlink ships in the image's own `/etc/systemd/system/sockets.target.wants/polkit-agent-helper.socket` (checked in three separate builds; it is **not** in `/usr/lib/systemd/system/sockets.target.wants/` or in `/usr/share/factory/etc/`, so do not go looking there). This is the #711 fall-through pattern that `mise run vt-owners-test` guards for kmscon, reappearing in an upstream unit.

Diagnosing the socket-vs-setuid question on a live system: `journalctl -g 'Starting polkit-agent-helper@'`. A unit start whose instance encodes the **agent's** PID (`polkit-agent-helper@0-1-<agentpid>_<n>-1000.service`) means the socket path, and therefore the sandbox. No such line around a prompt means the setuid path, where `pam_u2f` has the whole system's `/dev` and `$HOME`.

**The sandbox also silences the audit trail, which is why this is so hard to reconstruct after the fact.** `RestrictAddressFamilies=AF_UNIX` blocks `AF_NETLINK`, so libaudit inside the helper cannot reach the kernel audit socket: `polkit-agent-helper-1` emits **no** `AUDIT1100`/`AUDIT1110` PAM records at all, for success or failure. Every other consumer does — on this machine `journalctl -g 'grantors=.*pam_u2f'` returns 91 records over a month, all `exe="/usr/bin/sudo"`, `"/usr/bin/greetd"` or `"/usr/bin/login"`, and none from the polkit helper, because the helper cannot write any. So `grantors=` is a reliable way to prove *which module* granted a `sudo` or greeter authentication, and is useless for polkit until the sandbox is relaxed. Restoring those records would need `AF_NETLINK` added to `RestrictAddressFamilies`; #871 deliberately does not, since it only relaxes what `pam_u2f` needs.

**Three lessons, all paid for here:**

1. **A code audit of the agent says nothing about the helper.** This section used to read "noctalia polkit agent: FIDO2 works out of the box … No krytis config change needed for polkit FIDO2. Verified by code audit against polkit `9e4894c` and noctalia `78e528b` (issue #137)." The agent half is right and still is — noctalia wires `show-info` → `showInfoCallback` → `setSupplementary(text, false)` for the touch cue and `request` → `handleRequest` for the PIN round, so a multi-round FIDO2 conversation renders correctly. But the audit read conversation code and never ran an authentication, so it could not have caught a helper that never gets as far as a conversation. "Works out of the box" needs a live attempt behind it.
2. **`pam_u2f` reachability has bitten twice, from opposite directions.** #784 was stack ordering (`pam_systemd_home`'s `success=done` short-circuit meant `pam_u2f` never ran); #871 is process environment (`pam_u2f` runs, finds no device). "The module is in the stack and the key is enrolled" implies nothing about either.
3. **Do not read success or failure out of the absence of log lines.** `pam_u2f` logs nothing on success *and* nothing on a clean `PAM_AUTHINFO_UNAVAIL` fall-through, and polkitd logs only `FAILED to authenticate`, never the successful authorizations — so a journal with no `pam_u2f` lines and no polkitd successes is equally consistent with "worked fine for months" and "never once ran". An early draft of this section concluded from exactly that silence that polkit FIDO2 had never worked in krytis; the user had been using it. Establish which path a prompt took from the `polkit-agent-helper@` unit starts above, and establish reachability from the sandbox itself (`systemd-run` replication, `systemctl show`), not from what the journal fails to say.

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

Third consequence, found in #371: any tool that drives krytis over SSH with a
password cannot work — and krytis owns one such tool, the live-ISO installer gate.
`live/src/configure-live-krytis.sh` sets `liveuser:live` with `chpasswd` (under
`DEBUG=1` only), and `mise/tasks/iso-boot-live` plus
`scripts/iso-install-fisherman.sh` then log in as `liveuser` with
`-o PreferredAuthentications=password`. Against a live session still carrying the
image's pubkey-only policy that login fails, and the failure looks like a boot or
network problem rather than a policy decision:

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

**No client-side mechanism rescues this.** `scripts/e2e-lib.sh`'s
`e2e_ssh_auth_init` uses `sshpass -p live` when that binary is present and
otherwise writes a private `SSH_ASKPASS` shim, exporting
`SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+) and passing
`-o NumberOfPasswordPrompts=1`. A krytis host always takes the fallback: it is a
bootc image with no dnf and no apt, so `sshpass` cannot be installed and is
deliberately absent. Either way both mechanisms only *supply* a password —
whether sshd will accept one at all is decided server-side, so the gate still
depends on the drop-in below, not on which of the two it picked.

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

## systemd-homed disk-space management: `--auto-resize-mode` defaults to `off`, and an explicit `homectl resize` silently disables rebalancing

**Symptom, found on a real deployed machine (2026-09-08):** the physical disk backing
`/sysroot` was 95% full while the mounted home filesystem (`df -h /var/home/<user>`) reported
only ~90% of its own, much smaller size used. The gap was a single file,
`/sysroot/state/os/default/var/home/<user>.home` — homed's LUKS2 backing image — sized far
past what the btrfs filesystem inside it actually needed. `btrfs filesystem usage
/var/home/<user>` on the mounted fs showed a large `Device slack` figure: the btrfs
filesystem had been shrunk (by an earlier `homectl resize` or rebalance) but the *backing
loopback file* was never truncated to match, so the difference is pure dead weight on the
real disk.

**Root cause, from `man homectl`/`man homed.conf` (systemd 261):** two independent knobs, both
per-user record properties (no `homed.conf` global default exists for either — that file only
has `DefaultStorage=`/`DefaultFileSystemType=`):

- `--rebalance-weight=` (default **100**, i.e. on) makes homed periodically redistribute free
  space between active home areas and their backing storage in the background. **A resize
  turns this off**: "resizing the home area explicitly (with `homectl resize`) will implicitly
  turn off the automatic [rebalancing]" — so any one-off `homectl resize <user> <size>` an
  admin runs by hand permanently disables the self-healing background pass for that account,
  with no warning. Re-enable with `homectl update <user> --rebalance-weight=100`.
- `--auto-resize-mode=` (default **off**) is separate from rebalancing: `grow` expands the
  image to `--disk-size=` on login if smaller; `shrink-and-grow` additionally shrinks it back
  to the minimum the used space allows on a **clean logout**, every session. Neither is enabled
  by default — a homed image only ever grows unless one of these two mechanisms is active.

**Reclaiming space after the fact:** `homectl resize <user> min` (per `man homectl`, btrfs
supports this **while the user is logged in** — unlike ext4, which needs the home
deactivated/logged-out first, and xfs, which cannot shrink at all). Note this resize call
itself flips `Rebalance` to `off` per the mechanism above, so pair it with
`--rebalance-weight=100` (or just use `--auto-resize-mode=shrink-and-grow` going forward
instead of one-off manual resizes).

**Do not "fix" this by enabling `--luks-discard=on` (online discard).** `homectl inspect`
normally shows `LUKS Discard: online=no offline=yes` — that split is systemd's deliberate
default, not a misconfiguration: online discard thin-provisions the home area live, so if the
*outer* filesystem fills up, the *inner* one gets I/O errors mid-write instead of behaving like
a normal disk. `--auto-resize-mode`/`--rebalance-weight` reclaim space through explicit,
bounded resize operations instead, which is why krytis's first-boot wizard sets
`--auto-resize-mode=shrink-and-grow` on the initial account rather than touching discard (see
`docs/design/first-boot-setup.md`, `files/systemd-firstboot/firstboot-wizard.sh`).

## `userdbctl` can wedge SSH pubkey auth — and any probe that only sets `ConnectTimeout`

**What:** krytis's sshd ships systemd's drop-in
`AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys %u` (+
`AuthorizedKeysCommandUser root`), so **every** public-key authentication shells out to
`userdbctl`, which queries `systemd-userdbd` over varlink. When that query does not
answer, sshd blocks in the pre-auth phase indefinitely: the TCP connection is accepted,
the kex completes, the server advertises `publickey`, and then nothing. The guest is
otherwise healthy — `systemctl is-system-running` reports `running`, no jobs pending,
`sshd.service` active and listening.

Observed 2026-09-14 in QEMU while running the #843 ISO gates: three consecutive
installs (unsigned payload and sealed payload alike) wedged this way, after an earlier
identical run authenticated in seconds. Guest-side evidence, with
`systemd.journald.forward_to_console=yes` on the cmdline:

```
sshd-session[938]: Connection closed by authenticating user root 10.0.2.2 port 34014 [preauth]
```

— i.e. the *client* gave up; the server never answered the key offer. A manual
`ssh -vv` stalls at `debug1: Next authentication method: publickey` and never returns,
even after 200 s.

**Harness consequence, and the rule:** `ssh -o ConnectTimeout=N` does **not** bound this.
`ConnectTimeout` applies to the TCP connect only, which succeeds instantly here — so a
retry loop built on it never gets its iteration back, and a gate advertised as "up to 240s"
hangs forever. `mise/tasks/boot-test` sat at `[3/5] Waiting for SSH (up to 240s)` for 40+
minutes this way. Every SSH probe against a possibly-sick guest MUST carry a wall-clock cap:

```bash
timeout 10 ssh -o ConnectTimeout=2 -o BatchMode=yes …
```

and the surrounding loop MUST measure wall-clock (`date +%s` deadline), not iteration
count — iteration count silently multiplies the advertised budget by the per-probe cap.

**Undiagnosed, and no longer tracked:** why `systemd-userdbd` stops answering was never
established. #848 was closed as completed on 2026-09-15 by the harness fix below, which
routes `boot-test` around the call rather than fixing it, and no successor issue was
opened — so this is a known, untracked bug. It is not caused by
secure boot (reproduced with enforcement off), not by the sealed payload (reproduced with
the unsigned one), and not by a dirty disk (reproduced on a fresh install). Suspected
socket-activation race — it is intermittent. If a boot-test run fails with SSH never coming
up while the serial log shows a healthy `running` system, this is the first thing to check.
`AuthorizedKeysFile` alone (no `AuthorizedKeysCommand`) looked like the obvious escape hatch
for the test path — it turned out not to be enough on its own; see the next entry for why
and for the applied fix.

## `boot-test`'s SSH verdict must disable `AuthorizedKeysCommand`, not just override `AuthorizedKeysFile` (#848)

**Symptom.** `mise run boot-test` (and everything that delegates its verdict to it —
`iso-install-test`, `luks-install-test`, `upgrade-test`, `selfenroll-test`,
`tpm-boot-test`) intermittently wedged at `[3/5] Waiting for SSH`: TCP connects, kex
completes, sshd advertises `publickey`, then never answers the key offer. Reproduced
2026-09-14 running #843's ISO gates — three consecutive runs wedged after an earlier
identical run authenticated in seconds. Guest otherwise healthy
(`systemctl is-system-running` → `running`, sshd active and listening).

**Why `AuthorizedKeysFile` alone didn't rescue it.** krytis's image-wide sshd config
carries systemd's `AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys` drop-in
(`20-systemd-userdb.conf`). `boot-test`'s `sshd.service` override already pointed
`AuthorizedKeysFile` at its own ephemeral credential
(`-o "AuthorizedKeysFile ${CREDENTIALS_DIRECTORY}/krytis.boottest_authorized_keys"`), which
looks like it should be sufficient — sshd normally short-circuits on the first
matching source. It wasn't: `AuthorizedKeysCommand` stays configured regardless (that
keyword is untouched by the `AuthorizedKeysFile` override — different keyword, both
active), and *some* runs of the pubkey check reach it anyway rather than resolving off
the file. The exact fallthrough trigger is unconfirmed — plausibly the same
intermittent condition that makes this reproduce at all, possibly a credential-import
race — but once `AuthorizedKeysCommand` is reached, `sshd` blocks in pre-auth
indefinitely if `systemd-userdbd`'s varlink query doesn't answer, and there is no
timeout on that call.

**Fix, applied in `mise/tasks/boot-test`'s `sshd-dropin.conf`:** add
`-o AuthorizedKeysCommand=none` alongside the existing `-o "AuthorizedKeysFile …"`, so
the command source is disabled outright for this one boot rather than merely
shadowed. `boot-test` doesn't need userdb-backed key lookup — it provisions its own
ephemeral key — so there is no cost to removing the fallthrough path entirely instead
of chasing why some runs take it. Verified: `mise run boot-test` passes clean with no
SSH stall after this change.

**Scope note:** this fixes the *test harness's* dependency on `userdbctl`, not the
underlying `systemd-userdbd` intermittency, which is a real bug for any interactive
user hitting SSH on a booted guest. #848 was closed as completed on this fix alone
(2026-09-15) and nothing tracks the underlying bug now — see the previous entry. If a
`boot-test` run still stalls at the SSH wait step after this fix, the cause is something
else — this specific fallthrough is closed.
