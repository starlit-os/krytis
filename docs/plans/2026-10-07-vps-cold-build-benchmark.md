# Benchmark cold-cache builds: krytis-vps vs one.com L

**Issue:** #1126 · **Branch:** `1126-benchmark-cold-build-on-one-com` (step 1) · **Worktree:**
`krytis.worktrees/feat/gh1126-benchmark-cold-build-on-one-com` · **Status: step 1 done, next is
step 2.** The Security Gate (§ Decisions, D5) was approved on 2026-10-07: registering a
third-party host as a repo runner, inside the window. Cloud server M was dropped the same day,
leaving one one.com box.

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
  `runs-on: [bench-onecom-l]`. The only check is the fork-PR approval policy
  (`gh api repos/starlit-os/krytis/actions/permissions/fork-pr-contributor-approval`). Until
  2026-10-07 it was GitHub's public-repo default, `first_time_contributors`, under which anyone
  with one previously approved contribution runs without approval. On 2026-10-07 it was
  changed to `all_external_contributors`, outside this plan, so every outside PR now waits for
  approval. krytis-vps had the same exposure; the bench box only adds a second host to it while
  it is registered. Renovate and the tracking bot push same-repo branches, which the policy
  never gates.
- **`mise runner-vps:install`/`register` already work against another host.**
  `scripts/runner-vps-host.sh` prefers `RUNNER_VPS_HOST` from the environment over the vault.
  `RUNNER_VPS_NAME`, `RUNNER_VPS_LABELS` and `RUNNER_VPS_SSH_KEY` are env-overridable
  (`mise.toml`, `runner-vps-host.sh`). `provision.sh` adds the 8G swap backstop.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **No bow at all** on bench runs: no artifact remote and no source cache. Sources come from upstream. | No token on a third-party box, so nothing to mint or rotate. Pulls are impossible, so the runs are cold by construction. Per-element **build** times, the primary metric, do not depend on where sources came from. Cost: upstream mirror variance lands in the fetch time, which is reported separately. |
| D2 | **Phase 1: toolchain closure** on both boxes in parallel. Targets: `freedesktop-sdk.bst:components/llvm.bst freedesktop-sdk.bst:components/rust.bst freedesktop-sdk.bst:bootstrap/go.bst`, `--deps all`, `-o x86_64_v3 true`: 159 elements, 67 of them the Toolchain Gate's set. | The toolchain dominates a junction-bump rebuild and is the set the Toolchain Gate guards. It takes hours, not days. Builds on separate boxes share nothing, so running them in parallel costs no fairness. `bootstrap/go.bst` was added in step 1: `llvm` and `rust` alone cover 66 of the 67 (`bst show --deps all`, 2026-10-07). |
| D3 | **Phase 2: continue to the full closure** (`oci/krytis/image.bst --deps all`, no wipe) on krytis-vps, and on L **if L beat krytis-vps in phase 1**. If it did not, skip phase 2 on L. | phase 1 + phase 2 adds up to a cold full build. Running phase 2 on krytis-vps also refills its production CAS by building it, so the wipe costs no bow pull afterwards. |
| D4 | **Keep the bench box out of `publish.yml`'s reach two ways:** register it with `--no-default-labels` and the single label `bench-onecom-l`, **and** disable `publish.yml` for the window. | Either alone closes the `force_self_hosted` route. The label survives an early re-enable; the disable survives a registration done without the flag. Both cost nothing. |
| D5 | **Security Gate and a bounded window.** A human approves registering the one.com L host as a `starlit-os/krytis` runner (approved 2026-10-07). It is registered only once the window opens, just before phase 1, and deregistered as soon as its last bench run ends, not at write-up. | It runs repo code as root. The bench workflow is `workflow_dispatch`-only, `permissions: read-all`, and references no secrets, but any registered runner is reachable by a PR (§ Checked while writing). The fork-PR approval policy, `all_external_contributors` since 2026-10-07, puts every outside PR behind approval. A shorter registration bounds the rest of the exposure. |
| D6 | **krytis-vps is made cold by wiping `/root/.cache/buildstream`** (chosen 2026-10-07), inside the bench workflow, after the stale-FUSE cleanup. | Simple and representative. bow holds 917/917 (37515434814), so production loses nothing it cannot pull back. |
| D7 | **One run per box per phase.** Repeat phase 1 on both boxes if their wall times are within 15% of each other. | VPS neighbours add noise. CPU steal is recorded so a noisy run is visible as noisy rather than being taken as slow. |
| D8 | **Keep the bench workflow and compare task after the benchmark**, dispatch-only. | Runner evaluations recur: Contabo VPS 4 (2026-09-10), Hetzner on-demand (2026-09-08), Blacksmith 4vcpu (2026-10-07). The cold number is the one each of them lacked. |

## Steps

### 1. Benchmark tooling (one PR)

Landed as described in docs/skills/ci-runner.md § Cold-build benchmark: `bench-cold-build.yml`
(#1126). Where it differs from what this step first specified:

- [x] `mise/tasks/runner-vps/register`: `RUNNER_VPS_NO_DEFAULT_LABELS=true` passes
      `--no-default-labels` (present in actions/runner 2.338.0). It also checks the labels
      GitHub reports and fails before starting the service unless they are exactly
      `RUNNER_VPS_LABELS`, because an already-configured box reuses its registration.
- [x] `.github/workflows/bench-cold-build.yml`. Changes from the first spec:
  - phase 1 also targets `bootstrap/go.bst` (D2);
  - the full-phase precondition is the whole toolchain closure cached locally, not a
    count of 67;
  - no `concurrency:` group: the runner already serializes, and a group would drop a
    second queued dispatch;
  - `vmstat` starts and stops inside the build step;
  - extra artifact files: `bench.env` (runner, phase, commit, CPU, RAM, sizing) and
    `summary.md`;
  - `provision.sh` installs `procps` for `vmstat`.
- [x] `scripts/bench-compare.py` (`check` and `report`) and `mise run bench-compare`.
      `cache-summary.py` now parses `fetch:` events too, and takes `CACHE_REPORT_TARGETS`
      for its header. Per-element table: the toolchain elements plus the 20 slowest others.
- [x] `mise run bench-window open|close|status [--dry-run]`. What `open` disabled is kept in
      the repository variable `BENCH_WINDOW_DISABLED`, so `close` works from any machine. On
      2026-10-07 the derived list was `build-changed.yml`, `build-iso.yml`, `cache-warm.yml`,
      `publish.yml` and `runner-vps-gc.yml`.
- [x] `docs/skills/ci-runner.md`: the section and the § Workflow Runner Choices row.
      `docs/skills/mise.md` lists the two tasks.
- [x] `mise run docs-links`.

### 2. Provision the one.com box (needs D5)

- [x] Dedicated SSH credential, per docs/skills/fido2.md's one-per-host convention:
      `ssh:BenchOnecomL`, resident on the YubiKey, touch-only, handle
      `~/.ssh/id_ed25519_sk_rk_BenchOnecomL` (generated 2026-10-07, fingerprint
      `SHA256:2gaVEluCzEjGSYRqMfAgoroGWX1VydAi+XRWHhcELos`). Not `ssh:KrytisBuild`: a separate
      credential can be deleted from the key when L goes, without touching krytis-vps.
      Every `runner-vps:*` call for L below passes `RUNNER_VPS_SSH_KEY` to use it.
- [x] Krytis vault item **Krytis Bench VPS** (custom item, section "Access"): `SSH Public Key`,
      `SSH Credential`, `SSH Fingerprint`, `Username` (`root`), and an empty `IP Address`.
      Created with `pass-cli item create custom --from-template`, which puts fields in a
      section. That is a different shape from Krytis Build VPS, whose fields are top-level
      extra fields that `fnox.toml` reads; no `fnox.toml` entry reads the bench item.
- [ ] Order Cloud server L, Debian 13 if it is offered (record the version otherwise),
      with `~/.ssh/id_ed25519_sk_rk_BenchOnecomL.pub` as its SSH key. Record the renewal price
      in § Machines, and the address in the vault:
      `pass-cli item update --vault-name Krytis --item-title "Krytis Bench VPS" --field "IP Address=<ip>"`.
- [ ] **Install only, do not register yet** (D5):
      ```shell
      RUNNER_VPS_HOST=root@<ip> RUNNER_VPS_SSH_KEY=~/.ssh/id_ed25519_sk_rk_BenchOnecomL \
        mise run runner-vps:install
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
      RUNNER_VPS_HOST=root@<ip> RUNNER_VPS_SSH_KEY=~/.ssh/id_ed25519_sk_rk_BenchOnecomL \
        RUNNER_VPS_NAME=bench-onecom-l RUNNER_VPS_LABELS=bench-onecom-l \
        RUNNER_VPS_NO_DEFAULT_LABELS=true mise run runner-vps:register
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
- [ ] Each run: all 159 elements cached (67 toolchain), `Pulled from a remote` 0, no OOM. A run that died on
      a fetch: re-dispatch the same box with `resume=true` and pass both IDs to
      `bench-compare` as `<id>+<id>`.
- [ ] `mise run bench-compare <id-vps> <id-l>`. Paste the table under § Results.
- [ ] Apply D7 (repeat within 15%) and D3 (phase 2 on L or not).
- [ ] **If phase 2 skips L, deregister it now:**
      `RUNNER_VPS_HOST=root@<ip> RUNNER_VPS_SSH_KEY=~/.ssh/id_ed25519_sk_rk_BenchOnecomL RUNNER_VPS_NAME=bench-onecom-l mise run runner-vps:deregister`.

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
- [ ] Cancel the one.com subscription unless the decision keeps the box. A kept box gets
      registered again as a production runner, through that decision, not this plan. If it
      is cancelled, delete the `ssh:BenchOnecomL` credential from the key too: find its ID
      with `fido2-token -L -k ssh:BenchOnecomL <device>`, remove it with
      `fido2-token -D -i <id> <device>` (both ask for the PIN), then delete the handle and
      `.pub` files.
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

- **Where the bottleneck is for bow traffic, in both directions: the VPS or bow (#1128).** This
  covers pulls (reads) and pushes (writes). It is out of scope here, because D1 keeps bow out of
  every bench run, but it is still open and tracked in #1128. It decides whether a faster
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
