# CI Runner Reference

Load when working on GitHub Actions workflows, the self-hosted runner container, or BST cache in CI.

## Self-Hosted Runner in Podman

The runner container (`Containerfile.runner`) runs as root with `--privileged` — required for bubblewrap (BST sandboxing). Managed via `mise runner:*` tasks.

### Required flags / env

| Flag / env | Why |
|---|---|
| `--privileged` | bubblewrap requires unprivileged user namespaces, which need privileged mode in podman |
| `RUNNER_ALLOW_RUNASROOT=1` | GitHub Actions runner refuses to start as root without this |
| `--replace` on `podman run` | prevents "container name already in use" errors from stale stopped containers |

### PAT requirements

Fine-grained PAT with **Administration: Read and Write** on `starlit-os/krytis`. Stored as podman secret `gh-token`. Used only for deregistration (obtaining a remove token).

### Deregistration

**Do not rely on the container's EXIT trap.** The GitHub Actions runner binary intercepts SIGTERM internally and may not exit within podman's stop timeout, preventing the trap from firing. Instead, `runner:stop` deregisters via the GitHub API directly before stopping the container:

```bash
RUNNER_ID=$(gh api repos/starlit-os/krytis/actions/runners \
    --jq ".runners[] | select(.name == \"${RUNNER_NAME}\") | .id")
gh api -X DELETE "repos/starlit-os/krytis/actions/runners/${RUNNER_ID}"
```

### Stale offline runners

After an unclean shutdown the runner stays registered as `offline`. `runner:start` auto-removes any offline registration with the same name before re-registering. To remove one manually:

```bash
gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] | "\(.id) \(.name) \(.status)"'
gh api -X DELETE repos/starlit-os/krytis/actions/runners/<id>
```

### Dependencies (Ubuntu 24.04 base)

`libicu74` must be installed explicitly in the Containerfile. The runner's bundled `installdependencies.sh` doesn't work in a separate Docker layer (no apt lists). Without it the runner binary fails with "Libicu dependencies missing for .NET Core 6.0".

### The runner version is pinned in two places

| Pin | Consumed by |
|---|---|
| `mise.toml` `[env]` `RUNNER_VERSION` | `mise run runner/build`, passed as `--build-arg` |
| `ARG RUNNER_VERSION` default in `Containerfile.runner` | a direct `podman build -f Containerfile.runner` |

They must hold the same value: the `ARG` default is the only thing a build that bypasses the mise task sees, so it rots silently if only `mise.toml` is bumped. Renovate keeps them in step — the `custom.regex` manager in `.github/renovate.json5` matches both files and rewrites them in one PR (#27, see [`renovate.md`](renovate.md) § Custom regex managers). Bumping by hand means editing both.

### Rootless podman subuid/subgid

`mise run runner/build` (pulls `ubuntu:24.04`) and `mise run renovate-check`
(pulls `ghcr.io/renovatebot/renovate:latest`) both run **rootless** podman as
the invoking user, not `sudo podman`. Unpacking a multi-layer image under
rootless podman requires the user to own a subordinate UID/GID range —
`/etc/subuid`/`/etc/subgid` — so podman can remap each layer's UIDs into its
own user namespace. Accounts created without that range (or predating it)
fail with:

```
creating build container: unable to copy from source docker://ubuntu:24.04: ...
unpacking failed (error: exit status 1; output: potentially insufficient UIDs
or GIDs available in user namespace (requested 0:42 for /etc/gshadow): Check
/etc/subuid and /etc/subgid if configured locally and run "podman system
migrate": lchown /etc/gshadow: invalid argument)
```

**This is per-machine, per-user-account host state — not something the repo,
`mise.toml`, or the Containerfile can default.** It lives entirely outside
the project (`/etc/subuid`/`/etc/subgid` are shadow-utils files owned by the
host), and fixing it needs one-time interactive root:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$(id -un)"
podman system migrate
```

`runner/build` and `renovate-check` both preflight-check for the range and
print this fix before the cryptic podman error if it's missing (same pattern
as `runner/start`'s `apparmor_restrict_unprivileged_userns` warning above) —
the check surfaces the problem clearly, it doesn't auto-run `sudo` on the
user's behalf. First hit and root-caused in #703 (`docs/plans/done/2026-09-03-migrate-free-disk-space.md`
Task 7), where it blocked a local `renovate-check --dry-run` verification.

## Always-on VPS Runner (issue #794)

A second, distinct self-hosted runner: a dedicated, always-on Debian 13
(trixie) Contabo Cloud VPS 6 (6 vCPU/12 GB/200 GB), registered under the
name `krytis-vps`. It exists to take `cache-warm.yml`'s scheduled cron run
off Blacksmith — a `schedule`-triggered workflow can never satisfy a
`workflow_dispatch`-only opt-in condition, so that job was architecturally
stuck paying Blacksmith overage no matter how much manually-dispatched work
got routed to the local container runner by hand. See the issue for the
full cost/sizing rationale.

### Host-native, not a container — the local runner's design doesn't apply here

`Containerfile.runner`'s privileged-Podman-container design exists
specifically to isolate the runner on a **shared local dev workstation**.
This VPS has no other tenant — the VM itself is the isolation boundary — so
the runner is installed directly on the host (`/opt/actions-runner`,
`RUNNER_ALLOW_RUNASROOT=1`, supervised by the binary's own `svc.sh`-generated
systemd unit) rather than containerized. No `--privileged` flag, no podman
run wrapper, nothing analogous to `mise runner:start`/`stop` for the
container lifecycle — this is a persistent host service, closer in shape to
the Buildbarn Quadlet precedent (always up, restarts with the box) than to
the local runner's manually start/stop container.

Managed via `mise runner-vps:{install,register,deregister,status}`
(`mise/tasks/runner-vps/`, provisioning script in `files/runner-vps/provision.sh`).
`install` is idempotent and re-runnable (apt install + binary download are
both guarded); `register`/`deregister` call the GitHub API directly, same
pattern as `runner:start`/`stop`.

### Debian, not Ubuntu — sidesteps an AppArmor default that doesn't apply here

`kernel.apparmor_restrict_unprivileged_userns` (the sysctl `runner/start`
warns about, and `cache-warm.yml`'s "Enable unprivileged user namespaces"
step unconditionally flips for the Blacksmith/Ubuntu fallback path) is an
**Ubuntu-specific** AppArmor default, not a general Linux one. Confirmed
absent on this box: `/proc/sys/kernel/apparmor_restrict_unprivileged_userns`
doesn't exist at all on Debian 13, and `kernel.unprivileged_userns_clone=1`
(the more fundamental gate, historically 0 on some Debian configs) is
already enabled by default — bubblewrap works with zero sysctl changes.

### The PAT never lives on the VPS

`register`/`deregister` mint the GitHub registration/removal token from the
**operator's already-authenticated local `gh` session**, then SSH only that
short-lived (1h), single-use token to the box to feed `config.sh`. The
fine-grained Administration:Read-and-Write PAT itself never has to be
stored on this always-reachable external host — an improvement over the
local container runner's design (which does store that PAT there, as a
podman secret, but that box is a mostly-off local workstation, a smaller
exposure window than an always-on VPS).

`RUNNER_VPS_HOST`/`RUNNER_VPS_SSH_KEY`
are resolved by `scripts/runner-vps-host.sh`, which every `runner-vps` task
sources. Resolution order: `RUNNER_VPS_HOST` already in the environment
(`.mise.local.toml`, or an ad-hoc override), else **fnox**, joining the
`Krytis` vault item "Krytis Build VPS"'s `Username` and `IP Address` fields
(`fnox.toml`'s `RUNNER_VPS_USER`/`RUNNER_VPS_IP`). The address of
externally-reachable infra still doesn't belong committed to a public repo —
but `.mise.local.toml` alone made every `runner-vps` task unrunnable on any
machine where that gitignored file had never been hand-populated, which is
exactly how the 2026-09-12 outage below stayed undiagnosed while the box was
up and reachable the whole time. The vault already held the address; nothing
in the checkout knew how to ask. fnox has no template provider, so the join
happens in the script rather than vault-side.

SSH access is a per-host FIDO2 resident key following the convention in
`docs/skills/fido2.md` (`id_ed25519_sk_rk_<HostName>`), not a password —
root password SSH is disabled on this box (see `docs/skills/fido2.md` §
Remote host SSH login for the cloud-init `ssh_pwauth` gotcha hit doing that).

### Distinct label — avoids nondeterministic routing against the local runner

The local container runner and this VPS runner both satisfy
`runs-on: [self-hosted, linux, x64]` if given identical labels — GitHub
would then pick whichever happens to be online with no way to target one
specifically. `RUNNER_VPS_LABELS` (`mise.toml`) adds a distinct `krytis-vps`
label; `cache-warm.yml`'s `runs-on` targets
`["self-hosted","linux","x64","krytis-vps"]` specifically, so it always
lands on this box regardless of whether the local container runner also
happens to be up. `force_blacksmith` (workflow_dispatch input) is the
manual fallback for VPS maintenance or an outage — inverts the previous
`force_self_hosted` direction, since self-hosted is now the *default*, not
the opt-in.

### podman is installed but deliberately not version-pinned

Issue #794 proposed pinning podman to 4.9.3 — "the version that actually
built and boot-tested every shipped sealed image (#524/#527)". That premise
was already superseded before this runner existed: the 2026-08-12
composefs-digest verification
(`docs/plans/done/2026-08-12-verify-baked-composefs-digest.md`) found 4.9.3
and 5.8.2 both produce byte-identical, correctly-booting sealed images once
`verify-composefs-digest` checks the digest directly, and #527 already
reverted the `podman >= 5` assertion #524 had added on that now-disproven
premise. `provision.sh` installs whatever Debian trixie's apt carries
(5.4.2 as of setup). Moot either way today: `cache-warm.yml` — the only
workflow this box runs — never invokes podman; it was installed for parity
against a possible future `publish.yml` migration, which issue #794
explicitly leaves out of scope.

### Build concurrency is `builders` x `max-jobs` — size the product, not either half

`max-jobs` was raised from a hardcoded 4 to `$(nproc)` (d5bf7f6, 2026-09-11)
to stop leaving cores idle on single-element compiles, while
`scheduler.builders` was deliberately left at 4 pending "a representative
load to measure against." That load arrived the same day and the answer was
unambiguous: **4 builders x 6 jobs = up to 24 concurrent compilers on a
6-vCPU/11GiB box**, and the runner was OOM-killed twice inside 24h.

```
Sep 11 21:24:18  actions.runner...service: Failed with result 'oom-kill'.
                 Consumed 14h 6min CPU time, 11.4G memory peak.
Sep 12 14:55:14  actions.runner...service: Failed with result 'oom-kill'.
                 Consumed 27min CPU time, 11.1G memory peak.
kernel: oom-kill:...task=cc1plus...  Killed process 7960 (cc1plus) anon-rss:1541128kB
```

Neither knob is wrong on its own — their *product* is what has to fit in
RAM, and nothing was bounding it. `cache-warm.yml` now derives both from the
runner it lands on: one slot per core, one slot per 2 GiB of RAM (cc1plus
peaked at 1.5G RSS in the kill log), whichever is lower; `builders` fixed at
2 so the scheduler can still overlap a slow element with a fast one; and
`max-jobs` = slots / builders. That yields **2 x 3 = 6** on the VPS (was 24)
and **2 x 4 = 8** on the Blacksmith fallback (was 32).

No cache-key cost, then or now: `max-jobs`'s runtime env vars are excluded
from the cache key (see § `max-jobs` does NOT affect cache keys), which is
what made per-runner sizing safe in the first place.

**The generalisable lesson: an idle-cache verification run proves nothing
about RAM.** #794's verification run landed almost entirely bow cache hits,
showed >10G free, and was correctly identified in this file as "not evidence
either way" — but the sizing change shipped anyway. When a knob's risk is
peak RAM, the run that clears it has to actually compile.

### An OOM must not decommission the runner

`svc.sh install`'s generated unit carries **no `Restart=` at all** and
inherits systemd's default `OOMPolicy=stop`. So one OOM-killed compiler
stopped the whole unit, the runner went offline, and nothing brought it
back: the 2026-09-11 kill went unnoticed for **18 hours**, during which
every dispatch sat queued against an offline runner while the box itself was
up, healthy and reachable. The failure also reads misleadingly in the job
log — GitHub reports it as
`The runner has received a shutdown signal`, which looks like a manual
stop or a provider reboot, not an OOM. `journalctl -u actions.runner.*` on
the box is the ground truth; `systemctl show -p OOMPolicy -p Restart` is
how to check the drop-in is in effect.

`mise runner-vps:register` now writes
`/etc/systemd/system/<unit>.d/10-krytis-oom.conf` with
`OOMPolicy=continue` + `Restart=always` + `RestartSec=30`, so a build that
outruns RAM fails its own job and leaves the runner listening. Both
properties are consulted at event time, so `daemon-reload` alone applies
them — no restart of a live runner needed.

### The box ships with no swap

Contabo's Debian image has **zero swap**, which is what turned a RAM spike
into an immediate kill rather than a slowdown. `provision.sh` now creates an
idempotent 8G `/swapfile` (fstab entry + `vm.swappiness=10`, so it stays
emergency headroom rather than a paging tier a long build lives in). This is
a backstop for whatever the concurrency estimate above misses, not a
substitute for it.

**`free-disk-space` would have silently undone this.** The `Maximize build
space` step (`hastd/free-disk-space`) runs `swapoff -a && rm -f
/mnt/swapfile` — correct for a throwaway GitHub-hosted VM reclaiming its
preallocated swap, catastrophic on a persistent box whose swap is deliberate
OOM headroom: it would disable the backstop at the start of every single
run. Its path deletions are equally pointless here (124G free of 197G). The
step is now gated to the Blacksmith branch of the `runs-on` ternary, using
the same expression so the two can't drift.

**Generalisable:** any action whose job is "reclaim space on a disposable
runner" needs a second look before it runs on a persistent one. It is
written on the assumption that nothing on the box outlives the job.

### A killed build leaves FUSE mounts that break every later `df`

`buildbox-fuse` mounts under `~/.cache/buildstream/cas/staging/` do not
survive their server being killed, but the *mountpoints* do. Afterwards any
`df` traversing them exits 1:

```
df: /root/.cache/buildstream/cas/staging/cas-tmpdir0Z2arA: Transport endpoint is not connected
```

That is enough to fail a step outright — run 34696760836 died in
`Maximize build space` (which runs `df -h`) before it ever reached the
build, with four such mounts left by the previous OOM kill. On an ephemeral
runner this is invisible; on this box it persists until something unmounts
it, and now that `OOMPolicy=continue` keeps the runner alive across a kill,
the residue is *guaranteed* to reach the next job. `cache-warm.yml` has a
self-hosted-only `Clear stale FUSE mounts` step that `stat`s each
buildstream FUSE mountpoint and `fusermount -u`s (falling back to
`umount -l`) the dead ones.

### `register` is re-runnable

It used to be a strict one-shot — `config.sh` refuses with
`Cannot configure the runner because it is already configured` when
`.runner` exists (`--replace` only covers a same-named registration on
GitHub's side, not local state), and `svc.sh install` fails once the unit
file exists. That is the wrong shape for the task you reach for to bring a
runner back. It now skips `config.sh` when the box is already configured and
skips `svc.sh install` when the unit exists, so re-running it just
re-asserts the service and the drop-in. Re-key by running
`mise runner-vps:deregister` first.

## Scheduled Workflow Cron Delay

`cache-warm.yml` and `track-bst-sources.yml` were both `cron: '0 6 * * ...'`
— same trigger minute, no relation to each other otherwise (different
jobs, different runners, `track-bst-sources.yml` runs on GitHub-hosted
`ubuntu-24.04` with no self-hosted/concurrency-group involvement at all).
Investigated 2026-09-11 after their actual fire times (`created_at` on the
`schedule`-event run) looked "inconsistent." They weren't inconsistent —
they were **delayed, in lockstep, by a growing amount**:

```
2026-09-11  cache-warm 10:08:17   track-bst-sources 10:08:58
2026-09-10  cache-warm 10:11:17   track-bst-sources 10:11:42
2026-09-09  cache-warm 10:17:37   track-bst-sources 10:18:16
2026-09-08  cache-warm 10:13:18   track-bst-sources 10:13:38
2026-09-07  cache-warm 10:56:19   track-bst-sources 10:57:03
```

Both workflows landing within ~40 seconds of each other, every single day,
rules out anything in either workflow's own config (concurrency group,
runner assignment, job steps) — the delay is upstream of all of that, at
GitHub's own scheduler. The gap from the intended `06:00 UTC` grew over
several weeks rather than staying constant noise: ~20–30min in mid-August,
~1–2h by late August, a consistent ~4–5h by September. GitHub's own docs
acknowledge scheduled workflows can be delayed under load and specifically
call out the top of the hour (`:00`) as worst — every cron everywhere piles
up there — but a *sustained* multi-hour daily delay is well beyond the
"occasional few minutes" their docs describe; this reads as scheduler
backlog specific to this repo/account, not routine jitter.

**Fix applied:** moved both off `:00` to arbitrary non-round minutes
(`track-bst-sources.yml` → `13 5 * * *`, `cache-warm.yml` → `41 6 * * 1-5`,
~90min apart so tracking PRs have a window to land before cache-warm builds
— see each file's own cron comment). This addresses the documented
top-of-hour contention factor; it will not necessarily fix a genuine
account-level scheduler backlog if that's the real cause. Check
`gh api repos/starlit-os/krytis/actions/workflows/<file>/runs --paginate -q
'.workflow_runs[] | select(.event=="schedule") | .created_at'` again after
a couple of weeks — if delay from the new trigger times is still growing,
top-of-hour contention wasn't the (whole) story and it's worth a GitHub
support ticket instead of another cron-minute shuffle.

---

## BST Cache in CI

### casd quota

`cache.quota` in `buildstream.conf` controls the local CAS size. **4G is too small** for a full build — casd fills it, can't evict active blobs, and crashes:

```
OutOfSpaceException: disk usage above maximum quota and no inactive blobs are available for deletion
terminate called after throwing an instance of 'std::system_error'
```

Use **50G** for a full `cache-warm` build on a machine with adequate disk.

### `actions/cache` path spec determines the version hash

`actions/cache` computes an internal **version** from the `path:` input (a hash of paths + compression). This version is part of every lookup — including restore-key prefix matching. **Changing the path spec invalidates all prior cache entries, even those with matching key prefixes.**

```yaml
# These two configs produce different version hashes and cannot restore from each other:
path: ~/.cache/buildstream

path: |
  ~/.cache/buildstream
  !~/.cache/buildstream/sources
```

When changing `path:`, expect a cold-start run. Subsequent runs will find the cache.

### What to cache

The BST cache directory layout:

| Path | Content | Cache? |
|---|---|---|
| `cas/objects/` | Built artifact blobs | ✅ yes |
| `artifacts/` | Artifact refs (34 MB) | ✅ yes |
| `cas/tmp/` | casd staging (~18 GB) | ❌ no — transient |
| `logs/` | Build logs | ❌ no |
| `sources/` | Fetched source archives | ❌ no |
| `elementsources/` | Element source metadata | ❌ no |

When using `actions/cache`, pin the paths to exactly `cas/objects` and `artifacts`:

```yaml
path: |
  ~/.cache/buildstream/cas/objects
  ~/.cache/buildstream/artifacts
```

The self-hosted runner with a volume mount already persists the CAS between runs — `actions/cache` is only needed when a GitHub-hosted runner job will consume the cache.

### Clearing the CAS

BST has no native `artifact gc` command. To fully clear the cache:

```bash
bst artifact delete '**'          # remove all artifact refs
rm -rf ~/.cache/buildstream/cas/objects/ ~/.cache/buildstream/cas/tmp/
mkdir -p ~/.cache/buildstream/cas/objects/
```

### Freedesktop SDK remote cache errors

`cache.freedesktop-sdk.io:11001` (their BuildGrid CAS) occasionally returns:

```
OutOfSpaceException: Insufficient storage quota
```

This is a server-side error on their infrastructure — their CAS is full. BST logs it as `WARNING`/`FAILURE` for the cache pull but falls back to fetching sources from upstream and building locally. The build continues; it's just slower. No action needed on our side.

---

## uv sync in CI

Mise's experimental `[deps.uv]` feature (`outputs = [".venv/"]`) skips `uv sync` on re-runs if `.venv/` already exists. On a persistent self-hosted runner this means retried jobs find the venv but without the expected packages if the first run was incomplete.

**Fix:** add an explicit `uv sync` step after `mise bootstrap`:

```yaml
- name: Install Python dependencies
  run: uv sync
```

Don't rely on `[deps.uv]` auto-run for correctness in CI.

### `bst` is not on PATH — use `uv run bst`

`bst` is installed by `uv sync` into the project `.venv`; it is not placed on PATH. CI steps that call the bare `bst` binary fail with `bst: command not found` (exit 127). This bit the `cache-warm` workflow, which invoked `bst build …` / `bst show …` directly while `track-bst-sources.yml` correctly used `uv run bst …`.

**Convention:** every CI step that runs BuildStream must invoke it as `uv run bst …` (or `mise bst …`, which wraps the same thing). Never assume `bst` is on PATH.

---

## GitHub Actions: SHA Pinning and Org Allowlist

### SHA pinning — do it by hand; `mise lint` does not auto-pin

`mise lint` (`mise/tasks/lint`) only runs `podman build` + `bootc container lint` against the `Containerfile` — it does **not** run `actionlint` and does not touch `.github/workflows/` at all (verified by reading `mise/tasks/lint` and `mise.toml`'s `[tools]`: no `actionlint` tool or task exists anywhere in this repo as of 2026-07-30). An earlier version of this doc claimed `mise lint` auto-upgrades floating action tags to pinned SHAs — that was wrong; there is no such safety net. Pin every new `uses:` reference to a full commit SHA with a version comment yourself before committing (`uses: actions/checkout@<sha> # v7`), by copying an existing pinned reference to the same action elsewhere in `.github/workflows/` when one exists, or resolving the tag to its commit SHA via `gh api repos/<owner>/<repo>/commits/<tag>` (or the GitHub UI) otherwise — use the `commits/<tag>` endpoint, not `git/refs/tags/<tag>`: the latter returns the tag *object's* own SHA for an annotated tag (not a valid pin target), while `commits/<tag>` resolves either an annotated or lightweight tag straight to the underlying commit SHA.

### Org allowlist

The `starlit-os` org has an allowlist of permitted external actions. Any `uses: <owner>/<repo>` not already on the list will be blocked at runtime with a permissions error — the workflow job simply won't start.

When adding a new action to any workflow, check whether `<owner>/<repo>` is already allowlisted. If not, prompt the user to add it before the PR is merged. The allowlist is managed in the org's GitHub Actions settings.

**Easy to miss when adding a *new* action, not just re-pinning an existing one.**
Hit for real in PR #689: two new workflows added `actions/checkout` and
`jdx/mise-action` (both already used elsewhere in this repo, already
allowlisted — fine) alongside `actions/upload-artifact` (genuinely new,
zero prior uses anywhere in `.github/workflows/`) without flagging the
latter for an allowlist check at all, until the user asked directly. An
agent has no way to self-verify allowlist membership — `gh api
orgs/<org>/actions/permissions/selected-actions` needs org-admin or the
`admin:org` scope, which an agent's token will not have. **Checklist for
any new `uses:` line:** grep the rest of `.github/workflows/` for the same
`<owner>/<repo>` first; if it's not already there, call it out explicitly
in the PR description and ask the user to confirm/add it — do not assume
"it's a well-known action" is the same as "it's allowlisted."

**Hit a second time in PR #793 (issue #656), post-merge this time — the checklist above was skipped, not just missed by oversight.** `actions/create-github-app-token` was genuinely new to `.github/workflows/track-bst-sources.yml` (0 prior uses in the repo), landed in a plan (#710) and PR (#793) that never called out the allowlist question, and merged clean — `Static gates` doesn't run `actionlint` or touch workflow policy at all (see § SHA pinning above), so nothing in CI catches this before merge. The break only surfaces on the next real dispatch, as `startup_failure` with **zero jobs created** — no job logs, no check-run for the workflow, `gh api .../actions/runs/<id>/logs` 404s. The only place the actual reason appears is the run's web UI **Annotations** panel, reachable by opening `https://github.com/<org>/<repo>/actions/runs/<id>` in a real browser (`gh run view`/`gh api` surface nothing beyond the generic `startup_failure` conclusion):

```
The action <owner>/<repo>@<sha> is not allowed in <org>/<repo> because all actions
must be from a repository owned by <org> or match one of the patterns: <allowlist>.
```

Fix is entirely org-side (Settings → Actions → General → Allow select actions, on the org, not the repo) and needs an org admin — confirmed via `gh api orgs/<org>/actions/permissions/selected-actions` returning 403 even from an authenticated `gh` session. **Since nothing in CI catches this before merge, do not treat a clean `Static gates` run as proof a new third-party action will actually execute** — grep for prior use and ask before merging, the same discipline #689 already called for, now with a second confirmed cost of skipping it.

### `remove-unwanted-software` → `free-disk-space` migration (#703)

`ublue-os/remove-unwanted-software` had no push since 2025-10-10 and no `v10`
tag was ever cut (tags stop at `v9`), so Renovate's `github-tags` datasource
couldn't resolve a digest for the pinned commit `695eb75b…` used in
`cache-warm.yml`/`publish.yml`. Replaced with `hastd/free-disk-space`
(properly tagged, actively maintained, same action `zirconium-hawaii` already
uses) at `78ec0490f953d89f024c95d0c293e6307ceac02e # v0.1.1`.

**The old action's per-tool boolean inputs were dead code.** Reading
`action.yml` at the pinned commit shows the composite step reads only
`extra-squeeze`; `cache-warm.yml`'s `remove-dotnet`/`remove-android`/
`remove-haskell`/`remove-codeql` inputs were silently ignored the entire time
(composite actions warn, not error, on unrecognized inputs) — it ran the same
fixed `rm -rf` list as `publish.yml` without `extra-squeeze`. If a similar
action's inputs ever look suspicious, read the composite `action.yml` at the
exact pinned SHA rather than trusting the input names in the calling
workflow.

**`hastd/free-disk-space`'s bare defaults (no `with:` block) are a superset**
of what the old action + `extra-squeeze: true` ever removed — its default
path list already includes `/opt/hostedtoolcache/{CodeQL,PyPy,Python,Ruby,
go,node}` and `/usr/share/miniconda` (the old `extra-squeeze` set) alongside
`/usr/share/dotnet`, `/usr/local/.ghcup`, `/usr/local/lib/android`,
`/usr/lib/{firefox,llvm-*}`, `/opt/{az,google,microsoft,pipx}`, etc. Neither
krytis workflow uses `actions/setup-python`/`setup-node` (both install
Python via `uv`/mise), so the extra paths the new default also clears
(`/opt/hostedtoolcache/Python`, `/usr/local/lib/node_modules`, …) are safe.
Net: both workflows now run the *identical* input-free step, and it frees
more than either did before — no `include:`/`exclude:` mapping needed.

**Pinned to `v0.1.1`, one release behind newest, on purpose.** Diffed
`v0.1.1...v0.1.2` via GitHub's compare API: the only functional change is an
opt-in `skip-if-available` input (default empty, unused here) — the default
path-removal list is byte-identical between the two tags. So pinning the
older tag costs nothing behaviorally, and leaves Renovate a real minor bump
(`v0.1.1` → `v0.1.2`) to open once this merges. That bump is the actual
end-to-end proof the fix works: `mise run renovate-check --dry-run` only
proves extraction succeeds, not that Renovate can open and auto-merge a real
PR for this dependency (it already falls under the blanket
`digest`/`pin`/`patch`/`minor` automerge rule in `renovate.json5`, no
exception needed). Confirm the bump PR actually appears and auto-merges
before treating #703 as fully closed — if it doesn't, something about the
new dependency's Renovate config is still wrong despite `--dry-run` looking
clean.

## Buildbarn CAS (Quadlet)

krytis owns a Buildbarn deployment (`bb-storage` + `bb-remote-asset`) on the
self-hosted runner box, providing both a source cache (fixes upstream churn
like #233's CachyOS 404) and an artifact cache for krytis-specific elements.
See #234 and its sub-issues for the design rationale.

### Why Quadlet instead of `podman run` (unlike the runner)

The self-hosted runner (`mise runner:*`) is manually started/stopped around
CI activity — a `podman run` wrapper fits that lifecycle. Buildbarn is a
**persistent** host service that should survive reboots and restart on
failure, so it's modeled as Podman Quadlet units (`quadlet/buildbarn/`)
instead: `systemctl --user start/stop bb-storage bb-asset` after
`mise buildbarn:install` copies the units into
`~/.config/containers/systemd/` and reloads the user systemd manager.
There's no `buildbarn:start`/`buildbarn:stop` mise task — quadlet-generated
`.service` units already give us that via `systemctl`, and duplicating it in
a mise task would just be a less capable wrapper around the thing systemd
already provides.

### Quadlet-generated units cannot be `systemctl enable`d

`systemctl --user enable --now bb-storage.service` fails with:

```
Failed to enable unit: Unit /run/user/1000/systemd/generator/bb-storage.service is transient or generated
```

Quadlet units aren't real unit files on disk — they're generated into
`/run/user/<uid>/systemd/generator/` (or the system equivalent) by
`podman-system-generator` at every `daemon-reload`, and `systemctl enable`
only works on persisted unit files it can symlink. The `[Install]` section's
`WantedBy=` is instead honored **by the generator itself**, which creates
the `default.target.wants/bb-storage.service -> ../bb-storage.service`
symlink directly inside `/run` as part of generation — confirm with
`ls /run/user/<uid>/systemd/generator/default.target.wants/`. So the correct
lifecycle is just `systemctl --user start`/`stop`; there is no `enable`/
`disable` step, and `mise buildbarn:install` no longer attempts one.

### Rootless (`--user`) first, system-level later

The units currently target **rootless, user-level** Quadlet
(`~/.config/containers/systemd/`, `WantedBy=default.target`,
`systemctl --user`) rather than system-level
(`/etc/containers/systemd/`, `WantedBy=multi-user.target`, `sudo systemctl`)
— deliberately, so this can be brought up and torn down on a normal dev
box with `mise buildbarn:install` / `buildbarn:uninstall` while the design
is still being verified, with no `sudo` required. `%h` in a Quadlet unit
resolves to the *running user's* home directory in both modes, so the unit
files themselves don't need to change when this eventually moves to the
shared runner box as a system-level service — only the install
destination, `WantedBy=` target, and the `systemctl`/`journalctl` invocation
(drop `--user`) change. When that migration happens, re-run the
`quadlet -dryrun` check (below) against both modes, since the generator
resolves `%h` differently for a system unit (root's home, not the invoking
user's) if the service isn't given an explicit `User=`.

Rootless user services stop when the login session ends unless
`loginctl enable-linger <user>` has been run — not needed for interactive
local testing, but required before this is useful unattended even in
user-mode.

### mTLS: SAN-based push/pull split, not CN

Buildbarn's `AuthenticationPolicy.tlsClientCertificate` supports a
`validation_jmespath_expression`, but its docs explicitly recommend using it
for **authentication** decisions, not **authorization** — a failed match
returns `UNAUTHENTICATED`, not `PERMISSION_DENIED`, so gating write access
this way muddies the error semantics of a not-yet-registered pull cert vs. a
valid pull cert trying to push. Instead: one CA signs two client certs (SAN
`spiffe://krytis/ci-push` for CI, `spiffe://krytis/pull` for everyone else),
and the actual push/pull split is enforced per-operation via `putAuthorizer`/
`pushAuthorizer` (`jmespathExpression` matching the SAN) vs. `getAuthorizer`/
`fetchAuthorizer` (`allow: {}` for any cert signed by the CA). CN was
considered and rejected — SAN is what Buildbarn's own docs use for this kind
of identity check.

### Volume naming for Quadlet-referenced `.volume` units

A `.container` unit's `Volume=` line referencing a sibling `.volume` unit
must keep the **`.volume` suffix** — `Volume=buildbarn-storage-cas.volume:/data/storage-cas`.
Dropping the suffix (`Volume=buildbarn-storage-cas:/data/storage-cas`) looks
plausible but silently breaks unit-reference detection: `/usr/libexec/podman/quadlet
-dryrun` shows the generated `ExecStart=` falls back to treating the name as
a literal podman volume (`-v buildbarn-storage-cas:...`) instead of the
managed `systemd-<name>` volume the sibling `.volume` unit actually creates
(`-v systemd-buildbarn-storage-cas:...`) — two different volumes, one of
which is never created by the `-volume.service` unit. Always dry-run new
quadlet units with `QUADLET_UNIT_DIRS=<dir> /usr/libexec/podman/quadlet
-dryrun -no-kmsg-log` and grep the `ExecStart=` line for the `systemd-`
prefix on every volume reference before trusting the unit.

### Rootless bridge networking needs nft/iptables — use `Network=host` instead

A custom Quadlet `.network` unit (`podman network create`, netavark backend)
failed on this dev box with:

```
Error: netavark: code: 3, msg: modprobe: ERROR: could not insert 'ip_tables': Operation not permitted
iptables v1.8.13 (legacy): can't initialize iptables table `nat': Table does not exist
```

Rootless bridge networking needs NAT (iptables/nftables) support in the
user namespace, which isn't guaranteed to be available (missing `nft`
binary, restricted kernel module loading, etc.). Buildbarn's own two
services don't need a bridge network's DNS-by-container-name convenience
badly enough to justify that fragility for local/dev use: `bb-storage` and
`bb-asset` both use `Network=host` and reach each other over `localhost`
at their published ports instead of a `bb-storage:8981`-style container DNS
name. This does mean the two services can no longer share port `8981`
internally — each needs a distinct host-facing port baked directly into
its own `grpcServers.listenAddresses` (no publish-time remapping exists
under `Network=host`).

If the shared runner box turns out to support rootless bridge networking
fine, reintroducing a `.network` unit there is a reasonable follow-up —
just re-run the `modprobe ip_tables`/`nft` check first rather than assuming
it'll work because it works elsewhere.

### `Exec=` takes the config path positionally, not as `-config <path>`

`Exec=-config /config/storage.jsonnet` produces `Usage: bb_storage
bb_storage.jsonnet` and exits — both `bb_storage` and `bb_remote_asset`
take the jsonnet config path as a bare positional argument. `-config` looks
like a plausible flag by analogy with other Buildbarn-adjacent tooling but
isn't one here.

### TLS server cert: `serverKeyPair.files`, not `serverCertificate`/`serverPrivateKey`, and `refreshInterval` is mandatory

The `tls.proto` `ServerConfiguration` message **reserves** the old flat
`server_certificate`/`server_private_key` fields (present in some outdated
examples floating around) in favor of a `server_key_pair` oneof:
`inline: {certificate, privateKey}` (raw PEM strings — forces
`importstr`, see below) or `files: {certificatePath, privateKeyPath,
refreshInterval}`. Use `files` — it also means the daemon can hot-reload a
rotated cert without a restart. `refreshInterval` looks optional but isn't:
leaving it unset produces `Failed to parse refresh interval: proto: invalid
nil Duration`. Set it explicitly even for a cert that's never rotated
(e.g. `'3600s'`).

### jsonnet `importstr`/`import` require a string literal path

`importstr certDir + '/ca.crt'` (concatenating a local variable) fails with
`RUNTIME ERROR: Computed imports are not allowed`. The path has to be
written out in full at each call site — no path-prefix variable, no
helper function wrapping it.

### mTLS authorization requires an explicit metadata-extraction expression — it isn't automatic

Setting `tlsClientCertificate.clientCertificateAuthorities` is enough to
*authenticate* a connection (verify the client cert against the CA), but on
its own it does **not** populate `AuthenticationMetadata` for any later
Authorizer to read. `AuthorizerConfiguration`'s `jmespath_expression`
variant runs against `{authenticationMetadata, files, instanceName}` — if
`authenticationMetadata.public`/`.private` were never populated, an
expression like `contains(authenticationMetadata.public.uris, ...)`
simply evaluates against a null/missing field. The
`tlsClientCertificate` policy needs its own
`metadataExtractionJmespathExpression` (e.g. `` `{public: {uris: uris}}` ``
— same `{dnsNames, emailAddresses, uris}` SAN context as the validation
expression) to actually carry the cert's SAN into
`AuthenticationMetadata.public` where the per-operation Authorizer can see
it. Two separate jmespath expressions, two separate jobs: validation
decides *whether* the handshake authenticates; metadata-extraction decides
*what* gets handed to authorization.

### A raw TLS handshake succeeding without a client cert doesn't mean mTLS isn't enforced

`openssl s_client -connect host:port` (no `-cert`/`-key`) completing with
`Verify return code: 0 (ok)` only proves the *server's* cert validated —
it says nothing about whether the connection would be authorized to make an
actual gRPC call. Buildbarn's TLS client-cert policy operates at the gRPC
interceptor layer (per the client-cert config's own docs: a validation
failure returns gRPC `UNAUTHENTICATED`, not a TLS handshake abort) so the
TCP/TLS layer deliberately completes even for an unauthenticated peer.
Confirming the push/pull split actually holds requires a real gRPC call
(e.g. `bst source push`/`bst artifact push` once #339/#340 wire
`project.conf` at this remote) — a bare `openssl s_client` probe is not
sufficient evidence either way.

### Freshly created named volumes need `persistent_state` pre-created

Neither `bb_storage` nor `bb_remote_asset` create their own
`persistent_state` subdirectory inside a brand-new (empty) data volume —
first start fails with `Failed to open persistent state directory ...: no
such file or directory`. `mise buildbarn:install` seeds each of the four
named volumes with an empty `persistent_state/` dir via a throwaway
`busybox` container before starting the services; skip this step and a
fresh volume will not come up.

### Server cert SAN must include the actual connecting hostname

A client connecting to `https://<host>:<port>` fails with `Peer name <host>
is not in peer certificate` if the server cert's SAN list only has the
in-container aliases (`localhost`, `bb-storage`, `bb-asset`, `127.0.0.1`)
and not the hostname clients actually dial. `mise buildbarn:certs-init`
now adds `$(hostname)`/`$(hostname -f)` to the SAN automatically. If the
CA already exists (the common case — `certs-init` is idempotent and skips
everything once `ca.crt` is present), the server cert has to be **manually
reissued** with the corrected SAN using the existing `ca.key`/`server.key`
— reissuing the leaf server cert doesn't invalidate the CA or any already-
issued client cert, only the CA rotation would.

### `project.conf`'s `source-caches:`/`artifacts:` need separate `type: index` / `type: storage` entries

A single unsplit cache entry (the implicit `type: all`) assumes **one**
endpoint serves both the remote-asset index and the CAS storage. Buildbarn
splits these across two services/ports (`bb-asset` = index, `bb-storage` =
storage) — pointing a single `type: all`-implied entry at `bb-asset` alone
fails every push with `UNIMPLEMENTED: unknown service
build.bazel.remote.execution.v2.ContentAddressableStorage` (bb-asset simply
doesn't implement the CAS API). Fix: two entries per cache list, one
`type: index` at the `bb-asset` port, one `type: storage` at the
`bb-storage` port — matches the shape of Buildbarn's own docker-compose
reference example almost exactly.

### bb-remote-asset's HTTP fetcher can't serve `FetchDirectory` — use the `error` fetcher for a pure cache

BuildStream's source cache pushes/fetches multi-file sources as CAS
Directory trees, not single blobs. `fetcher: { http: {} }` (the shape used
in every Buildbarn reference example) can only serve blob fetches over
HTTP, and every push fails with `PERMISSION_DENIED: FetchDirectory: 7: HTTP
Fetching of directories is not supported!` — the asset service tries an
existence-check `FetchDirectory` internally as part of handling `Push`,
hits the unsupported path, and aborts the whole push. This is also simply
the wrong fetcher for krytis's use case: `bb-asset` is meant to be a *pure
cache* (krytis's own `bst` invocations do the real upstream fetch and push
the result here) — it should never reach out on its own. `fetcher.proto`
has a purpose-built `error` variant for exactly this ("can be wrapped by
CachingFetcher for a Push/Fetch service without any server side
downloads"): `fetcher: { 'error': { code: 5, message: '...' } }` (code `5`
= `NOT_FOUND`) makes a cache miss behave like an empty cache instead of
attempting a doomed live fetch. Note the quotes around `'error'` — it's a
jsonnet/Go-reserved-adjacent keyword and parses as a syntax error unquoted.

### First-deploy verification

All of the above was found and fixed by actually running
`mise buildbarn:certs-init` → `mise buildbarn:install` →
`mise buildbarn:status` end-to-end on a rootless dev box, not by reading
docs alone. Full round trip verified against #339's `project.conf` wiring:
with `~/.cache/buildstream` **completely wiped**, `bst source push
core/linux-cachyos.bst` succeeded against the local remote, and a
subsequent `bst source fetch core/linux-cachyos.bst` pulled the source
entirely from `melog:7981`/`melog:7982` — zero requests to the upstream
CachyOS CDN. This is the actual #233 resilience scenario, proven working
end-to-end, not just plausible from reading the design.

Still open: CI-side push wiring (`cache-warm.yml` generating a push-enabled
`buildstream.conf` with CI's `ci-push` cert from a GitHub Actions secret)
is deferred until Buildbarn is actually deployed on the shared runner box
— that's a Security Gate item (secret provisioning) that needs a human
decision, not something to wire silently. Local verification used a
hand-written `~/.config/buildstream.conf` user-config override (not
committed) with `type: index`/`type: storage` split entries mirroring
`project.conf`, pointed at the same `ci-push` cert `certs-init` already
generates locally.

### Artifacts need the same `type: index`/`type: storage` split as sources

Unlike the initial assumption ("artifacts only need CAS + ActionCache,
both served by `bb-storage` alone"), BuildStream's artifact protocol also
resolves artifact refs via the Remote Asset Fetch service, same as
sources. A single unsplit entry against `bb-storage` alone fails
immediately with `Configured remote does not implement the Remote Asset
Fetch service. Please check remote configuration.` — `project.conf`'s
`artifacts:` needs the identical `type: index` (at `bb-asset`) /
`type: storage` (at `bb-storage`) pair as `source-caches:` (#339), not the
single-entry shape shown in BuildStream's own "Global caches" user-config
docs example (that example assumes one combined server, which isn't our
topology).

### Artifact cache verified live: real pushes into the krytis remote during a bootstrap build

With `~/.cache/buildstream` wiped (left over from #339's source-cache
wipe test) and `mise bst build core/linux-cachyos.bst` running, the log
shows real `Pushed artifact <key> -> https://melog:7981` /
`Pushed data from artifact <key> -> https://melog:7982` lines for elements
as they complete (e.g. `freedesktop-sdk.bst:bootstrap/build/python3.bst`,
`freedesktop-sdk.bst:bootstrap/base-sdk/binary-seed.bst`) — confirming the
write path (mTLS push auth, `type: index`/`type: storage` routing) works
under real build load, not just a synthetic single-element push/pull like
#339's test. A one-off `UNAUTHENTICATED: Client provided no X.509 client
certificate` warning appeared on the very first remote-init attempt and
self-resolved on retry — treat a single transient auth warning at startup
as noise if subsequent pushes succeed; only worry if it repeats per-element.

## Deployed remote: bow (materia), JWT bearer token instead of mTLS

The design above (mTLS: CA + per-role client certs) was the **local
dev-test** design, verified against a Buildbarn instance on the dev
workstation. krytis's own `project.conf` now points at a real deployed
instance instead — `bst-cache.ririi.dev:7981`/`:7982`, on `bow`, managed
by a separate repo (`materia`, a GitOps Podman orchestration project —
see `specs/plans/issue-28-bst-cache-krytis.md` and
`specs/plans/issue-28-krytis-handoff.md` there for the full server-side
design, deployment, and handoff). **The auth model changed** during that
deployment — not a preference, a hard constraint discovered live:

### HS256 (mTLS's originally-planned JWT successor) doesn't work — Buildbarn requires an asymmetric algorithm

Buildbarn's JWT signature validator only accepts asymmetric public keys.
go-jose v3's `JSONWebKey.Valid()` has no `case []byte:` (returns `false`
for symmetric/`oct` keys — go-jose issue #314), and
`bb-storage`'s `NewSignatureValidatorFromJSONWebKeySet` type switch only
handles `*ecdsa.PublicKey` / `ed25519.PublicKey` / `*rsa.PublicKey` — no
symmetric case either. An HS256 JWKS (`kty: oct`) crashes `bb-storage`
with `Invalid JSON Web Key at index 0` on startup. This is a fundamental
incompatibility, not a config mistake — confirmed by an actual crash on
live deployment, not caught by local dry-run testing since the local mTLS
design never touched JWT at all.

The materia-side fix: switched to **EdDSA (Ed25519)** — one keypair, no
CA, no per-role client certs (closer in spirit to krytis's original mTLS
design than HS256 would have been, just with one keypair instead of a CA
+ 2 client certs). If krytis ever needs to mint or verify a token
client-side for debugging, it's Ed25519 signatures (`openssl pkeyutl
-sign/-verify -rawin`, not HMAC) — the JWT header is
`{"alg":"EdDSA","typ":"JWT"}`.

### `auth:` config shape — `access-token`, not `client-cert`/`client-key`

BuildStream's project-config `auth:` block still only needs
`server-cert` (unchanged — Buildbarn still terminates its own TLS,
server-only, for confidentiality through the tunnel; there's no client
cert anymore, but the connection is still TLS and still needs a
trusted server cert). What changes is the **user-config** side
(CI/local `buildstream.conf`, never committed to this repo):

```yaml
# OLD (local mTLS dev-test design, PRs #341–#343's original local testing) — remove:
auth:
  server-cert: /path/to/ca.crt
  client-cert: /path/to/ci-push.crt
  client-key:  /path/to/ci-push.key

# NEW (JWT/EdDSA against the deployed bow instance):
auth:
  server-cert: /path/to/bow-server.crt   # quadlet/buildbarn/certs/bow-server.crt in this repo
  access-token: /path/to/token            # file containing the minted push or pull JWT string
```

BuildStream's own docs describe `access-token` as "path to a token for
optional HTTP bearer authentication" — sent as `Authorization: Bearer
<token>`, exactly what Buildbarn's `jwt` `AuthenticationPolicy` expects.
Tokens are minted on the materia side (`mise buildbarn:mint-token
--role push|pull`, run from the materia repo with vault access) — not
something krytis mints or stores; the `push` token goes into krytis's
GitHub Actions secrets (e.g. `BUILDBARN_PUSH_TOKEN`), written to a file
at CI workflow start, path passed as `access-token`.

### Two other live-deploy-only gotchas (materia side, documented here for anyone debugging a connection failure from the krytis side)

- The JWT policy's claim-validation field is `claims_validation_jmespath_expression`
  (`claimsValidationJmespathExpression` in jsonnet) — **not**
  `validationJmespathExpression` like the x509/mTLS policy used above.
  Different Buildbarn config messages, same concept, different field
  name (a `claims_` prefix the x509 one doesn't have). A live crash
  (`unknown field validationJmespathExpression`) caught this on the
  materia side — irrelevant to krytis's own config, but explains why the
  two policies in this doc don't look symmetric if you go compare them.
- `cacheReplacementPolicy` (e.g. `LEAST_RECENTLY_USED`) is a **required**
  field on the JWT policy's token-validation cache, not optional — the
  proto3 zero value is `UNKNOWN`, which `bb-storage` rejects outright.

None of the above requires a krytis-side code change beyond the
`auth:` shape swap — they're Buildbarn/materia-side config details,
included here because a connection failure investigated from krytis's
side (`UNAUTHENTICATED`, `PERMISSION_DENIED`) could plausibly be
misdiagnosed as a krytis-side problem without this context.

### Local push/pull verification against the deployed bow remote (#340)

Done with a hand-written user-config override (not committed, same pattern
as the earlier local mTLS verification) pointed at `bst-cache.ririi.dev`
with `push`/`pull` JWTs pulled from Proton Pass (Krytis vault, "Buildbarn"
item). `bst source push`/`fetch` round-tripped cleanly against
`core/gum.bst` (small `kind: tar` GitHub-release source — reliable to
re-fetch on demand, unlike `core/linux-cachyos.bst`, whose upstream tarball
was returning a 404 at time of testing: the exact #233 resilience scenario
this cache exists to solve, but unhelpful as a push-test fixture since a
cold-cache push needs a successful upstream fetch first).

Two gotchas surfaced that aren't covered above:

- **Combining `artifacts:` and `source-caches:` overrides in one user-config
  file crashes `bst source push`** with `AssertionError: Trying to add task
  group 'Fetch' to {'Fetch': ...}` — BuildStream's scheduler double-registers
  the Fetch queue when both cache types are configured together for a
  source-only operation. Not a Buildbarn-side issue — a BuildStream 2.7.0
  scheduler bug. Workaround: use separate single-purpose config files (one
  with only `source-caches:` for source push/fetch, one with only
  `artifacts:` for artifact push/pull) rather than one combined file, even
  though the deployed-remote urls/auth are otherwise identical between them.
- **`mise run bst --container -- --config <path> <subcommand> ...` fails**
  with `Error: No such command '--config'` — the task's `FLAGS` (always
  prepended) vs. the trailing `"$@"` ordering means a `--config` placed in
  the trailing args after `--container --` doesn't parse as a top-level bst
  option the way it looks like it should. Pass it via `BST_FLAGS="--config
  <path>"` instead (already prepended ahead of the subcommand by the task):
  `BST_FLAGS="--config /src/.buildbarn-test/push.conf" mise run bst
  --container -- source push core/gum.bst`.

**Artifact push/pull is now verified end-to-end** against bow, and
#348 (freedesktop-sdk artifact cache appeared empty) has a confirmed root
cause — see below.

### Why every freedesktop-sdk artifact pull missed (#348) — not a broken cache, an `x86_64_v3` cache-key divergence

Initial diagnosis (#348) assumed `cache.freedesktop-sdk.io:11001` had lost
its artifact index since it served every bootstrap **source** but zero
bootstrap **artifacts**. Retested against `gbm.gnome.org:11003` directly
(`bst build core/gum.bst` with only that remote configured): same result
— every single FDSDK bootstrap/component artifact pull was skipped
("does not have artifact cached"), across the *entire* dependency chain, not
just bootstrap. That ruled out "one broken mirror" and pointed at something
structural common to every krytis build.

krytis's `project.conf` sets the freedesktop-sdk `x86_64_v3` option to
`true` project-wide (`elements/freedesktop-sdk.bst`, `project.conf`) —
AVX2 (`-march=x86-64-v3`) codegen for the whole SDK. Public FDSDK caches
almost certainly serve the upstream default (baseline `x86_64`, no AVX2).
BuildStream's cache key for a compiled element incorporates every variable
that affects its build output, so `x86_64_v3=true` changes the cache key of
**every single compiled element in the graph**, all the way down to
`bootstrap/gcc.bst` itself — while leaving *sources* (tarballs/git
checkouts, which don't depend on compiler flags) completely unaffected.
That's exactly the pattern observed: 100% source hits, 0% artifact hits,
regardless of which public remote was tried.

Confirmed empirically: `bst build -o x86_64_v3 false core/gum.bst` against
`gbm.gnome.org:11003` alone pulled all 16 required FDSDK bootstrap/component
artifacts cleanly (0 built) and finished in 67s total — versus the >500s,
still-incomplete from-scratch build under `x86_64_v3=true` attempted
earlier. **Conclusion: krytis can never get artifact-cache hits from any
public FDSDK cache for compiled elements as long as `x86_64_v3` stays
enabled** — every cold build rebuilds the whole SDK from scratch, and bow's
Buildbarn cache (populated by krytis's own `x86_64_v3` builds via
`cache-warm.yml`) is the *only* cache that will ever have matching keys.
This isn't a bug to fix; it's the reason the Buildbarn cache work (#234)
exists in the first place.

### `max-jobs` does NOT affect cache keys — a prior fix's stated reason was wrong (corrected 2026-07-29)

A second cache-key divergence was investigated when testing `cache-warm.yml`
on a Blacksmith-hosted runner (`blacksmith-8vcpu-ubuntu-2404`) after it had
already been populating bow from the self-hosted runner (`VM_CPUS=4`): the
Blacksmith run initially showed **zero** cache hits against bow for the
entire build, even though it built the exact same commit the self-hosted
runner had just successfully pushed to bow from.

**Caveat on "zero cache hits" as a diagnostic signal:** the *initial*
pipeline table (`waiting`/`fetch needed`/`cached` counts printed right after
"Query cache") only reflects the **local** BuildStream cache, which is
always empty on a fresh CI runner regardless of runner identity — it does
**not** indicate remote (bow) hit/miss. The real signal is the per-element
`pull:<element>` log lines that appear as the build actually processes each
element (`INFO Pulled artifact X <- https://...` vs `INFO ... does not have
artifact X cached`). Don't conflate the two when diagnosing a similar report.

**The original diagnosis (`max-jobs` bakes into a cache-key-affecting
`LTOJOBS`/`JOBS` environment variable) is FALSE — verified and retracted.**
Confirmed directly against the pinned `freedesktop-sdk-25.08.14-0-...` ref's
own `meson-conf.yml`, and against the upstream `buildstream_plugins`
package's `autotools.yaml`/`meson.yaml` (the actual source of the `autotools`
and `meson` element kinds), that the parallelism variable is *deliberately*
excluded from the cache key in every case:

```yaml
# buildstream_plugins/elements/autotools.yaml
environment:
  MAKEFLAGS: -j%{max-jobs}
environment-nocache:
- MAKEFLAGS
- V

# buildstream_plugins/elements/meson.yaml
environment:
  JOBS: "%{max-jobs}"
environment-nocache:
- JOBS

# freedesktop-sdk's own include/_private/meson-conf.yml
environment:
  LTOJOBS: "%{max-jobs}"
environment-nocache:
  (>):
  - LTOJOBS
```

Every one of these variables is declared under `environment:` **and then
explicitly re-listed under `environment-nocache:`** — the opposite of what
the original write-up claimed. Upstream's own comment on the autotools/meson
files states the intent directly: "And dont consider MAKEFLAGS/JOBS as
something which may affect build output." `-j4` vs `-j8` produces
byte-identical build *output*, just different build *time*; excluding it
from the cache key is correct BuildStream plugin design, not an oversight.

**Verified empirically**, not just by reading YAML: `bst show --format
'%{full-key}'` against `freedesktop-sdk.bst:components/m4.bst`,
`freedesktop-sdk.bst:bootstrap/build/gcc-stage1.bst` (autotools), and
`freedesktop-sdk.bst:components/systemd-ukify.bst` (meson) all produced
**byte-identical keys** at `build.max-jobs` values of 1, 4, 8, and 32. This
also directly answers #337 (FDSDK artifact cache misses): `max-jobs` is not
and cannot be the explanation there either — #337's own confirmed root cause
(krytis reads the public, apparently-unpopulated `cache.freedesktop-sdk.io:11001`,
while FDSDK's own CI writes to the authenticated `:11004`) stands unchanged.

**What this means for the Blacksmith-vs-self-hosted investigation:** the
stated mechanism was wrong, so whatever actually caused the original
"zero cache hits" report is back to unexplained. Two candidates, neither
confirmed:

1. The report was itself a misread of the local-vs-remote-cache caveat
   documented above — plausible, since that exact confusion is what this
   section now leads with as a warning.
2. `build.max-jobs: 4` was pinned as part of a `buildstream.conf` rewrite
   that also changed something else (scheduler settings, `cache.quota`,
   generation order) which was the real fix, misattributed to the `max-jobs`
   line specifically because it was the one deliberately added.

The pin itself (`build: { max-jobs: 4 }` in `cache-warm.yml`'s generated
`buildstream.conf`) is harmless and can stay — it makes local build
parallelism reproducible across runners, which is a reasonable thing to
pin regardless — but do not cite "matches bow's cache key shape" as the
reason going forward, and do not treat changing it as cache-busting.

**The "829/837 elements now match" and `expat.bst` findings below remain
useful data points** (a real cache-key diff was run, real numbers came out
of it) but their causal link to the `max-jobs` pin specifically should be
treated as unconfirmed, not "verified effective," per the above.

**Verified** by a full element-by-element cache-key diff between
a self-hosted run and a post-fix Blacksmith run (same commit, `runs-on:`
the only difference): **829 of 837 elements (99%) computed byte-identical
keys.** The 8 that differed are *expected, not a bug*:

```
core/os-release.bst, oci/os-release.bst, core/initramfs.bst,
oci/krytis/stack.bst, oci/krytis/manifest.bst, oci/krytis/runtime.bst,
oci/krytis/filesystem.bst, oci/krytis/image.bst
```

All 8 sit downstream of `mise run generate-image-version`, which bakes a
build timestamp into the image version string — every independent build run
gets a unique version stamp, so these 8 (and only these 8, the very top of
the graph) can never cache-match across separate runs, on any runner.
`oci/krytis/image.bst` itself will never be a genuine bow hit across builds;
that's inherent to versioning each build uniquely, not something to fix.

**A third, unrelated failure mode looks identical in the log but isn't a
key mismatch at all:** a `does not have artifact <hash> cached` message
doesn't by itself prove a key divergence — confirm the hash actually differs
from a known-good run before assuming the environment is at fault. Case in
point: `freedesktop-sdk.bst:components/expat.bst` (`b07b1a0a...`) reported
as a bow miss on Blacksmith even after the `max-jobs` pin, but its key was
confirmed byte-identical to the self-hosted run's key for the same element.
The actual cause: the self-hosted run's log showed `expat.bst` as `cached`
**before any build/pull activity even ran**, meaning it came from
self-hosted's persistent local disk cache (volume-mounted across runs, see
above), not from bow — so BuildStream never triggered a build+push cycle for
it on self-hosted, and bow's remote CAS genuinely never received that
artifact. This is an incremental cache-population gap (bow hasn't been
fully warmed yet), not a correctness bug; it resolves as future `cache-warm`
runs actually build and push whatever's still missing.


### Full artifact push/pull round-trip verified against bow

Using the `-o x86_64_v3 false` override purely as a way to get a *fast*
artifact build for the test (not a project-wide change — real krytis builds
still use `x86_64_v3=true`): built `core/gum.bst` in 67s pulling FDSDK
deps from `gbm.gnome.org`, then `bst artifact push core/gum.bst` against
bow (push token) succeeded, then wiped `~/.cache/buildstream` completely
and `bst artifact pull core/gum.bst` against bow (pull token) pulled it
back in ~7s — confirming both `type: index` (bb-asset) and `type: storage`
(bb-storage) round-trip correctly for artifacts, matching the source-cache
verification above.

One more command-composition gotcha found doing this: `BST_FLAGS` (additive,
appended after the task's `DEFAULT_FLAGS`) isn't reliable for overriding an
already-set flag like `-o x86_64_v3 true` — use `BST_FLAGS_OVERRIDE` instead
to fully replace the default flag set when a test needs to override
something the task sets by default:
```bash
BST_FLAGS_OVERRIDE="-o x86_64_v3 false --no-interactive --config /src/.buildbarn-test/pull-artifact-only.conf" \
  mise run bst --container -- artifact pull core/gum.bst
```

### `project.conf` deliberately omits bow entries — bearer auth means a token-less entry can never work

`bst-cache.ririi.dev` (bow) requires a JWT bearer token for **every** RPC,
read or write — not just push. Buildbarn's `jwt` `AuthenticationPolicy`
gates the connection itself; there's no anonymous-read carve-out. Since no
token is ever committed to this repo, a `project.conf` entry for bow with
only `server-cert` (no `access-token`) can *never* authenticate — it isn't
a fallback that degrades gracefully, it's permanently dead. The original
#339/#340 wiring declared bow in `project.conf` anyway (reasoning: "a
read-only default, override with a token for write access"), which seemed
right by analogy to `gbm.gnome.org`/`cache.projectbluefin.io` (genuinely
anonymous-read remotes) but doesn't hold for bow — the result was two
permanent `UNAUTHENTICATED` warnings per cache type, on every single build,
forever, confirmed live in a `cache-warm` run even with a valid push token
configured (BuildStream doesn't dedupe user-config and project.conf entries
for the same URL — both get tried, and the token-less one always fails).

**Fix:** removed the `bst-cache.ririi.dev` entries from both `artifacts:`
and `source-caches:` in `project.conf` entirely. bow is now reached *only*
via a user-config override that supplies `access-token` — `cache-warm.yml`
is the only current consumer (see below). Anyone who wants local bow access
adds their own `~/.config/buildstream.conf` override with a minted token,
same as the local push/pull verification did.

### `cache-warm.yml` wires bow via push token, falling back to a pull-only token

`cache-warm.yml`'s original scope (#340) included wiring the warm-cache
build to *push* krytis-built sources/artifacts into bow as it builds, not
just pull from it. The mechanism: BuildStream pushes each artifact to any
push-enabled remote as soon as that element finishes building, so a normal
`cache-warm` run incrementally populates bow over the course of the build
— no separate "push everything at the end" step needed.

Since `project.conf` no longer declares bow at all (see above), the
"Configure BuildStream" step is the *only* place bow gets wired, and it now
prefers `BUILDBARN_PUSH_TOKEN` over `BUILDBARN_PULL_TOKEN`:

- **Push token present:** used for both `artifacts:` and `source-caches:`,
  `push: true` on both `type: index`/`type: storage` entries. A
  push-capable connection also serves reads (verified live — the same run
  that pushed also queried the cache successfully), so this alone covers
  both directions.
- **Push token absent, pull token present:** falls back to the same entries
  with `push: false`, so `cache-warm` still benefits from whatever's
  already in bow (faster builds) even when push isn't configured — e.g. the
  push secret isn't provisioned yet, or got rotated out. Push and pull are
  minted as **separate JWT roles** (materia's `mise buildbarn:mint-token
  --role push|pull`) — a push-role token isn't guaranteed to authorize
  reads by design, even though it happened to work in the live test above,
  so don't assume one token covers both; wire the role you actually need.
- **Neither present:** no bow entries in user config at all — `cache-warm`
  builds against `gbm.gnome.org`/`cache.projectbluefin.io` only, cleanly,
  no warnings (since `project.conf` doesn't declare bow either).

The token file is written to `$RUNNER_TEMP` with `printf '%s'` (not `echo`,
to avoid a trailing newline in the token). Both secrets have to be added by
a human through the GitHub repo settings UI — provisioning a production
secret is a Security Gate item per AGENTS.md, not something to wire or set
autonomously.

## Workflow Runner Choices

| Workflow | Runner | Rationale |
|---|---|---|
| `cache-warm.yml` | `blacksmith-8vcpu-ubuntu-2404` (default); `[self-hosted, linux, x64]` via `workflow_dispatch` input `force_self_hosted` | Blacksmith by default since #351; self-hosted override exists to keep bow's cache-key shape aligned with the host that originally populated it (`VM_CPUS=4`), to prime bow ahead of a heavy element update, or to reproduce a build on the real hardware |
| `publish.yml` | `blacksmith-8vcpu-ubuntu-2404` (default); `[self-hosted, linux, x64]` via `workflow_dispatch` input `force_self_hosted` | Same escape hatch as `cache-warm.yml` — debug a publish failure on the real hardware, or fall back when Blacksmith is degraded/unavailable. `publish.yml` is `workflow_dispatch`-only (no schedule), so the input is unconditional (`inputs.force_self_hosted`) — no `github.event_name == 'workflow_dispatch'` guard needed, unlike `cache-warm.yml` which also has a `schedule` trigger. **Sealed builds belong on Blacksmith** — the self-hosted runner has no podman; see § The self-hosted runner container has no podman |
| `track-bst-sources.yml` | `ubuntu-24.04` | Lightweight; must run when local machine is off |

The `force_self_hosted` input only takes effect on manual `workflow_dispatch` runs — scheduled (cron) runs always land on Blacksmith. `build.max-jobs` stays pinned to `4` regardless of which runner executes — this does not affect cache-key matching (`max-jobs` is excluded from cache keys, see above), it's kept purely for reproducible local build parallelism across runners.

### Blacksmith container caching — not applicable here (evaluated 2026-08-06)

Blacksmith rolled out free org-wide "container caching" (a persistent,
org-scoped disk cache for images pulled by GitHub Actions' own
`container:`/`services:` job keys, so the "Initialize containers" step
doesn't re-pull on every run). **No krytis workflow uses `container:` or
`services:`** — every job runs steps directly on the runner VM; image
pulls/builds happen *inside* those steps via `podman`/`mise run
build`/`bst` (BuildStream's own source/artifact fetching), not via GitHub
Actions' job-container mechanism. Blacksmith's feature has nothing to
attach to, so it's a genuine no-op for this repo, not a missed
opportunity — don't re-evaluate this without a workflow actually adding
a `container:`/`services:` key first.

## The self-hosted runner container has no podman

`Containerfile.runner` is `FROM ubuntu:24.04` and installs bubblewrap, bzip2, curl,
git, jq, mise and the Actions runner — **not podman**. `mise/tasks/runner/start` mounts
only `~/.cache/buildstream`, so nothing supplies the host's podman either. Any job that
shells out to podman therefore dies on the self-hosted runner with:

```
./mise/tasks/load-image: line 69: podman: command not found      # exit 127
```

`publish.yml` carries a guarded install so the `force_self_hosted` escape hatch works:

```yaml
run: command -v podman >/dev/null || sudo apt-get install -y -qq podman
```

Same shape as the one in `verify-sealed.yml`. The `command -v` guard keeps it a no-op on
a runner that already has podman.

A red herring in those logs: `dnf: 6 package(s) skipped (dnf not found)` is expected on
Ubuntu — `[bootstrap.packages]` lists `apt:` and `dnf:` variants and only the matching
set applies. Unrelated to any failure.

### Where sealed images are actually built — and a version guard that was wrong

**Every sealed image this project has published was built on Blacksmith, with podman
4.9.3 / buildah 1.33.7** (its image mirrors GitHub's `ubuntu-24.04`). `publish.yml` has
used Blacksmith since #388; #511 only *added* the `force_self_hosted` input.

#524 asserted `podman >= 5` in `seal-uki`, reasoning that the two-phase squash was only
ever verified on 5.x, and routed sealed runs to self-hosted to satisfy it. Both halves
were wrong, and #527 reverted them:

- The engine that built the validated artifacts **is** 4.9.3. The 2026-08-04 `:sealed`
  image passed `tpm-boot-test`, `luks-install-test`, `iso-install-test --secure` and
  `selfenroll-test` — the first boots that exact UKI, so a wrong composefs digest could
  not have passed. 4.9.3 and 5.8.2 both work.
- Routing sealed builds to self-hosted moved them to the runner *without* podman, then
  apt-installed 4.9.3 there, which the new guard rejected. The default dispatch
  (`publish_sealed=true`) broke outright.

**The method error is the part worth keeping.** `RUNNER_IMAGE` and `RUNNER_VERSION`
appear in every job's env because they are workflow-level `env:`, not evidence of which
runner ran. Ask the API:

```bash
gh api repos/starlit-os/krytis/actions/runs/<id>/jobs --jq '.jobs[] | "\(.runner_name) \(.labels)"'
# krytis-local  ["self-hosted","linux","x64"]
# blacksmith-…  ["blacksmith-8vcpu-ubuntu-2404"]
```

Before asserting that a toolchain version is required, check what version built the
artifacts you have already validated. The engine-sensitivity of the squash is real; the
fix is to **verify the baked digest** rather than to guess at version numbers.

## `max-jobs` should only be set high when remote-execution is on

*Source: zirconium-hawaii `aceeb13` — `fix: set max-jobs to 12 only when remote-execution is on`*

Setting `max-jobs` high (e.g. 12–32) on a local GitHub Actions runner **without** remote CAS causes problems — the runner doesn't have the CPU/RAM to actually parallelize that many local builds, and they contend for resources. Only raise `max-jobs` when remote-execution is enabled (the actual builds happen on the CAS server cluster). Gate the `max-jobs` setting on the remote-execution flag rather than setting it unconditionally.

## `concurrency:` without `queue: max` silently drops queued runs, not just cancels in-progress ones

*Source: dakota `0aa3804` — "ci(build): queue runs FIFO with stale-run gate, detach source tracker"*

`cancel-in-progress: false` only protects a run that has already **started**. GitHub
Actions' default `queue:` behavior (`single`, undocumented as a default) still keeps only
**one pending** run per concurrency group — a new run entering the group cancels whatever
was queued behind the running one, with no error surfaced anywhere. Dakota lost a real
multi-hour build this way: a `testing`-branch push queued behind an in-progress build, then
a `next`-branch sync push landed ~40s later in the *same* concurrency group and silently
discarded the queued `testing` run.

Fix: set `queue: max` (holds every pending run FIFO instead of superseding) paired with a
cheap `stale-check` job that skips the expensive build step if a *newer* run for the same
branch is already queued behind it — this is what actually collapses a burst of pushes to
one real build, since `queue: max` alone would otherwise build every single push in order:

```yaml
concurrency:
  group: dakota-bst-build-global
  cancel-in-progress: false
  queue: max

jobs:
  stale-check:
    if: github.event_name == 'push'
    runs-on: ubuntu-24.04
    permissions:
      actions: read
    outputs:
      stale: ${{ steps.check.outputs.stale }}
    steps:
      - id: check
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          newer=0
          for status in queued pending; do
            n=$(gh run list --repo "${{ github.repository }}" --workflow build.yml \
              --branch "${{ github.ref_name }}" --event push --status "$status" \
              --json databaseId \
              --jq "[.[] | select(.databaseId > ${{ github.run_id }})] | length")
            newer=$((newer + n))
          done
          [ "$newer" -gt 0 ] && echo "stale=true" >> "$GITHUB_OUTPUT" || echo "stale=false" >> "$GITHUB_OUTPUT"

  build:
    needs: [stale-check]
    if: needs.stale-check.outputs.stale != 'true'
    # ...
```

`actionlint` versions ≤1.7.12 don't know the `queue:` key and need a `# actionlint-ignore`
comment (or an upgrade) on the `concurrency:` block.

**Krytis exposure:** `publish.yml` (`group: krytis-publish`), `cache-warm.yml`
(`group: krytis-cache-warm`), and `verify-sealed.yml` (`group: verify-sealed`) all use
`cancel-in-progress: false` with no `queue: max` — the identical landmine. `publish.yml` is
`workflow_dispatch`-only today, so the exposure is currently "two manual dispatches close
together, or a scheduled `cache-warm` racing a manual one, silently drops the earlier run
with zero error surfaced." Add `queue: max` (+ a stale-check gate if/when these workflows
trigger on `push` rather than only `workflow_dispatch`/`schedule`) before that becomes a
real incident instead of a documented risk.

## Use smaller/less-privileged CAS config for no-push phase

*Source: zirconium-hawaii `4a9b19c` — `chore: Use smaller config for no-push phase`*

When running a build phase that doesn't push to CAS (e.g. a validation-only or no-push CI phase), don't specify the key/auth/mTLS config. Use a smaller, less-privileged CAS client config that authenticates read-only or anonymously. Less privilege = smaller blast radius if the config leaks, and fewer moving parts that can fail on a phase that doesn't need push capability.

## `track-bst-sources.yml` per-job gotchas

Each `track-<element>` job in this workflow is hand-written (no shared template), so two requirements don't propagate automatically when copy-pasting a new job:

- **`gh` needs `GH_TOKEN` on the specific step that calls it.** `gh api`/`gh` CLI calls fail with `gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable` if the `env:` block is missing on that step — the job-level `permissions:` block does not supply it. Check whether the underlying `mise run <x>-update` task shells out to `gh` before assuming it's not needed (e.g. `falcond-profiles-update` uses `gh api` to get the latest commit SHA since the upstream repo has no releases; `falcond-update` also needs it now that it reads `PikaOS-Linux/falcond`'s releases via `gh api` — see the Cloudflare bullet below for why it moved off a raw `curl` call to git.pika-os.com).
- **`bst source track` needs bubblewrap.** Only jobs that run `mise bootstrap --yes` (an "Install system dependencies" step) have `bwrap` on the runner. If a `<x>-update` mise task starts invoking `bst source track` (e.g. `scx-loader-update` added this to refresh a `cargo2` crate list), the job needs that step added — otherwise it fails with `Could not find bubblewrap command "bwrap"`.
- **git.pika-os.com's Cloudflare 403s GitHub's own hosted-runner IP range, not just a User-Agent.** `falcond-update` sent a real, identifying `curl -A` User-Agent — the same request succeeds from an unrelated network — and still got a persistent (not flaky) 403 on every `ubuntu-24.04` scheduled run, four days running. `bst source track`/fetch of the same host from `blacksmith-8vcpu-ubuntu-2404` (the actual build runner in `publish.yml`/`cache-warm.yml`) and self-hosted runners is unaffected, which is what points at the GH-hosted runner's IP/ASN rather than the request itself. Don't spend more time tuning the User-Agent if this recurs on another `git.pika-os.com`-sourced element — check whether a verified GitHub mirror exists (same annotated tag object id as the Gitea origin) and route through that instead; `falcond.bst` and `falcond-profiles` both do.
- **Scope every version-detecting `grep` to the `url:` line, not the whole element.** `mise/tasks/tarball-update`'s `cur=$(grep -oP "..." "$element" | head -1)` originally scanned the whole file. wlroots' header comment still said "0.20.1" after PR #652 hand-bumped the `url:`/`ref:` pair to 0.20.2 (a doc omission, not a script bug by itself) — `head -1` picked up the comment's stale "0.20.1" as `cur`, and the later rewrite then found no `url:` line containing "0.20.1" to replace and failed outright (`no url line matching '0.20.1'`). Fixed by adding a `url_lines()` helper that isolates `^\s*url:\s*` lines first; every provider's `cur=` extraction (and the `gitlab-fdo-tag` tag-prefix sniff) greps that instead of the raw file. `falcond-update`'s own `CURRENT_TAG` extraction does the same.
