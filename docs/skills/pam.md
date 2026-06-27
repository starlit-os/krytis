# PAM & Keyring Skills

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

## PAM file path in Freedesktop SDK

fdsdk uses an arch-specific libdir: `/usr/lib/x86_64-linux-gnu`. PAM modules must be installed to `/usr/lib/x86_64-linux-gnu/security/`. In BST variables: `pam_moduledir=%{libdir}/security`.

Do not assume `/usr/lib/security/` — that path does not exist in fdsdk images.
