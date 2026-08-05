# First-Boot Setup: Initial User, Keymap, Timezone

## Problem

Krytis ships with no first-boot user creation. `root` is locked
(`root:!unprovisioned` in `/etc/shadow`) and no other account exists —
today an operator has to `useradd` manually (console or SSH) before the
machine is usable at all. There is also no first-boot path for keymap or
timezone selection.

systemd already ships the tooling for this (`systemd-firstboot.service`,
`systemd-homed-firstboot.service`), and krytis already has both in the
image (`base-system.bst` depends on `freedesktop-sdk.bst:vm/config/
systemd-homed-firstboot.bst` and krytis's own `config/systemd-firstboot.bst`).
Neither runs today:

- `systemd-firstboot.service` is enabled, but neutered by the kernel arg
  `systemd.firstboot=no` (`files/bootc-config/40-no-firstboot.toml`). It was
  added because the unit's default `ExecStart` passes
  `--prompt-root-password`, and `root:!unprovisioned` reads as "no password
  set" — the prompt then waits forever on a console nothing answers
  (headless, serial-only, or UKI/secure-boot boots), and because the unit is
  `Before=sysinit.target`, the *entire* boot stalls: greetd, sshd, logind,
  networking — nothing after `sysinit.target` starts.
- `systemd-homed-firstboot.service` (which runs `homectl firstboot`, the
  systemd-homed equivalent — interactively creates a homed-managed user if
  none exists) is `disable`d by freedesktop-sdk's own preset. It is ordered
  `Before=systemd-user-sessions.service` with no timeout — the same class of
  hang, one target later: an unanswered prompt blocks all logins.

## Decision

Re-enable both units, but move them **off the critical boot path** so an
unattended boot (CI, headless, or a human who hasn't sat down yet) always
reaches a healthy graphical session regardless of whether anyone answers.
Root stays locked; the created user is the sudoer.

| Unit | Purpose | ExecStart override |
|---|---|---|
| `systemd-firstboot.service` | keymap + timezone (optional) | `systemd-firstboot --prompt-keymap-auto --prompt-timezone --welcome=no` — no locale/root-password prompt. `--prompt-keymap-auto` (added systemd 259) self-skips when not invoked on a local VT, so it never blocks a serial-only session either. |
| `systemd-homed-firstboot.service` | initial user (required) | `homectl firstboot --prompt-new-user --prompt-shell=no --prompt-groups=no --member-of=wheel --mute-console=yes` — systemd-homed managed (encrypted home, FIDO2-login-ready, matching the PAM/FIDO2 investment already in the repo), auto-granted `wheel` (sudo, see fdsdk's `vm/config/sudo.bst` → `/etc/sudoers.d/wheel`) rather than prompted — the first-boot user *is* the admin account, matching every other bootc/desktop-OS first-run flow. |

Both units:

- Have `Before=` cleared of `sysinit.target` / `systemd-user-sessions.service`
  (systemd list-type directives: an empty assignment in a drop-in resets the
  accumulated list; `Before=first-boot-complete.target shutdown.target` is
  re-added since that ordering is still correct and harmless).
- Get `TTYPath=/dev/tty2` so they run on a dedicated, reserved VT instead of
  `/dev/console` — `greetd` is fixed at `vt=1` (`greetd-config.bst`) and
  must not be contended for.
- Get `Conflicts=getty@tty2.service autovt@tty2.service` +
  `Before=getty@tty2.service autovt@tty2.service` so `systemd-logind`'s
  on-demand `autovt@` spawn (triggered when a user switches to an
  unoccupied VT) can't race the wizard for ownership of tty2.
- `systemd-homed-firstboot.service` gets `After=systemd-firstboot.service`
  so the two run in a sensible order on the shared VT (settings, then
  account) — not because the new keymap is live for the second prompt
  (`systemd-firstboot` only writes `vconsole.conf` for the *next* boot; the
  running VT's keymap is unaffected until then), but because it's the
  conventional wizard order.

`files/bootc-config/40-no-firstboot.toml` (the `systemd.firstboot=no` karg)
is deleted — root-password prompting is now removed at the `ExecStart`
level, which is more precise than suppressing it globally, and the karg
would otherwise also suppress the keymap/timezone prompts.

freedesktop-sdk ships `systemd-homed-firstboot.service` `disable`d by its
own preset file (`systemd-homed-firstboot.preset`, unprefixed). krytis's
override ships as a numerically-prefixed file
(`80-systemd-homed-firstboot.preset`); preset resolution takes the first
matching filename in sort order, and digits sort before letters, so ours
wins without touching or masking fdsdk's file. Same pattern krytis already
uses for `systemd-firstboot.service` (`80-systemd-firstboot.preset`).

## Consequence: the greeter is reachable before any account exists

`greetd`/`noctalia-greeter` starts and shows its login screen immediately —
it does not wait on either first-boot unit. On a genuinely fresh install
there is nothing to log into yet; the actual setup wizard is on tty2
(Ctrl+Alt+F2), which is not discoverable from the greeter itself. Making
the greeter surface a hint is an upstream noctalia-greeter UI feature, not
something krytis owns — out of scope here. This is a known, accepted
first-run rough edge, not a regression: today there is no in-band recovery
path *at all* (an operator needs a second machine / recovery shell to
`useradd`), so tty2 being merely undiscoverable is already strictly better.
A follow-up could file an upstream issue for a "no accounts configured"
state in noctalia-greeter, or ship a `/etc/motd`-style hint that shows on
any console session, if this proves confusing in practice.

## What this does not attempt

- No locale prompt (only keymap + timezone were asked for) — locale stays
  whatever `config/locale-data.bst` bakes into the image.
- No root password prompt — root stays locked by design, matching the
  existing shadow entry and the sudo-rs/pangolin passwordless-sudo posture.
- No changes to `noctalia-greeter` or any graphical wizard — this is the
  stock systemd TTY-based first-boot flow, not a bespoke one.
- No credential-based (non-interactive) provisioning path is added, though
  both units still honor `ImportCredential=firstboot.*` / `home.*` for free
  if a future installer wants to feed values via systemd credentials — that
  wiring is not built here.

## Alternatives considered

- **Classic `useradd` via a first-boot oneshot script**, instead of
  `systemd-homed-firstboot.service`. Rejected: duplicates functionality
  systemd already ships and tests upstream, and a second account model next
  to the FIDO2/PAM homed support already built (`docs/skills/pam.md`,
  `docs/skills/fido2.md`) rather than unifying on it.
- **Keep both units ordered before `sysinit.target`/login (blocking)**, with
  a bounded timeout instead of a full input wait. Rejected in favor of
  fully decoupling from the boot-critical path — a timeout still risks
  flakiness under slow/loaded CI boots, and the non-blocking design has no
  failure mode to tune.
