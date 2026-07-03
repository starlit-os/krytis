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

## noctalia-greeter: PAM_TEXT_INFO (FIDO2 cue) display — fixed upstream

`driveAuthConversation` in `greeter_surface.cpp` used to ACK `Info` messages with an empty response but not call `updateStatus` for them — the "Please touch your security key" cue was silently dropped. Krytis carried a local patch (`files/noctalia-greeter/0001-show-pam-info-cue.patch`) fixing this via `updateStatus` for both Info/Error, a `layoutScene` `hasStatus` check, and a `commitImmediateFrame(true)` before the blocking `postAuthData("")` recv (same pattern as `tryAuthenticate()`).

Merged upstream in noctalia-dev/main commit `26865dae` ("always allow empty passwords and surface PAM info messages"). `desktop/noctalia-greeter.bst` is now pinned to upstream `main` directly — the local patch and fork pin are gone. If a future `bst source track` update on this element regresses the cue, check whether `26865dae`'s equivalent logic survived the change.

## noctalia polkit agent: FIDO2 works out of the box

Noctalia ships its own polkit agent (`src/dbus/polkit/`). The `show-info` signal (from `PAM_TEXT_INFO`) is wired to `showInfoCallback → setSupplementary(text, false)`, which `polkit_panel.cpp` displays in `promptLabel` when no input is required. Multi-round (PIN prompt) is handled via the `request` signal → `handleRequest` → input field shown. No krytis config change needed for polkit FIDO2. Verified by code audit against polkit `9e4894c` and noctalia `78e528b` (issue #137).

**PAM chain**: `polkit-1` → `system-auth` → `pam_u2f.so`. The polkit meson.build defaults to `system-auth` for non-SUSE/non-BSD Linux builds.

## PAM file path in Freedesktop SDK

fdsdk uses an arch-specific libdir: `/usr/lib/x86_64-linux-gnu`. PAM modules must be installed to `/usr/lib/x86_64-linux-gnu/security/`. In BST variables: `pam_moduledir=%{libdir}/security`.

Do not assume `/usr/lib/security/` — that path does not exist in fdsdk images.
