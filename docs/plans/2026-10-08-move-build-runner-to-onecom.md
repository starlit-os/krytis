# Move the build runner to one.com Cloud server L

**Issue:** #1145 · **Branch:** `1145-move-build-runner-to-one-com` · **Worktree:**
`krytis.worktrees/chore/gh1145-move-build-runner-to-one-com` · **Status: draft, waiting on
§ Decisions.** **Blocked by #1126**: krytis-vps's phase 2, `bench-window close` and the
write-up come first. Until the window is closed, the box being replaced is busy with the
benchmark.

Moves the always-on runner `krytis-vps` from the Contabo Cloud VPS 6 to the one.com Cloud
server L that was set up for the cold-build benchmark. The name, labels and workflows stay
as they are: the box behind them changes.

## Why

From `docs/plans/2026-10-07-vps-cold-build-benchmark.md` § Results:

| | Contabo (krytis-vps today) | one.com L |
|---|---|---|
| vCPU / RAM / disk | 6 / 11.7 GiB / 197G | 8 / 15.6 GiB / 394G |
| builders × max-jobs (cache-warm's formula) | 2 × 3 | 2 × 4 |
| Cold toolchain closure (159 elements) | 13h43m | 5h50m |
| Cold full build (917 elements) | about 29–31h, projected [INFERENCE] (phase 2 still running at writing) | 12h19m |
| Per-element build time | 2.2–3.2× L's | 1× |
| Price / month incl. VAT | €9.38 | 211.25 SEK |

The cold full build on krytis-vps exceeds cache-warm's `timeout-minutes: 1440`. On L it
fits with room to spare. That is the case that matters after a junction bump. Neither box
showed CPU steal or meaningful iowait.

## What runs on `krytis-vps` today

Checked against `main` at writing:

- **Workflows** whose `runs-on` names the `krytis-vps` label: `cache-warm.yml` (weekday
  cron), `build-changed.yml` (same-repo PRs), `build-iso.yml` (dispatch),
  `runner-vps-gc.yml` (Sunday cron). `bench-cold-build.yml` can also target it. The box
  carries GitHub's default labels too, so `publish.yml`'s `force_self_hosted` can reach it
  (docs/skills/ci-runner.md § Workflow Runner Choices).
- **Name-keyed behaviour:** `cache-warm.yml` sets `QUOTA=100G` only when
  `RUNNER_NAME = krytis-vps`. `mise.toml` defaults `RUNNER_VPS_NAME` to `krytis-vps`.
- **Access:** `scripts/runner-vps-host.sh` resolves the host from the Krytis vault item
  **Krytis Build VPS** (`Username`, `IP Address`, read by `fnox.toml`'s `RUNNER_VPS_USER` /
  `RUNNER_VPS_IP`). It logs in with `ssh:KrytisBuild` (`RUNNER_VPS_SSH_KEY` default).
- **Co-resident, not managed by this repo** (docs/skills/ci-runner.md § Host-native, not a
  container): `beszel-agent` (monitoring) and `materia-update.container` (the box's
  config-management agent, from `kitten-lily/materia`). Both are root-equivalent through
  `podman.sock`.
- **State:** the local CAS (casd quota 100G), podman storage from `build-iso`, the 8G
  `/swapfile`, and the OOM drop-in from `runner-vps:register`. The CAS refills from bow, and
  everything else is recreated by `install`/`register`.
- **No secrets on disk.** bow tokens arrive per job from GitHub secrets, and R2 credentials
  per step in `build-iso`'s `publish_r2` path.

## Checked while writing

- **`runner-vps:deregister` leaves the box's local runner config behind, and `register`
  then reuses it.** `deregister` deletes the GitHub registration and runs `svc.sh
  stop/uninstall`. It does not remove `/opt/actions-runner/.runner` or `.credentials*`.
  `register` skips `config.sh` whenever `.runner` exists ("already configured — reusing its
  registration"). L was deregistered that way on 2026-10-08, so registering it now would
  reuse the deleted `bench-onecom-l` registration (that name, its labels, no default labels)
  and fail to authenticate. Step 2 fixes `deregister`. Until then, remove the files by hand.
- **L's CPU runs `x86_64_v3` builds**: it built all 917 elements, test suites included, in
  #1126.
- **L's CAS already holds the closure.** #1126 built all 917 elements there, from cold, with
  the same keys `main` had (no build inputs changed during the benchmark). How much survives
  depends on the quota cache-warm sets (D4).
- **SSH on L is key-only** since #1126 step 2: `PasswordAuthentication no`, `ssh_pwauth:
  false`. Root accepts `ssh:BenchOnecomL` only. The one.com `administrator` account
  (passwordless sudo) and its password in the **Krytis Bench VPS** vault item are kept for
  one.com's web console.

## Decisions

| # | Decision | Recommendation and why |
|---|---|---|
| M1 | **Runner name and label** | Keep `krytis-vps`. No workflow, `mise.toml` or quota-rule change, and every doc that names the runner stays correct. The name describes the role, not the provider. |
| M2 | **Default labels** (`self-hosted,linux,x64`) | Keep them, for parity: today's box has them, so `publish.yml`'s `force_self_hosted` behaves exactly as before. Dropping them would also need `force_self_hosted` retargeted at `krytis-vps`. That is a separate change, possibly a better one, not part of a host move. |
| M3 | **SSH credential** | Install `ssh:KrytisBuild` for root on L, so `runner-vps-host.sh`'s default works unchanged. Delete `ssh:BenchOnecomL` from the key and the disk once L is verified. KrytisBuild is named for the role, which moves with the box. |
| M4 | **casd quota on the new box** | Raise from 100G to 200G. The disk is 394G. A quota that holds the whole build closure means fewer evictions and a CAS that survives junction bumps better. The `build-iso` podman storage and `cas/tmp` keep 190G+ of room. Needs `cache-warm.yml`'s quota line and docs/skills/ci-runner.md § casd quota updated. |
| M5 | **beszel-agent and materia on L** | Move them, so monitoring and config management carry on. That is a change in `kitten-lily/materia` (cross-repo exception in AGENTS.md: paired PRs, cross-referenced). Your call: materia's footprint on a runner host is documented as root-equivalent. |
| M6 | **Rollback window** | Keep the Contabo box running but deregistered for 7 days after cutover, then cancel. Check the contract term first: it may decide the date. |
| M7 | **Vault** | Repoint the existing **Krytis Build VPS** item at L (`IP Address`, `Username` `root`, `Hostname`, `Operating System`). Before overwriting, copy the old values into its note, for rollback. Merge the bench item's useful fields (`Password` for the web console, the SSH fingerprint) into it, then delete **Krytis Bench VPS**. |

## Steps

### 1. Decisions

- [ ] A human signs off M1–M7, or amends them here.

### 2. Code (one PR, before the cutover)

- [ ] `mise/tasks/runner-vps/deregister`: after `svc.sh uninstall`, remove
      `/opt/actions-runner/.runner`, `.credentials` and `.credentials_rsaparams`, so a later
      `register` really re-registers. Update `register`'s comment that tells you to run
      `deregister` first.
- [ ] M4: `cache-warm.yml` quota 200G for `krytis-vps`, with its comment's disk numbers.
- [ ] docs/skills/ci-runner.md: record the deregister gap and its fix.
- [ ] `mise run docs-links`.

### 3. Prepare L (no registration)

- [ ] **Inventory the Contabo box** so nothing is left behind:
      `systemctl list-units --type=service --state=running`,
      `ls /etc/containers/systemd/`, `crontab -l`, `ls /etc/cron.d`,
      `ls /etc/apt/apt.conf.d` (unattended upgrades?), `sshd -T | grep -E
      'passwordauth|permitroot'`, `swapon --show`. Anything not explained by
      `provision.sh`, `register`, beszel or materia gets a line here before step 4.
- [ ] Remove the stale bench registration files on L (the step 2 gap), and the bench-only
      `/opt/actions-runner/_work/_temp/git-mirrors` if a run left it behind.
- [ ] `ssh:KrytisBuild` into root's `authorized_keys` on L (M3), over the `ssh:BenchOnecomL`
      login. Verify a KrytisBuild login with `RUNNER_VPS_HOST=root@<L>` set explicitly.
- [ ] `RUNNER_VPS_HOST=root@<L> mise run runner-vps:install`. It is idempotent, and keeps
      the package list at `main`.
- [ ] M5: materia + beszel on L (paired `kitten-lily/materia` PR), or recorded as dropped.

### 4. Cutover (minutes; pick a time with no job on `krytis-vps`)

Do it right after a cache-warm finishes, not near the 01:41 UTC cron. Jobs dispatched during
the gap queue (for up to 24h) rather than fail.

- [ ] `gh api repos/starlit-os/krytis/actions/runners` shows `krytis-vps` online and not busy.
- [ ] `mise run runner-vps:deregister` (the vault still points at Contabo).
- [ ] M7: repoint the **Krytis Build VPS** vault item at L, keeping the old values in its note.
- [ ] `mise run runner-vps:register` (defaults: name and labels `krytis-vps`, default labels
      kept per M2).
- [ ] `gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] | "\(.name) \(.status) [\([.labels[].name]|join(","))]"'`
      shows exactly one `krytis-vps`, online, `self-hosted,linux,x64,krytis-vps`.

### 5. Verify on L

- [ ] Dispatch `cache-warm.yml`: 917/917 cached, casd quota as M4, 2 × 4 sizing in the
      log. Record the wall time. Pulls from bow are expected for anything the bench's local
      CAS evicted.
- [ ] Dispatch `runner-vps-gc.yml` with `dry_run: true`: it runs and reports.
- [ ] Dispatch `build-iso.yml` (unsealed, `publish_r2: false`): an ISO is produced.
- [ ] The next same-repo PR's `build-changed.yml` runs on L, or open a throwaway PR as #1123 did.
- [ ] `mise run runner-vps:status` without any env override: the vault path works.
- [ ] Measure bow pull and push throughput from L for #1128, using the method in that issue.

### 6. Docs

- [ ] docs/skills/ci-runner.md § Always-on VPS Runner (issue #794): the host, specs,
      provider, and the co-resident services as of M5.
- [ ] docs/skills/ci-runner.md § Build concurrency is `builders` x `max-jobs`: current sizing
      2 × 4 on 15 GiB. Keep the Contabo OOM history as history.
- [ ] docs/skills/ci-runner.md § casd quota and § The box ships with no swap. The swap
      paragraph names Contabo's image. Whether one.com's image shipped swap was not
      recorded before `provision.sh` added `/swapfile`, so say only what is known.
- [ ] `cache-warm.yml` and `files/runner-vps/provision.sh` comments that quote "197G",
      "6-vCPU/11GiB" or Contabo as the *current* box (`grep -rn 'Contabo\|197G\|6-vCPU'`).
      Historical incident notes stay.
- [ ] `mise run docs-links`.

### 7. Decommission (after the M6 window)

- [ ] Cancel the Contabo VPS. Remove it from beszel/materia if M5 moved them.
- [ ] Delete `ssh:BenchOnecomL` from the YubiKey (`fido2-token -L -k ssh:BenchOnecomL`, then
      `-D -i <id>`), its handle and `.pub` files, and the **Krytis Bench VPS** vault item
      (after M7's merge).
- [ ] Drop the old host from `~/.ssh/known_hosts`.
- [ ] `git mv` this plan to `docs/plans/done/`.

## Rollback (inside the M6 window)

1. `mise run runner-vps:deregister` (the vault points at L).
2. Restore the **Krytis Build VPS** item from its note.
3. `mise run runner-vps:register` against Contabo. Its `/opt/actions-runner` is untouched by
   the move.
4. Dispatch cache-warm.

## Risks

- **Monthly cost goes up** from €9.38 to 211.25 SEK incl. VAT. That buys a cold full build
  that fits the 24h timeout and a toolchain rebuild 2.35× faster.
- **bow traffic from a new network path is unmeasured** (#1128). cache-warm's push-heavy
  runs could be limited by L's upload rather than its CPU. Step 5 measures it.
- **materia runs root-equivalent** on the new host if M5 moves it. Same exposure as today,
  on a box with more on it.
- **The `build-iso` R2 path** has only run on Contabo. It needs `rclone` from `provision.sh`
  (installed by `install`) and the R2 secrets per step, so nothing is host-specific
  [INFERENCE]. Step 5's unsealed run does not exercise R2; the first real `publish_r2: true`
  run on L does.
