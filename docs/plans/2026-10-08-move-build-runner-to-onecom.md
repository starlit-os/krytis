# Move the build runner to one.com Cloud server L

**Issue:** #1145 · **Branch:** `1145-move-build-runner-to-one-com` · **Worktree:**
`krytis.worktrees/chore/gh1145-move-build-runner-to-one-com` · **Status: cut over 2026-10-09
07:17 UTC; verification (step 5) pending.** `krytis-vps` is now one.com L. The Contabo box is
deregistered, with its runner service removed, and kept for rollback (M6).

Moves the always-on runner `krytis-vps` from the Contabo Cloud VPS 6 to the one.com Cloud
server L that was set up for the cold-build benchmark. The name, labels and workflows stay
as they are: the box behind them changes.

## Why

From `docs/plans/done/2026-10-07-vps-cold-build-benchmark.md` § Results:

| | Contabo (krytis-vps today) | one.com L |
|---|---|---|
| vCPU / RAM / disk | 6 / 11.7 GiB / 197G | 8 / 15.6 GiB / 394G |
| builders × max-jobs (cache-warm's formula) | 2 × 3 | 2 × 4 |
| Cold toolchain closure (159 elements) | 13h43m | 5h50m |
| Cold full build (917 elements) | 31h29m (excluding a 4h44m hung-download stall) | 12h19m |
| Per-element build time | 2.54× L's (141 shared elements ≥1 min) | 1× |
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

- [x] The operator ordered the move on 2026-10-09 ("migrate to one.com runner"). Applied as
      recommended: M1, M2, M3 (`ssh:BenchOnecomL` stays installed until step 7), M6, and M7
      in part (below). **Not applied yet:** M4 (quota stays 100G; L's CAS was 63G at
      cutover, so it fits) and M5 (beszel and materia are not on L).

### 2. Code (one PR, before the cutover)

- [x] `mise/tasks/runner-vps/deregister`: after `svc.sh uninstall`, remove
      `/opt/actions-runner/.runner`, `.credentials` and `.credentials_rsaparams`, so a later
      `register` really re-registers. Update `register`'s comment that tells you to run
      `deregister` first. Landed after the cutover, not before it. It also removes the
      `actions.runner.*.service.d` drop-in directory, which the Contabo inventory below
      found orphaned.
- [x] M4: `cache-warm.yml` quota 200G for `krytis-vps`, with its comment's disk numbers.
      Done in #1159 (#1155); a straight `QUOTA=200G` since #1162 dropped the Blacksmith
      fallback.
- [x] docs/skills/ci-runner.md: record the deregister gap and its fix (§ Always-on VPS
      Runner (issue #794)).
- [x] `mise run docs-links`.

### 3. Prepare L (no registration)

- [x] **Inventory the Contabo box** so nothing is left behind. Skipped at cutover to make
      the 2026-10-09 cron window; done 2026-10-09 afternoon, inside M6. Everything found
      is explained:
      - **ours:** the runner's orphaned `actions.runner.*.service.d` drop-in (now removed
        by `deregister`), `/swapfile` 8G (`provision.sh`), `/opt/actions-runner` with a
        78G CAS;
      - **beszel and materia (M5, #1154):** `beszel-agent` quadlet and container,
        `materia-update.container` with `materia-update.timer`;
      - **Contabo/Debian image defaults:** `exim4` on loopback only, `/etc/cron.d/staticroute`
        (Contabo's network route), the `debian` user, `unattended-upgrades` (also running
        on L), apt's daily timers.
      - Listening sockets: only sshd, systemd-resolved and loopback exim.
      - `sshd -T`: `permitrootlogin without-password`, `passwordauthentication no`, the
        same as L.
- [x] Remove the stale bench registration files on L (the step 2 gap), and the bench-only
      `/opt/actions-runner/_work/_temp/git-mirrors` if a run left it behind. `.runner` and
      `.credentials*` were already absent. The service drop-in directory and `git-mirrors`
      were removed.
- [x] `ssh:KrytisBuild` into root's `authorized_keys` on L (M3), over the `ssh:BenchOnecomL`
      login. Verified a KrytisBuild login with `RUNNER_VPS_HOST=root@<L>` set explicitly.
- [x] ~~`RUNNER_VPS_HOST=root@<L> mise run runner-vps:install`.~~ Not re-run. It ran on
      2026-10-07 for #1126, and `provision.sh` has not changed since.
- [ ] M5: materia + beszel on L (paired `kitten-lily/materia` PR), or recorded as dropped.
      Tracked as #1154. L runs neither on 2026-10-09.

### 4. Cutover (minutes; pick a time with no job on `krytis-vps`)

Do it right after a cache-warm finishes, not near the 01:41 UTC cron. Jobs dispatched during
the gap queue (for up to 24h) rather than fail.

- [x] `gh api repos/starlit-os/krytis/actions/runners` shows `krytis-vps` online and not busy.
      The dispatched cache-warm 37895827873 was cancelled first (06:52 run, cancelled at
      07:08). GitHub refused the first delete with "currently running a job" (HTTP 422) until
      the cancelled job's cleanup finished.
- [x] `mise run runner-vps:deregister` (the vault still points at Contabo). The GitHub delete
      succeeded. The SSH step timed out at the PIN prompt (`LoginGraceTime`), so the Contabo
      service was stopped and uninstalled by hand afterwards, and its `.runner`/`.credentials*`
      removed so a rollback `register` really re-registers.
- [x] M7: repoint the **Krytis Build VPS** vault item at L (`IP Address`, `Hostname`,
      `Operating System`; `Username` stays `root`). The Contabo host is kept in a new field,
      "Previous host (Contabo, rollback until decommission)". `Password` is still Contabo's
      root password. `fnox get` resolves to L. Merging and deleting the bench item: step 7.
- [x] `mise run runner-vps:register` (defaults: name and labels `krytis-vps`, default labels
      kept per M2). Service active 07:17:06 UTC.
- [x] `gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] | "\(.name) \(.status) [\([.labels[].name]|join(","))]"'`
      shows exactly one `krytis-vps`, online, `self-hosted,linux,x64,krytis-vps`.

### 5. Verify on L

- [x] Dispatch `cache-warm.yml`: 917/917 cached, casd quota as M4, 2 × 4 sizing in the
      log. Record the wall time. Pulls from bow are expected for anything the bench's local
      CAS evicted. **37904110098** (2026-10-09 08:18 UTC, dispatched by hand). The
      01:41 UTC cron fired while the benchmark window still had cache-warm disabled, so no
      scheduled run came. Results:
      - log: `8 cores, 15GiB RAM -> builders=2 max-jobs=4 (<=7 concurrent compilers)`,
        `casd quota 100G` (M4 not applied);
      - **917 of 917** cached, build step 47m32s;
      - built 23 (elements changed on `main` since the benchmark: `noctalia` 26m46s,
        `bootc` 26m08s, `oo7`, `image.bst` 5m07s, `umbriel` …), pulled 0, pushed 916 to
        bow, failed 0.
- [x] Dispatch `runner-vps-gc.yml` with `dry_run: true`: it runs and reports. Done as a
      real run on L instead, **37930363709** (2026-10-09): removed `grype@0.120.0`
      (mise installs 637M → 551M), reclaimed 264 MB, disk 93G used of 394G, CAS 73G. The
      dry-run path ran on L through `mise run runner-vps:gc -- --dry-run` (#1159, #1161).
- [ ] Dispatch `build-iso.yml` (unsealed, `publish_r2: false`): an ISO is produced.
      Waiting on a publish the operator is dispatching first.
- [x] The next same-repo PR's `build-changed.yml` runs on L, or open a throwaway PR as #1123 did.
      PRs #1159–#1162 each ran it on `krytis-vps`, machine `cloud-server-10673574`
      (e.g. 37929107309, 11s). None changed an element, so each reported "Nothing to
      build"; element builds on L are covered by cache-warm 37904110098 (23 built).
- [x] `mise run runner-vps:status` without any env override: the vault path works.
      2026-10-09: resolved `root@85.190.122.137`, `krytis-vps: online (busy=false)`, unit
      active since 07:17:06 UTC with the OOM drop-in. The unit reported a 12G memory
      peak and a 980M swap peak (recorded in ci-runner.md § Build concurrency).
- [x] Measure bow pull and push throughput from L for #1128, using the method in that issue.
      ByteStream write of fresh random blobs, then read-back, from three clients (Mbit/s):
      L write 158–176 / read 458–465; workstation 199–202 / 291–315; Contabo 160–249 /
      **51–55**. Writes are similar everywhere (bow-side limit); reads are not
      (client-side). Method and caveats: ci-runner.md § Measuring bow throughput per
      client (#1128).

### 6. Docs

- [x] docs/skills/ci-runner.md § Always-on VPS Runner (issue #794): the host, specs,
      provider, and the co-resident services as of M5 (none yet on L; #1154).
- [x] docs/skills/ci-runner.md § Build concurrency is `builders` x `max-jobs`: current sizing
      2 × 4 on 15 GiB. Keep the Contabo OOM history as history.
- [x] docs/skills/ci-runner.md § casd quota and § The box ships with no swap. The swap
      paragraph names Contabo's image. Whether one.com's image shipped swap was not
      recorded before `provision.sh` added `/swapfile`, so say only what is known.
      § casd quota was rewritten in #1159.
- [x] `cache-warm.yml` and `files/runner-vps/provision.sh` comments that quote "197G",
      "6-vCPU/11GiB" or Contabo as the *current* box (`grep -rn 'Contabo\|197G\|6-vCPU'`).
      Historical incident notes stay.
- [x] `mise run docs-links`.

### 7. Decommission (after the M6 window)

- [ ] Cancel the Contabo VPS. Remove it from beszel/materia if M5 moved them.
- [ ] Delete `ssh:BenchOnecomL` from the YubiKey (`fido2-token -L -k ssh:BenchOnecomL`, then
      `-D -i <id>`), its handle and `.pub` files, and the **Krytis Bench VPS** vault item
      (after M7's merge).
- [ ] Drop the old host from `~/.ssh/known_hosts`.
- [ ] `git mv` this plan to `docs/plans/done/`.

## Rollback (inside the M6 window)

1. `mise run runner-vps:deregister` (the vault points at L).
2. Restore the **Krytis Build VPS** item's `IP Address`, `Hostname` and `Operating System`
   from its "Previous host (Contabo…)" field.
3. `mise run runner-vps:register` against Contabo. Its `/opt/actions-runner` binary and `_work`
   are untouched. Its `.runner`/`.credentials*` were removed at cutover, so `register`
   configures it fresh.
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
