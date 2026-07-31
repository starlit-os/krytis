# Fix inert ssh config drop-ins + set key-only SSH auth

**Issue:** #408
**Branch:** `408-fix-inert-ssh-config-drop-ins`
**Depends on:** #404 (merged) — supplies `elements/core/openssh.bst`, the override element these changes land in.

---

## Problem

The image ships systemd's SSH drop-ins and tmpfiles symlinks both into place, but
neither `sshd_config` nor `ssh_config` contains an `Include` line — not even a
commented one — so **neither drop-in is ever read**.

```console
$ grep -rniE '^[[:space:]]*#?[[:space:]]*include' /etc/ssh/sshd_config /etc/ssh/ssh_config
  (no output)
$ sshd -T | grep -i authorizedkeyscommand
authorizedkeyscommand none
```

Upstream OpenSSH ships no `Include`; Fedora, Debian and Arch each patch one in.
Freedesktop SDK ships systemd's drop-in *mechanism* without that distro-side
`Include`, so the drop-in directories look like a working config surface and are
not one.

Consequences, in order of practical weight:

1. **Client:** `ssh vsock/<cid>`, `ssh machine/<name>`, `ssh unix/<path>` and
   `ssh .host` do not resolve from a krytis machine, because
   `ssh_config.d/20-systemd-ssh-proxy.conf`'s `ProxyCommand` blocks never load.
   Note the asymmetry — `systemd-ssh-generator` *does* emit
   `sshd-unix-local.socket` and `sshd-vsock@.service` in a krytis guest, so a
   krytis guest is reachable this way but a krytis host cannot dial it.
2. **Server:** `sshd_config.d/20-systemd-userdb.conf`'s
   `AuthorizedKeysCommand userdbctl ssh-authorized-keys` never applies, so
   credential-provided keys (`ssh.authorized_keys.<user>`), `/etc/userdb` records
   and `homectl` user records all yield no SSH key. Classic `useradd` accounts are
   unaffected — `~/.ssh/authorized_keys` works — which is why this went unnoticed.
3. **Nothing can be configured by drop-in**, so any krytis SSH policy would
   otherwise have to be another `sed` against the main config file, which is how
   the current mess arose.

## Decisions taken

**Ship both `Include` lines** (issue option 1) rather than the client-only subset
or deleting the symlinks. The mechanism is already half-present; completing it is
cheaper than removing it, and it gives krytis a supported place to put SSH policy.

**Set `PasswordAuthentication no` and `KbdInteractiveAuthentication no`**, as a
krytis drop-in — which is only possible once the `Include` exists, hence one PR.

Rationale: `sshd.service` ships `disable`d by preset, so this sets the posture
*when a user opts in*, not shipped behaviour. `PermitRootLogin prohibit-password`
already establishes key-only intent for root; extending it to all accounts is
consistent. Native FIDO2 SSH keys are compiled in
(`--with-security-key-builtin`) and advertised — `sk-ssh-ed25519@openssh.com`,
`sk-ecdsa-sha2-nistp256@openssh.com` — so hardware-token auth works over pubkey
and needs no keyboard-interactive path. Lockout recovery is via console; this is a
desktop, not a headless server.

**Both settings are required, not just `PasswordAuthentication`.** With
`UsePAM yes`, keyboard-interactive hands the challenge to PAM, which prompts for a
password. Verified against this image:

```
# PasswordAuthentication no, KbdInteractiveAuthentication yes, UsePAM yes
debug1: Authentications that can continue: publickey,keyboard-interactive
# both no
debug1: Authentications that can continue: publickey
```

Accepted consequences, to be recorded in the skill docs:

- **Incompatible with homed-managed homes.** `pam_systemd_home` needs the user's
  password to unlock the encrypted home, so pubkey-only SSH has nothing to mount
  it with. Harmless today (accounts are `useradd` per
  `docs/skills/desktop.md` § `/etc/skel`), but it constrains any future move to
  `homectl`.
- **No PAM-driven 2FA over SSH** (`pam_u2f`). Native `sk-*` keys replace it.

Both consequences are the subject of **#409 (Fix FIDO2 login for homed users)**.
If #409 concludes that homed becomes the account model, `KbdInteractiveAuthentication`
has to come back for SSH and this drop-in needs revisiting — the two decisions are
coupled, so land whichever is decided first and adjust the other.

## Rejected alternatives

| Option | Why not |
|---|---|
| Client `Include` only | Leaves the server gap and the misleading drop-in dir; the auth decision does not get easier by deferring it |
| Delete both tmpfiles symlinks | Throws away working upstream functionality to avoid a two-line fix |
| Ship policy to `/usr/lib/ssh/sshd_config.d/` + a second `Include` | Cleaner vendor/admin split in theory, but invents a path with no upstream precedent for one file. `/etc/ssh/sshd_config.d/` is where the tmpfiles symlink already assembles drop-ins, and `%{sysconfdir}` config is the established pattern in `elements/config/*.bst` |
| Patch `sshd_config` directly with the auth policy | Another `sed` against the upstream file — exactly the pattern that produced this issue |

## Tasks

### 1. `elements/core/openssh.bst` — add both `Include` lines

Prepend, do not append. OpenSSH keeps the **first** value obtained for most
keywords, and the shipped `sshd_config` already sets `AuthorizedKeysFile` at line
41 — an `Include` after it could never be overridden by a drop-in. The client
`ssh_config` says the same thing in its own header comment ("host-specific
definitions should be at the beginning").

Extend the existing `install-commands` `sed` block (same place the `UsePAM`
rewrite lives). Use `%{sysconfdir}` (overridden to `/etc/ssh` in this element) so
the path stays derived.

Also update the `KNOWN GAP` comment added by #404 — it is no longer a gap.

### 2. New `elements/config/ssh-auth-policy.bst`

Ships `/etc/ssh/sshd_config.d/10-krytis-auth.conf` with both auth settings and a
comment explaining why both are needed. `kind: manual`, `strip-binaries: ''` plus
a no-op `strip-commands` — the config-element pattern from `config/oomd.bst` and
`config/greetd-config.bst`.

Numbered `10-` so krytis policy is read before systemd's `20-systemd-userdb.conf`.
They set disjoint keywords today, so ordering is precautionary rather than load-bearing.

### 3. Wire into `elements/stacks/base-system.bst`

Next to the existing `components/openssh.bst` / `components/openssh-systemd.bst`
entries, with a comment pointing at the issue.

### 4. Skill docs

- `docs/skills/bst.md` — the openssh case study's "Separate gap found while
  retracting it" note becomes a description of the fix.
- `docs/skills/pam.md` — new section on the `UsePAM` + `KbdInteractiveAuthentication`
  interaction, since that is the trap and it is PAM-caused.

## Verification

| Check | Command | Expected |
|---|---|---|
| Include present and first | `head -5 /etc/ssh/sshd_config` | `Include …/sshd_config.d/*.conf` before any keyword |
| userdb drop-in now live | `sshd -T \| grep authorizedkeyscommand` | `/usr/bin/userdbctl ssh-authorized-keys %u` |
| Auth policy applied | `sshd -T \| grep -E 'passwordauth\|kbdinteractive'` | both `no` |
| Only pubkey offered | `ssh -v` to a container sshd | `Authentications that can continue: publickey` |
| Pubkey still works | key in `~/.ssh/authorized_keys`, login | succeeds |
| Client proxy live | `ssh -G vsock/3 \| grep proxycommand` | `systemd-ssh-proxy` |
| `boot-test` unaffected | `mise boot-test --secure` | PASS — it passes `-o "AuthorizedKeysFile …"` on the command line, and `-o` beats config files |

`mise run build` for a real rebuild — `mise lint` alone would test stale content
(see `docs/skills/bst.md`). The container checks cover everything except a live
boot; `mise boot-test --secure` needs root for `generate-disk` and is the final
gate.

## Risk

Low. `sshd.service` is disabled by preset, so nothing is exposed until a user
enables it. The one way this could bite an existing user is if they had already
enabled sshd *and* relied on password auth — for them this is a breaking change,
which is why it belongs in a release note rather than a silent bump.
