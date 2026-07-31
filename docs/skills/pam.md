# PAM & Keyring Skills

## systemd-homed users: FIDO2 login belongs to homed, not pam_u2f

Two independent things broke FIDO2 login for `systemd-homed`-managed users. Both were fixed in #409; keep them straight, because fixing only the first looks plausible and achieves nothing.

**1. `pam_u2f` structurally cannot serve homed *login*.**

In per-user mode (no `authfile=`) pam_u2f builds the path from the passwd entry — `resolve_authfile_path()` in `pam-u2f.c` does `dir = user->pw_dir` + `.config/Yubico/u2f_keys` — and `open()`s it during `pam_sm_authenticate` (`util.c:get_devices_from_authfile`). A homed user's home is an **unmounted encrypted image** at that moment: systemd's `home_activate()` (`src/home/homework.c`) only mounts it *after* `user_record_authenticate()` succeeds. So the `open()` returns `ENOENT` and pam_u2f returns **`PAM_AUTHINFO_UNAVAIL`** (not `PAM_USER_UNKNOWN` — that code is only used when the file parsed fine but held no line for this user). Upstream states the general case outright in pam-u2f's `README.adoc`: an authfile in an encrypted home makes login impossible.

Moving the authfile to a root-owned absolute path *would* make the `open()` succeed (`authfile=/etc/security/u2f_mappings/%u` + `expand`, no `openasuser` → read as root; note `expand` substitutes only `%u` and `%%`, there is no `%h`). **Do not do it.** For homed, the token's `hmac-secret` output *is* the key material that decrypts the home — `fido2_use_token()` in `src/home/homework-fido2.c` derives the LUKS/fscrypt passphrase from it. A `sufficient` pam_u2f success would end the auth stack before `pam_systemd_home` ever ran, landing the user in a session with no home mounted. FIDO2 for homed login is homed's job, via `homectl update <user> --fido2-device=auto` (rp_id `io.systemd.home`).

pam_u2f is still right for a homed user's **sudo/polkit**: by then the home is mounted, so the per-user authfile is readable. Hence `mise fido2:enroll` enrolls the key twice for homed users — once into the home record, once into `~/.config/Yubico/u2f_keys`.

**2. `/etc/pam.d/greetd` had no `pam_systemd_home.so` at all.**

Because greetd's stack is self-contained (it does not `include system-auth`), homed users could not log in through the greeter *at all* — with or without a key. They have no `/etc/shadow` entry, so `pam_unix` denies. tty `login` worked the whole time because it `include`s `system-auth`, which did carry the module. **Any new self-contained PAM service in this repo must carry `pam_systemd_home.so` in all four phases**, or it silently excludes every homed user.

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

Upstream bug: passing the wrong property key to `CreateCollection` causes an `unwrap()` panic at `client/src/dbus/api/properties.rs:84:78` instead of returning an error.

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

### Two consequences of key-only SSH

**Incompatible with homed-managed homes.** `pam_systemd_home` needs the user's
password to unlock the encrypted home image, so a pubkey-only SSH login has
nothing to mount it with. Harmless while accounts are created by `useradd` with
plain home directories (see docs/skills/desktop.md § `/etc/skel`), but it
constrains any future move to `homectl`. If krytis ever adopts homed for real
accounts, keyboard-interactive has to come back for SSH.

**No PAM-driven 2FA over SSH.** `pam_u2f` runs in the keyboard-interactive path,
so disabling it removes FIDO2-via-PAM for SSH specifically (console, sudo, polkit
and the greeter are unaffected — they do not go through sshd). The replacement is
native OpenSSH security-key auth: openssh is built `--with-security-key-builtin`
and advertises `sk-ssh-ed25519@openssh.com` and
`sk-ecdsa-sha2-nistp256@openssh.com`, which authenticate over **pubkey** and need
no keyboard-interactive path. `ssh-keygen -t ed25519-sk` is the intended second
factor for SSH.
