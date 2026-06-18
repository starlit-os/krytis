# Verification: Self-Hosted Runner

**Legend:**
- `[R]` Remote-control — Claude can run this via bash
- `[L]` Local — requires interactive terminal, sudo, or browser on the local machine

---

## Pre-flight

| # | Step | How |
|---|------|-----|
| 1 | `[L]` **Set user namespaces** if restricted | `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` — only needed if `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns` returns `1`. Bubblewrap (BST sandbox) requires this. |
| 2 | `[R]` **Build image** | `mise run runner:build` |

## Start-up

| # | Step | How |
|---|------|-----|
| 3 | `[L]` **First-time PAT entry** | `mise run runner:start` — `gum input` prompts for the PAT on the first run. Requires an interactive terminal. Once the PAT is stored in podman secrets, subsequent starts are non-interactive. |
| 4 | `[R]` **Subsequent starts** (PAT already stored) | `mise run runner:start` |
| 5 | `[R]` **Check container running** | `mise run runner:status` |
| 6 | `[R]` **Check runner registered on GitHub** | `gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] \| {name,status,labels}'` — runner should appear with `status: online`. |

## Functional test

| # | Step | How |
|---|------|-----|
| 7 | `[R]` **Patch `cache-warm.yml`** (test only) | Change `runs-on:` to `[self-hosted, linux, x64]` on the feature branch. |
| 8 | `[R]` **Trigger workflow** | `gh workflow run cache-warm.yml` |
| 9 | `[R]` **Watch run** | `gh run watch` — wait for completion. |
| 10 | `[R]` **Follow runner logs** | `mise run runner:logs` (in parallel with step 9). |
| 11 | `[R]` **Revert `runs-on:`** | Restore `blacksmith-8vcpu-ubuntu-2404` after test passes. |

## Shut-down

| # | Step | How |
|---|------|-----|
| 12 | `[R]` **Stop runner** | `mise run runner:stop` |
| 13 | `[R]` **Verify deregistered** | `gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] \| {name,status}'` — `krytis-local` should be absent. |

---

## Notes

- Steps 3 and 4 use the same task (`runner:start`). The only difference is whether the
  `gh-token` podman secret already exists. After step 3, all subsequent runs are `[R]`.
- Step 1 (sysctl) is a one-time host configuration. It resets on reboot — add to
  `/etc/sysctl.d/` or the systemd user service (see `runner-followup.md`) if you want
  it persistent.
- Steps 7–11 are a temporary test; do not merge `cache-warm.yml` targeting self-hosted
  until the run in step 9 succeeds. See `runner-followup.md` §1 for the permanent migration.
