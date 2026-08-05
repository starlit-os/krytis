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
Neither runs today, and neither is usable as shipped:

- `systemd-firstboot.service` is neutered by the kernel arg
  `systemd.firstboot=no` (`files/bootc-config/40-no-firstboot.toml`). It was
  added because the unit's default `ExecStart` passes
  `--prompt-root-password`, and `root:!unprovisioned` reads as "no password
  set" — the prompt then waits forever (`TimeoutStartSec=infinity`) on a
  console nothing answers, and because the unit is `Before=sysinit.target`,
  the *entire* boot stalls: greetd, sshd, logind, networking — nothing after
  `sysinit.target` starts.
- `systemd-homed-firstboot.service` (which runs `homectl firstboot`, the
  systemd-homed equivalent — interactively creates a homed-managed user if
  none exists) is `disable`d by freedesktop-sdk's own preset. It is ordered
  `Before=systemd-user-sessions.service`, also with no timeout — the same
  class of hang, one target later: an unanswered prompt blocks all logins.

## Decision

Krytis ships **its own unit**, `krytis-firstboot.service`, which runs both of
systemd's wizards in sequence on a reserved VT, off the critical boot path.
Both upstream units are **neutralised in place**. Root stays locked; the
created user is the sudoer.

### Why not drop-ins on the upstream units

The obvious approach — keep both upstream units and fix them with drop-ins —
cannot work, and failing quietly is the trap:

**systemd's dependency directives are purely additive in drop-ins.** An empty
`Before=` does *not* reset the accumulated list, unlike `ExecStart=` and most
other list-valued settings. So `Before=sysinit.target` and
`Before=systemd-user-sessions.service` survive any drop-in, and the units stay
exactly as boot-blocking as before while *appearing* to be fixed. Verified on
systemd 260 — see `docs/skills/bootc-vm.md`
§ Dependency directives cannot be reset from a drop-in.

A preset cannot retire `systemd-firstboot.service` either: it is `static` (no
`[Install]` section), pulled in by systemd's own shipped
`sysinit.target.wants/systemd-firstboot.service` symlink, which
`systemctl disable` does not touch. And overwriting the unit file in
`/usr/lib/systemd/system/` would collide with the file freedesktop-sdk's
systemd element already provides there.

What a drop-in *can* reach is `ExecStart=`, which is resettable. So both
upstream units get `ExecStart=/usr/bin/true` plus `StandardInput=null`: they
still run, instantly and silently, cannot prompt, and cannot stall the target
they are ordered before. `first-boot-complete.target` is satisfied as usual.

### The krytis unit

| Step | Command | Notes |
|---|---|---|
| keymap + timezone (optional) | `systemd-firstboot --prompt-keymap-auto --prompt-timezone --welcome=no --mute-console=yes` | No locale prompt, no root-password prompt. `--prompt-keymap-auto` self-skips when not invoked on a local VT, so a serial-only session is never blocked. Values already present in `/etc` are skipped (no `--force`), so `/etc/localtime` being pre-set to UTC means only keymap normally prompts. |
| initial user (required) | `homectl firstboot --prompt-new-user --prompt-shell=no --prompt-groups=no --member-of=wheel --mute-console=yes` | systemd-homed managed (encrypted home, FIDO2-login-ready, matching the PAM/FIDO2 investment already in the repo), auto-granted `wheel` (sudo, `%wheel ALL=(ALL) ALL` from fdsdk's `vm/config/sudo.bst`) rather than prompted — the first-boot user *is* the admin account. `--prompt-groups=no` is load-bearing for that: were the groups prompt left on, an interactive answer would overwrite `memberOf` wholesale (`homectl.c`, `create_interactively()`). |

Both steps run from one script (`/usr/libexec/krytis/firstboot-wizard.sh`)
rather than two units, because the unit is `Type=exec` — a second unit ordered
`After=` the first would start as soon as the first was *exec'd*, not when it
finished, and the two wizards would fight over the same VT.

Key properties of `krytis-firstboot.service`:

- **`WantedBy=multi-user.target`, and no `Before=` on anything on the boot
  path.** `Wants=` implies no ordering, so `multi-user.target` /
  `graphical.target` activate without waiting for the wizard. An unattended
  boot (CI, headless, or a human who hasn't sat down yet) always reaches a
  healthy graphical session regardless of whether anyone answers.
- **`Type=exec`, not `Type=oneshot`.** The start job must complete as soon as
  the wizard is exec'd. A oneshot keeps its job pending until `ExecStart`
  returns, which leaves `systemctl is-system-running` reporting `starting` for
  as long as the prompt goes unanswered — and `mise boot-test` asserts health
  with `is-system-running --wait`, so a oneshot would *hang* the gate rather
  than fail it.
- **`TTYPath=/dev/tty5`** (Ctrl+Alt+F5), not `/dev/console` and not tty2:
  `greetd` is fixed at `vt=1` (`greetd-config.bst`) and `config/kmscon.bst`
  claims vt2–4 for kmscon. tty6 is logind's `ReserveVT`, where a getty is
  spawned *unconditionally*, so tty5 is the first VT free of all three.
- **`Conflicts=getty@tty5.service` + `Before=getty@tty5.service`** to win the
  VT back if a getty got there first. This does not backfire once the wizard
  holds the VT: logind refuses to spawn a getty over a busy VT
  (`logind-core.c`, `manager_spawn_autovt()` → `vt_is_busy()` → `-EBUSY`), so
  switching to tty5 to *use* the wizard cannot kill it. `autovt@tty5.service`
  is deliberately not listed — it is an alias of the same `getty@.service`
  unit, so naming it adds nothing.
- **Gated on `/var/lib/krytis/firstboot-done`, not `ConditionFirstBoot=yes`.**
  This is a direct consequence of `Type=exec`: the start job completes
  immediately, so first-boot state gets committed
  (`systemd-machine-id-commit.service`) while the prompt is still waiting for
  input. Under `ConditionFirstBoot=yes` a first boot nobody answered would
  therefore never prompt again — stranding the machine with no account and a
  locked root, the exact failure this design exists to prevent. The marker is
  written only once a regular user really exists, so a skipped or aborted
  wizard comes back on the next boot. Both steps are idempotent, which is what
  makes re-running safe: `systemd-firstboot` skips already-set values, and
  `homectl firstboot` returns without prompting once a regular user exists
  (`homectl.c`, `has_regular_user()`).

`files/bootc-config/40-no-firstboot.toml` (the `systemd.firstboot=no` karg) is
deleted. This is now required rather than merely tidy: `homectl firstboot`
honours that karg too (`homectl.c`, `verb_firstboot()` sets
`arg_prompt_new_user = false`), so leaving it in place would silence krytis's
own wizard as well as upstream's.

## Consequence: the greeter is reachable before any account exists

`greetd`/`noctalia-greeter` starts and shows its login screen immediately —
it does not wait on the first-boot unit. On a genuinely fresh install
there is nothing to log into yet; the actual setup wizard is on tty5
(Ctrl+Alt+F5), which is not discoverable from the greeter itself. Making
the greeter surface a hint is an upstream noctalia-greeter UI feature, not
something krytis owns — out of scope here. This is a known, accepted
first-run rough edge, not a regression: today there is no in-band recovery
path *at all* (an operator needs a second machine / recovery shell to
`useradd`), so tty5 being merely undiscoverable is already strictly better.
A follow-up could file an upstream issue for a "no accounts configured"
state in noctalia-greeter, or ship a `/etc/motd`-style hint that shows on
any console session, if this proves confusing in practice.

## What this does not attempt

- No locale prompt (only keymap + timezone were asked for) — locale stays
  whatever `config/locale-data.bst` bakes into the image.
- No root password prompt — root stays locked by design, matching the
  existing shadow entry and the sudo-rs/pangolin passwordless-sudo posture.
- No changes to `noctalia-greeter` or any graphical wizard — this is the
  stock systemd TTY-based first-boot flow, not a bespoke one. The only
  krytis-authored code is the sequencing script.
- No credential-based (non-interactive) provisioning path is added, though
  the unit still honors `ImportCredential=firstboot.*` / `home.*` for free
  if a future installer wants to feed values via systemd credentials — that
  wiring is not built here.

## Alternatives considered

- **Drop-ins on the two upstream units**, keeping them enabled. Rejected: does
  not work at all — see *Why not drop-ins on the upstream units* above. This
  was the first implementation of this design and it silently retained
  `Before=sysinit.target`, reintroducing the very hang the deleted karg was
  suppressing.
- **Full replacement copies of both upstream unit files** in
  `/usr/lib/systemd/system/`. Rejected: collides with the files
  freedesktop-sdk's systemd element already installs at those paths, and
  carries the unit definitions as permanent forks to re-sync on every systemd
  bump.
- **Masking the upstream units** via `/etc/systemd/system/<unit> → /dev/null`.
  Rejected: no krytis element ships into `/etc` today (image config lives in
  `/usr`, per bootc convention), and the `ExecStart=/usr/bin/true`
  neutralisation achieves the same thing inside the existing convention.
- **Classic `useradd` via a first-boot oneshot script**, instead of
  `homectl firstboot`. Rejected: duplicates functionality systemd already
  ships and tests upstream, and stands up a second account model next to the
  FIDO2/PAM homed support already built (`docs/skills/pam.md`,
  `docs/skills/fido2.md`) rather than unifying on it.
- **Keeping the wizard ordered before `sysinit.target`/login (blocking)**, with
  a bounded timeout instead of a full input wait. Rejected in favor of
  fully decoupling from the boot-critical path — a timeout still risks
  flakiness under slow/loaded CI boots, and the non-blocking design has no
  failure mode to tune.
