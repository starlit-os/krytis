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
- [ ] `mise run lint`
- [ ] `mise run generate-fakecap-manifest` — the TSV still attributes files to
      `core/gnome-keyring.bst`; it is derived data consumed by `mise run chunkify`, so it must
      be regenerated **after** a successful build or chunkify will restore stale attributions.

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

### In-guest checks

- [ ] **gcr-prompter really is gone** — otherwise every prompt result below is meaningless:
      `ls /usr/libexec/gcr-prompter /usr/share/dbus-1/services/org.gnome.keyring.SystemPrompter.service`
      should both fail, and `grep -c gcr /usr/manifest.json` should not turn up `gcr-3`.
- [ ] **oo7 is the secrets provider:**
      `systemctl --user status oo7-daemon.service` and
      `busctl --user introspect org.freedesktop.secrets /org/freedesktop/secrets`
- [ ] **noctalia owns the prompter name:**
      `busctl --user list | grep org.gnome.keyring.SystemPrompter` — the owner should be
      noctalia's PID, not an activated helper.
- [ ] **Password login auto-unlocks** the login collection via `pam_oo7.so auto_start`:
      `secret-tool store --label=t a b <<<hunter2` then `secret-tool lookup a b` with no prompt.
- [ ] **Manual unlock draws noctalia's panel, not a GTK dialog.** This is the headline test:
      lock a secondary collection and force a prompt —
      `secret-tool lock --collection=test` then read from it. Expect noctalia's centred
      prompt; expect the typed password to be accepted.
- [ ] **Cancel is clean, not a hang** — dismiss the prompt with Escape and confirm the caller
      returns an error promptly rather than blocking (the pop-os/cosmic-epoch#3453 failure mode).
- [ ] **`CreateCollection` / `ChangePassword`** through `seahorse` or a libsecret client.
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
