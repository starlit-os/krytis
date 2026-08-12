# oo7 + native SystemPrompter testbed

**Branch:** `feat/oo7-prompter-testbed` — a throwaway integration branch, **not a merge candidate.**

Two independent pieces of work are combined here so they can be exercised together on one
booted image:

1. **oo7** replaces `gnome-build-meta.bst:core/gnome-keyring.bst` as the
   `org.freedesktop.secrets` provider (#84, previously attempted and abandoned in #178).
2. **noctalia serves `org.gnome.keyring.SystemPrompter` natively**
   (`kitten-lily/noctalia` `feat/system-prompter`, `ba821c7da`), so manual unlock does not
   need `gcr-3`/`gcr-prompter`.

The combination is the interesting part. Dropping gnome-keyring also drops the transitive
`sdk/gcr-3.bst` dependency that put `gcr-prompter` in the image; `elements/desktop/oo7.bst`
deliberately does **not** add it back. If manual unlock still works on this image, it works
because noctalia is answering the prompt.

Background and prior findings: `docs/design/secrets-service.md`, `docs/skills/pam.md`
§ *Manual unlock on niri needs `gcr-3`* and § *Writing an `org.gnome.keyring.SystemPrompter`
provider*.

## Gates this branch is parked behind

- **The #84 hold still stands.** `docs/design/secrets-service.md` § Decision says do not
  re-attempt the oo7 migration until oo7#506 resolves *or* we deliberately accept the
  FIDO2-keyring-stays-locked gap. This branch does not overturn that — it exists to gather
  evidence for the decision, not to pre-empt it.
- **Breakage Gate.** Touches the PAM stack (`config/greetd-config.bst`) and the greeter
  session. Human sign-off required before any of this merges.
- **Upstream Gate.** Nothing has been opened against `noctalia-dev/noctalia`. The prompter
  lives on a fork branch.

## Must not merge as-is

| Item | Why |
|---|---|
| `elements/desktop/noctalia.bst` pinned to `github:kitten-lily/noctalia.git`, `track: feat/system-prompter` | Fork branch pin. `bst source track` follows a branch head here instead of the `v*` release glob. Revert to `noctalia-dev/noctalia` + `track: v*` once the prompter is upstreamed. |
| `files/noctalia-skel/settings.toml` → `secret_prompter = true` | Only meaningful while the fork pin is in place; the option does not exist upstream. |

Everything else (`elements/desktop/oo7.bst`, the PAM swap, the stack swap, the
`track-bst-sources.yml` entry) is a genuine candidate if #84 is ever unblocked.

## Divergences from #178

- **`use_authtok` dropped from the `password` line.** #178 carried it over from the
  `pam_gnome_keyring` line without checking. Upstream's own example
  (`oo7` `pam/README.md`) is `password optional pam_oo7.so`, no flag — pam_oo7 reads the old
  and new password itself to re-encrypt matching keyrings.
- **PAM stack rebased onto current `main`.** `pam_systemd_home` landed after #178 (see
  `greetd-config.bst`); only the three `pam_gnome_keyring.so` → `pam_oo7.so` swaps were
  applied, nothing else was reverted.
- **`sdk/gcr-3.bst` deliberately absent** (see above). #178 never noticed it was losing it.

## Build

- [x] `mise run bst show --deps none desktop/oo7.bst desktop/noctalia.bst stacks/desktop.bst` — graph resolves
- [x] `mise run bst source fetch desktop/noctalia.bst` — fork ref `ba821c7da` resolves
- [x] `mise run bst source fetch desktop/oo7.bst` — git ref + cargo2 crates resolve
- [x] `mise run bst build desktop/oo7.bst desktop/noctalia.bst` — both build clean
      (`Build Queue: processed 2, failed 0`). Artifacts contain
      `usr/lib/x86_64-linux-gnu/security/pam_oo7.so`, `usr/libexec/oo7-daemon`,
      `usr/lib/systemd/user/{oo7-daemon,dbus-org.freedesktop.secrets}.service`, and
      `usr/bin/noctalia` — which links `libgcr-4.so.4` and carries the
      `org.gnome.keyring.SystemPrompter` / `.internal.Prompter{,.Callback}` strings, so the
      prompter really is in the artifact rather than merely in the source pin.
      (`--pull` was unavailable: the Buildbarn token comes from fnox and the local pass-cli
      database is corrupt, so this was a local-cache build.)
- [x] `mise run build` (= `generate-image-version` + `load-image` + `lint`) — passed;
      `bootc container lint` reports 13 checks passed, 1 skipped, image tagged
      `localhost/krytis:latest`.
- [ ] `mise run generate-fakecap-manifest` — **deliberately not run on this branch.** The
      committed TSV still attributes files to `core/gnome-keyring.bst`, so it is stale here,
      but regenerating it produces a ~34 MB diff that is pure noise on a throwaway branch.
      Run it before `mise run chunkify` (which feeds the TSV to `fakecap-restore`); the plain
      `generate-disk` route below does not need it.

### Careful: `mise run lint` alone does not rebuild the image

`lint` only runs the Containerfile against whatever `localhost/krytis-input:latest` already
is — it will happily pass against a stale image from a previous branch. The first run here
did exactly that and reported success while the image still contained gnome-keyring,
`gcr-prompter` and `pam_gnome_keyring.so`. Use `mise run build`, which chains
`generate-image-version` → `load-image` → `lint`. Verify image *contents*, never just the
lint exit code.

### Build gotcha worth keeping

Adding a library dependency to noctalia's own `meson.build` upstream is only half the change:
`elements/desktop/noctalia.bst` must gain the matching BST dependency or the element fails at
`meson setup` with `ERROR: Dependency "gcr-4" not found, tried pkgconfig`. Here that is
`gnome-build-meta.bst:sdk/gcr.bst` (**gcr-4**, not the legacy `sdk/gcr-3.bst`), in `depends`
rather than `build-depends` because `libgcr-4.so` is linked at runtime.

## Boot and test

`mise run boot-vm` cannot give an interactive console on a krytis host (#505), and every check
below needs typing inside the guest. Use the qcow2 route from #506:

```shell
mise run generate-disk --disk /var/tmp/krytis-oo7.raw --size 15G   # needs sudo
mise run convert-to-qcow2 --disk /var/tmp/krytis-oo7.raw           # unprivileged
# GNOME Boxes -> + -> Install from file -> /var/tmp/krytis-oo7.qcow2
```

See `docs/skills/bootc-vm.md` § *Interactive VM testing via GNOME Boxes* for the OVMF and
stale-disk snags.

### Already verified statically against `localhost/krytis:latest`

These needed no boot — `podman run --rm localhost/krytis:latest` was enough:

- [x] **gcr-prompter really is gone.** Both `/usr/libexec/gcr-prompter` and
      `/usr/share/dbus-1/services/org.gnome.keyring.SystemPrompter.service` are absent, and
      `/usr/manifest.json` lists neither `core/gnome-keyring.bst` nor `sdk/gcr-3.bst` — only
      `desktop/oo7.bst` and `sdk/gcr.bst` (gcr-4, for the exchange). So any prompt that
      appears on this image is noctalia's.
- [x] **oo7 is installed:** `/usr/libexec/oo7-daemon`,
      `/usr/lib/x86_64-linux-gnu/security/pam_oo7.so`, and both
      `/usr/lib/systemd/user/oo7-daemon.service` and
      `/usr/lib/systemd/user/dbus-org.freedesktop.secrets.service`.
- [x] **PAM is wired to oo7:** `/etc/pam.d/greetd` has `auth optional pam_oo7.so`,
      `-password optional pam_oo7.so` (no `use_authtok`) and
      `session optional pam_oo7.so auto_start`; no `pam_gnome_keyring.so` remains.
- [x] **noctalia links gcr-4:** `ldd /usr/bin/noctalia` → `libgcr-4.so.4`.
- [x] **The skel toggle ships:** `secret_prompter = true` in
      `/etc/skel/.local/state/noctalia/settings.toml`.
- [x] **`oo7-daemon` actually runs on this image and claims the bus name.** Run it as an
      unprivileged uid — `podman run --rm --user 1000 --tmpfs /tmp:rw,mode=1777
      --tmpfs /run/user:rw,mode=0777 localhost/krytis:latest`, start a private
      `dbus-daemon --session`, then `/usr/libexec/oo7-daemon`. It logs
      `Created default 'Login' collection (locked)` and
      `PAM listener started on /run/user/1000/oo7-pam.sock`, and `busctl --user list` shows it
      owning `org.freedesktop.secrets` exposing `org.freedesktop.Secret.Service`.
      **Run it as root and it dies** with `Capability error Operation not permitted` — that is
      a container artifact, not a broken build (see `docs/skills/pam.md`).
- [x] **`secret-tool` and `busctl` are in the image** (`seahorse` is not — use `secret-tool`
      or a libsecret client for the `CreateCollection`/`ChangePassword` checks below).
- [x] **noctalia accepts `secret_prompter`.** `noctalia config export` round-trips
      `secret_prompter = true`, and a deliberately bogus sibling key produces
      `shell.bogus_made_up_key: unknown setting` while `secret_prompter` produces no warning —
      so it is a recognised setting, not one silently tolerated and dropped.

### Proven on the bus without booting: oo7 really does need this prompter

With `oo7-daemon` running in the image and **nothing** owning the prompter name, a
`secret-tool store` against the locked `Login` collection emitted
`org.gnome.keyring.SystemPrompter`, `org.gnome.keyring.internal.Prompter`,
`BeginPrompting`, `/org/gnome/keyring/Prompter` and oo7's own
`/org/gnome/keyring/Prompt/p` callback object — then **blocked until killed at 25s, printing
nothing.** oo7 logged only `Client :1.2 connected` / `disconnected`.

So oo7's `GNOMEPrompterProxy` is observed, not assumed, and the no-prompter failure mode is an
indefinite hang rather than an error — pop-os/cosmic-epoch#3453 on our own image.

### In-guest checks (booted session)

- [x] **oo7 is the secrets provider** — `org.freedesktop.secrets` owned by `oo7-daemon`.
- [x] **noctalia owns the prompter name** — `busctl --user list` shows
      `org.gnome.keyring.SystemPrompter` owned by noctalia, and there is no `gcr-prompter` in
      the image to fall back to.
- [x] **The image under test is the testbed** — `/usr/manifest.json` lists `desktop/oo7.bst`.
- [x] **Manual unlock draws noctalia's panel** and, once answered, noctalia stored a secret
      through the Secret Service — which is only reachable with the collection unlocked. The
      full chain ran: oo7 → `BeginPrompting` → noctalia's panel → `sx-aes-1` → unlock → store.
- [x] **Password login auto-unlocks** the login collection via `pam_oo7.so auto_start` —
      second login produced no prompt at all, so the PAM handshake over
      `/run/user/$(id -u)/oo7-pam.sock` is working and the panel is not papering over a
      broken auto-unlock.
- [ ] **Round-trip a secret by hand.** Order matters — see the trap below.

      # 1. state check: `b false` = unlocked
      busctl --user get-property org.freedesktop.secrets \
        /org/freedesktop/secrets/collection/Login \
        org.freedesktop.Secret.Collection Locked

      # 2. store while UNLOCKED (no prompt expected)
      echo -n hunter2 | secret-tool store --label='krytis test' service krytis-test key demo
      secret-tool lookup service krytis-test key demo; echo   # prints hunter2

      # 3. lock, and confirm it took
      secret-tool lock --collection=Login
      busctl --user get-property org.freedesktop.secrets \
        /org/freedesktop/secrets/collection/Login \
        org.freedesktop.Secret.Collection Locked              # expect b true

      # 4. NOW read it back -- this is the prompt test
      secret-tool lookup service krytis-test key demo

      secret-tool clear service krytis-test key demo          # cleanup

      **Trap: querying a secret that does not exist never prompts**, so "I locked it and
      nothing happened" usually means step 2 was skipped. Verified against oo7 in the image:
      with the collection locked and no prompter on the bus, both
      `secret-tool lookup` and `secret-tool search --unlock` for an absent item returned in
      0s (`rc=1` and `rc=0`) — there is nothing to unlock, so no prompt is raised. The item
      has to exist first.

      **The guaranteed trigger is `store` into a locked collection**, which must open the
      collection to write: that is the case that emitted `BeginPrompting` and then hung for
      the full 25s timeout with no prompter present.

      `secret-tool store` reads the secret from stdin. **`Login` is capitalised**: oo7 derives
      the collection path from the keyring label, so it is
      `/org/freedesktop/secrets/collection/Login`, not gnome-keyring's lowercase `login` —
      `--collection=login` fails with "No such secret collection at path". See
      `docs/skills/pam.md`.
- [ ] **Cancel is clean, not a hang** — dismiss the prompt with Escape and confirm the caller
      returns an error promptly rather than blocking (the pop-os/cosmic-epoch#3453 failure mode).
- [ ] **`CreateCollection` / `ChangePassword`** — `seahorse` is not in the image, so drive
      these over D-Bus directly (`busctl --user call org.freedesktop.secrets
      /org/freedesktop/secrets org.freedesktop.Secret.Service CreateCollection ...`) or with
      any libsecret client. Both paths are prompt-bearing, which is the point.
- [ ] **FIDO2 login leaves the collection locked, and the prompt is now the way out.**
      Known gap, not a regression (`docs/design/secrets-service.md` § The blocker). Worth
      measuring here because the native prompter is what makes it *recoverable* rather than
      terminal: log in with the FIDO2 key, confirm the collection is locked, then confirm a
      manual unlock through noctalia's prompt actually opens it.
- [ ] **Mid-session daemon restart:** `systemctl --user restart oo7-daemon.service`, then
      trigger a read. Expect a re-lock (oo7#506, no FD-store resume) and, critically, a
      working prompt afterwards rather than a hung caller.
- [ ] **`SSH_AUTH_SOCK`** — oo7 ships no ssh-agent, and nothing in this repo wires one
      (checked: no `gcr/ssh` reference in `elements/` or `files/`). Any user dotfile pointing
      at gnome-keyring's `$XDG_RUNTIME_DIR/gcr/ssh` breaks on this image. Confirm what the
      test user's shell config does before blaming oo7.

## Outcome

Record the result in `docs/design/secrets-service.md` — either as evidence for accepting the
FIDO2 gap deliberately, or as the reason to keep holding. Then archive this plan to
`docs/plans/done/`.
