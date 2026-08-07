# Test homed SSH fallback shell — Testing Plan

**Issue:** #422

**Goal:** Answer #422's actual open question — "does `systemd-home-fallback-shell` complete a pubkey-only SSH login end to end for a `systemd-homed` user, including the FIDO2 path?" — with a reproducible, command-level procedure, not just the conceptual "Acceptance" paragraph the issue currently has.

**Why a new plan, not just the issue's existing "Acceptance" section:** that section describes the *end state* ("a homed user can ssh in with a pubkey... land in the fallback shell, authenticate once, end up in a normal shell with `$HOME` mounted") but gives no exact commands, no environment setup, and no way to tell a genuine pass from a false one. This plan fills that in.

**What this is not:** an implementation plan. Per the issue itself and `docs/skills/pam.md`, no krytis code changes are believed necessary — `systemd-home-fallback-shell` is substituted automatically by `nss_systemd` for any homed user whose home is inactive, confirmed already on real hardware (see the `getent passwd`/`userdbctl` transcript already in `docs/skills/pam.md` § systemd-homed users). This plan only proves whether that already-shipped mechanism actually completes an SSH login end to end.

## Environment requirement — read before starting

**This needs a real booted krytis VM or hardware, not a bare `podman run` container.** I attempted to build the whole test inside a rootless container (extending the existing recipe in `docs/skills/pam.md` § "Verifying a PAM stack edit without root or a reboot", which only proves *homed is live on the bus* — it never creates or activates a real home area). That recipe's scope stops well short of what this test needs. Concretely, in this session:

- `dbus-daemon --system --fork --nopidfile` + `systemd-userdbd` + `systemd-homed`, backgrounded by hand in a `podman exec`, come up and answer `busctl` calls (`ListHomes` etc.) — same as the existing recipe.
- `homectl create --identity=<json>` (the standard way to script account creation non-interactively — embed a pre-hashed password under `privileged.hashedPassword` rather than answering the interactive prompt) **hung indefinitely** even with `storage: "directory"` (the simplest non-LUKS backend) and a valid `/etc/machine-id`. No journald in a PID-1-less container to see why (`systemd-homed`'s own stderr goes nowhere retrievable once the backgrounding shell exits).
- Two real gotchas hit along the way, worth keeping even though the attempt didn't finish:
  - `python3 -c 'import crypt'` fails — the `crypt` module was removed in Python 3.13. Use `openssl passwd -6 <password>` for a SHA-512 hash instead (both the built krytis image and most dev hosts have `openssl`).
  - `homectl`/`systemd-homed` need a **real** `/etc/machine-id`, not literally `uninitialized` (default in a fresh container). `systemd-machine-id-setup` didn't populate one reliably in this sandboxed environment; `printf '%032x\n' 1 > /etc/machine-id` (any valid 32-hex-digit value) does. This is the same fact `docs/skills/bst.md`'s `ConditionFirstBoot=yes` note describes from the other direction — machine-id state gates first-boot-ish behavior generally, not just `systemd-firstboot.service`.

Conclusion: proving *homed is reachable* fits in a container; proving *a real home area activates end-to-end* needs the real system plumbing (mount namespaces, LUKS/btrfs subvolume support, or at minimum working process supervision to see actual daemon errors) a container without PID 1 doesn't give you. Use `mise boot-vm` (interactive) or a real installed disk. Don't re-attempt the container-only path without a specific reason to believe it'll behave differently — the four hours a fresh attempt would cost are better spent on the real VM from the start.

## Tech Stack

`mise boot-vm` (or real hardware), `homectl`, `mise fido2:enroll` (`docs/skills/fido2.md`), `ssh -o PreferredAuthentications=publickey`, `journalctl`.

---

### Step 1: Boot a real krytis VM (or use real hardware) with console access

```bash
mise boot-vm
```

Interactive — leaves you with a console into a running krytis instance. (`mise boot-test` is the headless/scripted variant and won't let you interact with the fallback shell's prompts; use `boot-vm` here, not `boot-test`.)

### Step 2: Create a homed test user with a password

From the VM console (or via an existing admin account, e.g. the `homectl firstboot`-created user from #487):

```bash
sudo homectl create sshfallbacktest --member-of=wheel
```

`homectl create` (no `--identity=`) prompts interactively for the password on a real console — answer it directly rather than fighting the non-interactive JSON path (that path is for scripting on a *host* that already has a real system; it's not the blocker here, the container environment was). Pick something you'll type again in Step 5. `--member-of=wheel` is optional but useful for the sudo re-check in Step 7.

Confirm the home is created but leave it **inactive** (don't log into it yet — that's the whole point of the test):

```bash
homectl list
# sshfallbacktest ... inactive ... /bin/bash   <- record's real shell, for contrast
```

### Step 3: Confirm NSS substitutes the fallback shell while inactive

```bash
getent passwd sshfallbacktest
```

Expected: `sshfallbacktest:x:<uid>:<gid>:sshfallbacktest:/:/usr/bin/systemd-home-fallback-shell` — home reported as `/`, shell substituted. This is the exact transcript already recorded in `docs/skills/pam.md` § systemd-homed users for a different user (`fido2test`); confirming it again here for a genuinely never-activated account is the first real checkpoint. If this doesn't match, stop — the rest of the test can't proceed (nothing downstream would trigger the fallback shell at all).

### Step 4: Copy an SSH public key onto the (still-inactive) home from another machine

Homed manages `~/.ssh` inside the encrypted/inactive home, which you can't write to directly while it's inactive. Two options, pick whichever is available:

- **(a) Via `homectl update --ssh-authorized-keys=`** (no need to mount anything):
  ```bash
  sudo homectl update sshfallbacktest --ssh-authorized-keys="$(cat ~/.ssh/id_ed25519.pub)"
  ```
  This is a user-record property (served over `AuthorizedKeysCommand userdbctl ssh-authorized-keys`, already wired per `docs/skills/pam.md` § SSH config drop-ins), not a file write, so it works even while inactive.
- **(b) If (a) isn't available on the krytis version under test**, activate the home once first (`homectl authenticate sshfallbacktest`, enter the password), write `~/.ssh/authorized_keys` normally, then **deactivate it again** (`homectl deactivate sshfallbacktest`) before continuing — the test needs to start from `inactive`, so don't skip the deactivate step.

### Step 5: SSH in with pubkey only, from a second machine (or a second terminal on the same host over loopback)

```bash
ssh -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes \
    sshfallbacktest@<vm-ip-or-127.0.0.1>
```

Expected sequence, in order:
1. No password/keyboard-interactive prompt from sshd itself (confirms krytis's key-only posture, `docs/skills/pam.md` § key-only SSH, is unaffected).
2. The session lands you **in the fallback shell's own prompt**, not a normal shell — it should re-prompt for a password (or, for the FIDO2 variant in Step 8, ask you to touch the key) to *activate* the home. This is `systemd-home-fallback-shell` running as your login shell and driving its own interactive auth, independent of SSH's own auth phase.
3. After answering correctly, you should land in a **real** shell (`bash`, per the record's actual shell) — not back in the fallback shell.

If step 2 never happens and you instead land directly in a shell (or the connection is refused/closed), that is a **fail** — record exactly what happened (verbatim session transcript) rather than summarizing, since the failure mode is the useful signal for whoever picks this up next.

### Step 6: Verify the landed session, not just that a shell appeared

In the same SSH session, once you believe you've landed in a real shell:

```bash
echo "HOME=$HOME"
echo "XDG_SESSION_INCOMPLETE=[$XDG_SESSION_INCOMPLETE]"
mount | grep sshfallbacktest
id
```

Expected: `$HOME` is the real mounted path (`/home/sshfallbacktest` or wherever homed mounts it — **not** `/`), `XDG_SESSION_INCOMPLETE` is empty (`[]`), `mount` shows a real entry for the user's home, `id` shows `wheel` in the group list (from Step 2's `--member-of`).

**This step is not optional.** A shell prompt alone doesn't prove the home activated — it's possible to land in *some* shell (even a broken/fallback one) without `$HOME` ever mounting. Per `docs/skills/pam.md`'s own stated methodology for this exact class of bug ("Always assert the home is actually mounted... a smoke test that only checks *whether* login succeeds will pass on a completely broken configuration"), don't shortcut this check.

### Step 7: Confirm sudo works from the landed session (exercises a second PAM path with the now-active home)

```bash
sudo -n true && echo "sudo OK (should fail — NOPASSWD not expected here)"
sudo whoami
```

`sshfallbacktest` was created with `--member-of=wheel`, and `wheel`'s sudoers rule requires a password (`%wheel ALL=(ALL) ALL`, per `docs/skills/desktop.md`/fdsdk's `vm/config/sudo.bst`) — so `sudo -n true` should fail (no cached credentials, password required), and `sudo whoami` should prompt for the account's password and succeed once entered. This confirms the activated home's `pam_u2f`/`pam_unix` stack works normally post-fallback-shell, not just that the SSH session itself is alive.

### Step 8: Repeat Steps 2–7 for the FIDO2 path

Create a second test user and enroll a FIDO2 credential the same way #409's flow does:

```bash
sudo homectl create sshfallbackfido2
# ... as sshfallbackfido2, or as an admin on its behalf:
mise fido2:enroll   # docs/skills/fido2.md — homectl update --fido2-device=auto for a homed user
```

Repeat Step 4 (authorized key) and Step 5 (SSH in). At the fallback shell's re-prompt, this time it should ask for **touch** (and PIN, if the key requires one) rather than a password — confirm the key's LED blinks / the touch cue appears, touch it, and confirm the same landed-session checks from Steps 6–7 pass.

### Step 9: Record the outcome in `docs/skills/pam.md`

Per #422's own acceptance criteria ("plus a `docs/skills/pam.md` entry recording the outcome") and this repo's self-improvement-loop mandate (`AGENTS.md`), add a new subsection near the existing "systemd-homed users" section documenting:

- Pass/fail for both the password and FIDO2 variants, with the exact transcripts from Steps 5–8 (verbatim, not paraphrased — matching how `docs/skills/pam.md` already quotes real `getent passwd`/`userdbctl` output rather than describing it).
- If it failed: the exact point of failure (which step, what appeared instead of what was expected) and any journal lines (`journalctl -b -u sshd -u systemd-homed --no-pager` on the VM) captured at the time.
- If it passed: whether Step 4's option (a) (`--ssh-authorized-keys=` while inactive) actually worked, since that was flagged as uncertain above — this closes a real gap in the current docs.
- Explicitly correct or confirm the existing sentence in `docs/skills/pam.md` § "Two consequences of key-only SSH" that currently ends with *"So the open question for #422 is not 'how do we install it' but 'does it actually work... which is a test, not an implementation"* — replace "is a test" language with the actual result once this plan has been run.

### Step 10: Close the loop on the issue

Comment on #422 with a link to the `docs/skills/pam.md` update and a one-line verdict (pass/fail/partial). If it passed cleanly, close #422. If Step 4 needed option (b) instead of (a), or Step 5/8 failed, leave #422 open with the specific gap now precisely identified (this plan's whole purpose is to convert "needs testing" into either "confirmed working" or a precisely diagnosed remaining bug — not to leave the issue exactly as vague as it started).
