# Secrets Service: gnome-keyring vs. oo7

Krytis ships `gnome-keyring` (`gnome-build-meta.bst:core/gnome-keyring.bst`) as its
`org.freedesktop.secrets` provider and PAM-unlocked login keyring, wired in
`stacks/desktop.bst` and `elements/config/greetd-config.bst`. This doc tracks whether/when
to switch to [oo7](https://github.com/linux-credentials/oo7) instead, and why the last
attempt was abandoned.

## Why oo7 is attractive

- Memory-safe Rust implementation of the same `org.freedesktop.secrets` spec — fits the
  "Rust over C where equivalent" preference already applied elsewhere in this repo
  (`sudo-rs.bst`).
- Wayland-native, no legacy X11 assumptions.
- Scoped-authorization model for sandboxed apps, and a path to FIDO2-backed secrets —
  relevant to krytis's existing `pam_u2f` investment (#129, #133).
- **Fedora is adopting it as the system-wide default for F45** (KWallet and GNOME Keyring
  both replaced), FESCo-approved:
  [Changes/oo7_Secrets_Service_Provider](https://fedoraproject.org/wiki/Changes/oo7_Secrets_Service_Provider).
  This validates the technical direction — it is not a niche or abandoned project.

## History

- **#84** (2026-06-20): investigation opened.
- **#178** (2026-06-26, closed without merge): implementation attempt. Added
  `elements/desktop/oo7.bst`, swapped `pam_gnome_keyring.so` → `pam_oo7.so` on all three
  PAM lines in `greetd-config.bst`, built successfully. Abandoned after discovering the
  FIDO2 login gap below — the stated goal of unblocking #129/#133 wasn't actually achieved.
- **#189** (2026-06-27): rescued the skill-file learnings from #178's branch into
  `docs/skills/pam.md` before the branch was deleted, so the findings weren't lost even
  though the code wasn't merged.
- **2026-08-12**: re-validated #178's findings against current upstream `main`
  (post-0.7.0-alpha) and Fedora's F45 change proposal, prompted by that proposal surfacing
  in conversation. Findings below; details in `docs/skills/pam.md`.

## The blocker: FIDO2-only login leaves the keyring locked

`pam_oo7.so`'s `auth` phase needs a non-null `PAM_AUTHTOK` to stash a password for the
`session` phase to send to the daemon. A FIDO2-only login via `pam_u2f sufficient` never
populates `PAM_AUTHTOK` — pam_u2f doesn't set it, and it short-circuits the stack before
`pam_unix` would. Result: the oo7 Login collection stays locked for the entire session, and
since `oo7-daemon` only exposes the `default` alias on an *unlocked* collection, libsecret
clients that expect it (e.g. Ghostty) get an unexpected Prompt response and crash.

**This is not a regression** — `gnome-keyring`'s PAM module has the identical shape of gap
on FIDO2-only login, for the same reason (no password captured, nothing to unlock with).
Switching to oo7 does not make FIDO2 login worse. It also does not unblock #129/#133 the way
#178's PR description claimed, because the actual blocker survives the swap.

**Verified still open as of 2026-08-12**, both in code and in upstream's own tracker:

- `pam/src/lib.rs::get_auth_token_internal` on current `main` still returns
  `Err(PAM_SYSTEM_ERR)` on null `PAM_AUTHTOK`, and `pam_sm_authenticate` still treats that
  as "nothing to stash" rather than failing loudly.
- [oo7#506](https://github.com/linux-credentials/oo7/issues/506) is the upstream
  maintainer's own discussion of passwordless/FIDO2 keyring unlock, still active
  (last reply 2026-08-02). The maintainer is waiting on `credentiald` and a systemd PR to
  mature before deciding a direction — there is no fix in flight, just an open design
  question. Re-attempting #84 today would not change this outcome.

See `docs/skills/pam.md` § pam_oo7 for the full technical detail, plus two more findings
from the 2026-08-12 pass that don't block anything but matter for a future attempt:

- A restart of `oo7-daemon.service` mid-session silently re-locks an already-unlocked
  collection (no FD-store/credential-based resume yet — oo7#506, 2026-08-03 comment).
  Lower risk for krytis than for traditional Fedora, since bootc updates are reboot-driven
  rather than live in-place daemon restarts, but still worth a boot-test scenario.
- oo7 ships no ssh-agent component at all. Whatever provides `SSH_AUTH_SOCK` today
  (`~/.config/fish/conf.d/ssh-agent.fish`, currently pointed at gnome-keyring's
  `$XDG_RUNTIME_DIR/gcr/ssh`) has to keep existing independent of this migration — it isn't
  a "different path to switch to" question.
- Manual unlock UI on niri (secondary keyrings, `CreateCollection`, `ChangePassword`) needs
  `gcr-prompter` (`sdk/gcr-3.bst`) — oo7 has no niri/wlroots-native prompter, and a
  Wayland session always resolves to the GNOME (`org.gnome.keyring.SystemPrompter`) path,
  never the CLI fallback, since `WAYLAND_DISPLAY` counts as "has a display". Krytis gets
  this today only transitively through `gnome-keyring.bst`'s runtime dependency — `oo7.bst`
  must add it explicitly or manual unlock silently breaks. Full detail in `docs/skills/pam.md`
  § Manual unlock on niri needs `gcr-3`.

## Decision

**Hold.** Leave gnome-keyring in place. Do not re-attempt #84 until one of:

1. oo7#506 lands a resolution (passwordless/FIDO2 unlock has a real path), or
2. We explicitly decide the FIDO2-keyring-stays-locked gap is acceptable to ship (it is no
   worse than the status quo, so this is a legitimate option — it just needs to be a
   deliberate call, not a surprise discovered mid-implementation again).

If reopening: reuse #178's BST/PAM mechanics (verified sound against current upstream —
`auto_start` flag real, three-stack `optional` wiring matches krytis's existing convention
line-for-line) but do **not** carry `use_authtok` onto the oo7 password-stack line without
checking whether pam_oo7 needs it — upstream's own example omits it, and #178 blindly ported
it from the gnome-keyring line. Also worth checking whether Fedora's Rawhide
`oo7-daemon.spec` has landed by then (queued at the time of the F45 proposal) — it will be a
more authoritative packaging reference than reverse-engineering upstream source.

## Revisit trigger

Re-read this doc and oo7#506 before starting any new #84 attempt. If oo7#506 is still open
with no maintainer-endorsed direction, don't start — leave a comment on #84 instead noting
the re-check and moving on.
