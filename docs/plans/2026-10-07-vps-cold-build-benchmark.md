# Benchmark cold-cache builds: krytis-vps vs one.com L

**Issue:** none · **Branch:** `docs/vps-cold-cache-benchmark-plan` · **Worktree:**
`krytis.worktrees/docs/vps-cold-cache-benchmark-plan` · **Status: ready.** The Security Gate
(§ Decisions, D5) was approved on 2026-10-07: registering a third-party host as a repo runner,
inside the window. Next is step 1. Cloud server M was dropped the same day, leaving one one.com
box.

Measures how long a cold-cache build takes on today's runner and on one.com Cloud server L. Here
"cold" means an empty local cache and no artifact remote. This is the build a junction bump
forces on cache-warm. The result is input for a human decision on whether to replace
krytis-vps. This plan does not make that decision.

## Machines

| Name | Provider / plan | vCPU | RAM | Disk | Slots under today's formula |
|---|---|---|---|---|---|
| `krytis-vps` | Contabo Cloud VPS 6 | 6 | 12 GB (11 GiB `MemTotal`) | 200 GB | 5 → builders 2 × max-jobs 3 = 6 |
| `bench-onecom-l` | one.com Cloud server L | 8 | 16 GB | 400 GB NVMe | ~7 (15 GiB) → 2 × 4 = 8 |

one.com specs come from <https://www.one.com/en-gb/vps/>, checked 2026-10-07. The page
names AMD EPYC CPUs and OpenStack, and lists Debian among the OS images without a version.
Prices are rendered client-side and the search snippets disagree with each other, so fill
in the **renewal** price, not the intro price, from the order page in step 2.

The one.com slot counts are estimates until step 3 records the real `MemTotal`.

## Checked while writing

- **No run has ever built the full closure cold.** The last toolchain rebuild took four
  dispatches, 2026-10-02 to 2026-10-05: 37003574522 (two attempts, both cancelled),
  37108048862 and 37296270943. Each one pulled whatever the one before had pushed. Per-element
  times survive in the cache-report artifacts of the last two. 37003574522 predates the
  report and has no artifacts. Known element times on krytis-vps: `components/llvm.bst`
  4h12m, `components/rust.bst` 1h04m (37108048862), `bootstrap/gcc` 70m and
  `bootstrap/build/gcc-stage2` 61m (docs/skills/ci-runner.md § A toolchain rebuild does
  not fit in 6 hours). So a cold full closure probably takes more than 24h there
  `[INFERENCE]`, longer than cache-warm's `timeout-minutes: 1440`.
- **The closure is 917 elements, 67 of them toolchain** (cache report of 37515434814).
- **Without bow, nothing can be pulled.** Every fdsdk key and every gbm key diverges under
  `x86_64_v3`. The declared remotes (`cache.freedesktop-sdk.io`, and gbm's own) can never hold
  them (project.conf header; docs/skills/ci-runner.md § Why every freedesktop-sdk artifact
  pull missed). A build with no bow config is therefore cold by construction. Step 1's
  `Pulled from a remote = 0` assertion proves it for each run.
- **The sizing formula overshoots its own budget.** `MAX_JOBS = ceil(SLOTS / BUILDERS)` with
  `BUILDERS=2` gives `2 × ceil(SLOTS/2)`, which is one compiler more than `SLOTS` whenever
  `SLOTS` is odd. krytis-vps (5 slots) runs 6 today; L (about 7) would run 8. The benchmark
  measures the formula as it is, because that is what production would run. Recorded in
  docs/skills/ci-runner.md § Build concurrency is `builders` x `max-jobs`, not fixed here.
- **`publish.yml`'s `force_self_hosted` matches any runner with default labels.** It targets
  `["self-hosted","linux","x64"]`, and `config.sh` adds exactly those labels unless it gets
  `--no-default-labels`. A bench box registered through `mise runner-vps:register` as it is
  today would be eligible for a sealed publish, which writes the six UEFI private keys into the
  workspace. Hence D4.
- **A pull request can target any runner label, whatever is disabled on `main`.** krytis is
  public. A `pull_request` run uses the workflow file from the PR, so a PR can add a job with
  `runs-on: [bench-onecom-l]`. The only check is the fork-PR approval policy, which is
  `first_time_contributors` (`gh api repos/starlit-os/krytis/actions/permissions/fork-pr-contributor-approval`,
  2026-10-07). Under that policy, anyone with one previously approved contribution runs
  without approval. krytis-vps has the same exposure today; the bench box adds a second host to
  it while it is registered. Hence D5. This is also GitHub's default for public repos, not
  a setting anyone loosened: nothing in the repo or its issues records a change, and Renovate
  and the tracking bot push same-repo branches, which the policy never gates.
- **`mise runner-vps:install`/`register` already work against another host.**
  `scripts/runner-vps-host.sh` prefers `RUNNER_VPS_HOST` from the environment over the vault.
  `RUNNER_VPS_NAME`, `RUNNER_VPS_LABELS` and `RUNNER_VPS_SSH_KEY` are env-overridable
  (`mise.toml`, `runner-vps-host.sh`). `provision.sh` adds the 8G swap backstop.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **No bow at all** on bench runs: no artifact remote and no source cache. Sources come from upstream. | No token on a third-party box, so nothing to mint or rotate. Pulls are impossible, so the runs are cold by construction. Per-element **build** times, the primary metric, do not depend on where sources came from. Cost: upstream mirror variance lands in the fetch time, which is reported separately. |
| D2 | **Phase 1: toolchain closure** on both boxes in parallel. Targets: `freedesktop-sdk.bst:components/llvm.bst freedesktop-sdk.bst:components/rust.bst`, `--deps all`, `-o x86_64_v3 true`. | The toolchain dominates a junction-bump rebuild and is the set the Toolchain Gate guards. It takes hours, not days. Builds on separate boxes share nothing, so running them in parallel costs no fairness. |
| D3 | **Phase 2: continue to the full closure** (`oci/krytis/image.bst --deps all`, no wipe) on krytis-vps, and on L **if L beat krytis-vps in phase 1**. If it did not, skip phase 2 on L. | phase 1 + phase 2 adds up to a cold full build. Running phase 2 on krytis-vps also refills its production CAS by building it, so the wipe costs no bow pull afterwards. |
| D4 | **Keep the bench box out of `publish.yml`'s reach two ways:** register it with `--no-default-labels` and the single label `bench-onecom-l`, **and** disable `publish.yml` for the window. | Either alone closes the `force_self_hosted` route. The label survives an early re-enable; the disable survives a registration done without the flag. Both cost nothing. |
| D5 | **Security Gate, a bounded window, and a permanent approval policy.** A human approves registering the one.com L host as a `starlit-os/krytis` runner (approved 2026-10-07). It is registered only once the window opens, just before phase 1, and deregistered as soon as its last bench run ends, not at write-up. The fork-PR approval policy becomes `all_external_contributors` when the window opens and **stays that way afterwards** (decided 2026-10-07). | It runs repo code as root. The bench workflow is `workflow_dispatch`-only, `permissions: read-all`, and references no secrets, but any registered runner is reachable by a PR (§ Checked while writing). A shorter registration bounds the bench box's exposure. The permanent policy also closes the same route to krytis-vps (and to `build-changed.yml` if #1122 merges). It does not slow Renovate or the tracking bot, whose PRs come from same-repo branches. |
| D6 | **krytis-vps is made cold by wiping `/root/.cache/buildstream`** (chosen 2026-10-07), inside the bench workflow, after the stale-FUSE cleanup. | Simple and representative. bow holds 917/917 (37515434814), so production loses nothing it cannot pull back. |
| D7 | **One run per box per phase.** Repeat phase 1 on both boxes if their wall times are within 15% of each other. | VPS neighbours add noise. CPU steal is recorded so a noisy run is visible as noisy rather than being taken as slow. |
| D8 | **Keep the bench workflow and compare task after the benchmark**, dispatch-only. | Runner evaluations recur: Contabo VPS 4 (2026-09-10), Hetzner on-demand (2026-09-08), Blacksmith 4vcpu (2026-10-07). The cold number is the one each of them lacked. |

## Steps

### 1. Benchmark tooling (one PR)

- [ ] `mise/tasks/runner-vps/register`: when `RUNNER_VPS_NO_DEFAULT_LABELS=true`, pass
      `--no-default-labels` to `config.sh`. Confirm the flag exists in the pinned
      `RUNNER_VERSION`'s `./config.sh --help` before relying on it.
- [ ] `.github/workflows/bench-cold-build.yml`, `workflow_dispatch` only:
  - inputs: `runner` (choice: `krytis-vps`, `bench-onecom-l`), `phase`
    (choice: `toolchain`, `full`) and `resume` (boolean, default `false`; see § Risks, fetch
    failure);
  - `runs-on`: `krytis-vps` → `["self-hosted","linux","x64","krytis-vps"]`, `bench-onecom-l` →
    `["bench-onecom-l"]`;
  - `timeout-minutes: 4320` (self-hosted allows 5 days);
  - steps reuse cache-warm.yml's: checkout, stale-FUSE cleanup, mise pinned to the same
    version, `mise bootstrap --yes --update`, `uv sync`, `generate-image-version`, userns
    sysctl;
  - `phase: toolchain` without `resume`: `rm -rf /root/.cache/buildstream`, then assert it is
    gone. With `resume`: skip the wipe and keep whatever the failed attempt built.
    `phase: full`: never wipe; assert all 67 toolchain elements are `cached` locally, and fail
    otherwise;
  - **Record host**: `lscpu`, `nproc`, `/proc/meminfo`, `swapon --show`, `df -h -x fuse`,
    `/etc/os-release`, `uname -r`, into `host.txt`;
  - **Configure BuildStream**: the same `SLOTS`/`BUILDERS`/`MAX_JOBS` formula as cache-warm.yml,
    with a comment pointing back to it. Same scheduler block. `quota: 100G` on every box. **No
    `artifacts:`/`source-caches:` entries** (D1);
  - start `vmstat -t 30 > vmstat.log &` before the build and stop it after (`if: always()`);
  - build: `uv run bst -o x86_64_v3 true --no-interactive build --deps all <targets>`, teed
    under `set -o pipefail`. Record the step's start and end epoch in `timing.txt`;
  - report (`if: always()`): `bst show --deps all` states and `scripts/cache-summary.py`, as in
    cache-warm. **Fail if the run pulled anything** (cold check).
    `journalctl -k --since <start> | grep -i oom` goes to `oom.txt`;
  - upload `bench-<runner>-<phase>-<run_id>`: `host.txt`, `timing.txt`, `vmstat.log`,
    `oom.txt`, `states.tsv`, `bst-build.log`, the summary. Retention 90 days.
- [ ] `scripts/bench-compare.py` plus a `mise run bench-compare <runs>...` task, where each
      argument is one box's run, or several resumed attempts joined with `+`
      (`<id>+<id>`; their wall times and element times add up). It downloads the artifacts with
      `gh run download` and prints one table:
  - host: CPU model, `nproc`, `MemTotal`, builders × max-jobs;
  - wall time of the build step, the sum of per-element build seconds, and fetch seconds
    (`fetch:` events; cache-summary.py's `EVENT` regex only matches build/pull/push);
  - per-element build times for the 67 toolchain elements, slowest first, one column per run;
  - from vmstat: mean and p95 of `st` (steal) and `wa` (iowait), peak swap used;
  - OOM kills.
- [ ] `mise run bench-window open|close`, so the window is one reproducible command each way.
      `open`: disables `publish.yml` plus every workflow whose `runs-on` names `krytis-vps`. It
      derives that list from `.github/workflows/` when it runs, not from a fixed list: today that
      is `cache-warm.yml`, `runner-vps-gc.yml` and `build-iso.yml`, and open PR #1122 adds
      `build-changed.yml`. It also excludes the bench workflow itself.
      It sets the fork-PR approval policy to `all_external_contributors` (idempotent, so it is a
      no-op after the first window):
      `gh api -X PUT repos/starlit-os/krytis/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`.
      `close`: re-enables exactly the workflows `open` disabled. It **leaves the policy alone**
      (D5). Both end by printing the workflow states and the policy.
- [ ] `docs/skills/ci-runner.md`: a section for the bench workflow (what "cold" means here,
      D1/D4, how to read the comparison) and a row in § Workflow Runner Choices. Commit them
      with the code, per AGENTS.md.
- [ ] `mise run docs-links`.

### 2. Provision the one.com box (needs D5)

- [ ] Order Cloud server L, Debian 13 if it is offered (record the version otherwise),
      with the `KrytisBuild` FIDO2 public key. Record the renewal price in § Machines.
- [ ] **Install only, do not register yet** (D5):
      ```shell
      RUNNER_VPS_HOST=root@<ip> mise run runner-vps:install
      ```
      `install` copies packages, swap and the runner binary. GitHub knows nothing about the
      box until `register`.

### 3. Open the window and smoke (just before phase 1)

Phases 1 and 2 run inside one window, on any day. Nothing that targets krytis-vps can then
queue behind a bench run or land between phases. If a tracking PR bumps a junction meanwhile,
publish would have refused it anyway at the Toolchain Gate. Its next run after `close` does
exactly that until cache-warm has run.

- [ ] Confirm the latest cache-warm reports 917/917, so bow can refill krytis-vps.
- [ ] Push branch `bench/2026-10` at `main`'s current SHA. Every dispatch below uses
      `--ref bench/2026-10`, so all runs build identical cache keys while `main` moves. The
      bench workflow must already be on `main`, because `workflow_dispatch` only sees workflows
      on the default branch.
- [ ] `mise run bench-window open`.
- [ ] Register the box:
      ```shell
      RUNNER_VPS_HOST=root@<ip> RUNNER_VPS_NAME=bench-onecom-l \
        RUNNER_VPS_LABELS=bench-onecom-l RUNNER_VPS_NO_DEFAULT_LABELS=true \
        mise run runner-vps:register
      ```
- [ ] `gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] | "\(.name) \([.labels[].name])"'`
      shows `bench-onecom-l` with **only** its own label.
- [ ] Smoke: dispatch `runner=bench-onecom-l phase=toolchain`. Within the first 15 minutes,
      check that `host.txt` looks right, the config print shows no remotes and the expected
      builders × max-jobs, and fetches are under way. If anything is wrong, cancel the run,
      land a fix PR, move `bench/2026-10` to the fixed SHA, and smoke again. L is the right
      smoke target: a fresh box holds nothing worth keeping, while a bad smoke on krytis-vps
      would wipe its CAS for nothing. A clean smoke run can stay as L's phase 1 run.

### 4. Phase 1: toolchain closure

- [ ] Dispatch `phase=toolchain` on krytis-vps (and on L again, if the smoke run was
      cancelled).
- [ ] Each run: toolchain 67/67 cached, `Pulled from a remote` 0, no OOM. A run that died on
      a fetch: re-dispatch the same box with `resume=true` and pass both IDs to
      `bench-compare` as `<id>+<id>`.
- [ ] `mise run bench-compare <id-vps> <id-l>`. Paste the table under § Results.
- [ ] Apply D7 (repeat within 15%) and D3 (phase 2 on L or not).
- [ ] **If phase 2 skips L, deregister it now:**
      `RUNNER_VPS_HOST=root@<ip> RUNNER_VPS_NAME=bench-onecom-l mise run runner-vps:deregister`.

### 5. Phase 2: full closure (straight after phase 1)

- [ ] Dispatch `phase=full` on krytis-vps, and on L if D3 kept it.
- [ ] Each run: 917/917 cached, 0 pulled, no OOM. Cold full time = phase 1 wall + phase 2 wall.
- [ ] **Deregister L** as soon as its run ends, if it is still registered, then confirm the runners
      list shows only krytis-vps (and the local runner, if it happens to be online).
- [ ] `mise run bench-window close`. If phase 2 was skipped on krytis-vps, dispatch cache-warm
      now. It pulls the closure from bow; confirm it reports 917/917.
- [ ] `mise run bench-compare` over all phase 1 and phase 2 runs. Paste under § Results.

### 6. Write up and tear down

- [ ] § Results: wall times, cold full time vs the 1440-minute cache-warm timeout, steal, OOMs,
      price per month, and hours per cold rebuild per € of monthly price. The replacement
      decision is a human's (Design Gate). This plan reports, it does not recommend.
- [ ] `docs/skills/ci-runner.md`: measured cold times per box. If a box hit an OOM or heavy
      steal, add that too. The sizing-formula overshoot and the `force_self_hosted` label reach
      were recorded there with this plan.
- [ ] `docs/skills/ci-runner.md`: record that the fork-PR approval policy is
      `all_external_contributors` (since this window, dated) and why: a fork PR can name any
      self-hosted runner label. That way a later agent does not read it as an accident and
      loosen it. Where a doc or an **open** issue/PR body still says `first_time_contributors`,
      update it (`gh pr list --state open --search 'first_time_contributors in:body'`, and the
      same for issues). #1122's description and its § PR build gate in ci-runner.md say "Not
      changed here" today.
- [ ] Cancel the one.com subscription unless the decision keeps the box. A kept box gets
      registered again as a production runner, through that decision, not this plan.
- [ ] Delete branch `bench/2026-10`. `git mv` this plan to `docs/plans/done/`.

## Risks

- **Fetch failure mid-run.** Without the bow source cache, an upstream mirror outage fails
  the run. The local cache keeps everything built so far, and a `resume=true` dispatch
  continues from it without wiping. The box's time is the sum of its attempts. That
  includes some re-fetching, which shows up in fetch seconds, not build seconds.
- **n = 1.** D7 covers close calls only. Sustained steal above about 10% in `vmstat.log`
  marks a run as noisy in § Results.
- **The window stays open on a failure.** A long OOM/re-run loop keeps the bench box
  registered and publish disabled. Past two failed attempts on a box, deregister it and report it
  as failed rather than hold the window open.
- **Network to bow is not measured.** A production one.com runner would push to and pull from
  bow (`bst-cache.ririi.dev`) over a different path than Contabo's. D1 trades that measurement
  away. See § Deferred.
- **builders = 2 caps scaling.** L's 8 cores run 2 × 4, the production formula. If L barely
  beats krytis-vps, check the per-element table before blaming the CPU. Single-element compiles
  (llvm) use only `max-jobs`.

## Deferred

- **Where the bottleneck is for bow traffic, in both directions: the VPS or bow.** This covers
  pulls (reads) and pushes (writes). It is out of scope here, because D1 keeps bow out of every
  bench run, but it is still open and needs answering separately. It decides whether a faster
  runner would speed up the paths that mostly move cache data:
  - **Reads:** publish's build step swings between 540s and 1388s with bow's cache state
    (docs/skills/ci-runner.md § Sizing the `publish.yml` runner). Refilling a wiped or new
    runner pulls the whole closure.
  - **Writes:** cache-warm run 37296270943 built 21 elements and pushed 916 in a 5h36m run
    (its cache report; the slowest build was 21m), so pushing probably took most of it
    `[INFERENCE]`.

  The candidate limits are on the client side (network path and its upload rate, disk, casd,
  the `fetchers`/`pushers` counts) or on bow (uplink and downlink, the SATA SSD under
  bb-storage, bb-storage itself). A cheap first split is to measure the same transfer from more
  than one client: krytis-vps, the Blacksmith publish runner, a workstation, and L while it
  exists. If every client sees the same rate, the limit is on bow's side; if the rates differ,
  it is on the client side. Measure reads and writes separately, because a client's upload can
  be the limit when its download is not. A write test must push content bow does not already
  hold: BuildStream skips blobs the remote reports as present, so re-pushing a cached artifact
  measures almost nothing.

## Results

Not run yet.
