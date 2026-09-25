# Issue #824 option B (`publish.yml` on `krytis-vps`) — investigated, DECLINED

**Outcome, 2026-09-25: option B is not being done. `publish.yml` stays on
Blacksmith.** Decided by the maintainer once V0 came back, on two grounds:

1. **The VPS cannot hold the signing keys.** V0 (below) found two third-party
   root-equivalent workloads co-resident with the runner, one of them on a
   floating tag. That rules out sealed publishes on that host.
2. **The only variant that survived V0 buys nothing durable.** With sealed ruled
   out, all option B could offer was routing the *unsealed* publish to the VPS —
   and the unsealed image is expected to go away. Building a runner-selection
   mechanism, a scheduler-sizing fix and a key-hygiene regime for a path with a
   planned end-of-life is cost against an artifact we intend to stop producing.

What follows is kept as the evidence behind that call, not as a checklist. The
V-sections were written as an execution plan before the decision; they are
preserved because V0's measurements and the defects in "Findings that outlive
this decision" are load-bearing for other work, and because a future proposal to
revisit this should start from what was actually measured rather than repeat it.

Issue #824's other half is untouched by this: option A (cron on Blacksmith) and
the cadence/policy question remain open and human-owned, and V7 below — nothing
boot-gates `:latest` — applies to *any* scheduled publish regardless of runner.

---

## Findings that outlive this decision

Three of the prerequisites were not VPS-specific. They stay true whether or not
publish ever moves:

- **P1** — `publish.yml:85` runs `hastd/free-disk-space` ungated, and its
  `swapoff -a && rm -f /mnt/swapfile` is wrong on *any* persistent runner. That
  includes the `force_self_hosted` escape hatch that exists today, which targets
  the local container runner running privileged on a dev workstation. Still worth
  gating.
- **P2** — `bst --config` replaces the user config, so every `mise run build
  --pull` gets `builders: 4` × `max-jobs: 4` regardless of what the host wrote to
  `~/.config/buildstream.conf`. This is not about publish or about the VPS; it is
  about any RAM-constrained host that builds with the bow cache wired. The
  mechanism is recorded in `docs/skills/ci-runner.md`, in the section following
  § Build concurrency is `builders` x `max-jobs`.
- **P5 / `provision.sh`** — `openssl` is present on the VPS only as an implicit apt
  dependency. Any task that depends on it there is relying on dependency
  resolution rather than provisioning.

None of these are in scope for this PR, which is documentation only.

---

## What is already proven on this box — do not re-verify

Every weekday `cache-warm.yml` runs on `krytis-vps`, and `build-iso.yml` (#844)
dispatches there. Between them the following are exercised evidence, not
assumption:

| Proven | By |
|---|---|
| `jdx/mise-action` with a pinned `version:`, `mise bootstrap --yes --update`, `uv sync` | `cache-warm.yml` steps 112–125, every weekday |
| BST build from the warm local CAS, `bst show`, artifact cache under a 50G quota | `cache-warm.yml` step "Build image" |
| bubblewrap/userns with **no** sysctl change (Debian has no `apparmor_restrict_unprivileged_userns`) | `docs/skills/ci-runner.md` § Debian, not Ubuntu |
| `podman run --privileged`, `podman pull/tag/rmi` on podman 5.4.2 | `build-iso.yml` steps 106–130 |
| `actions/checkout` default `clean: true` → `git clean -ffdx` wipes untracked workspace state at the *start* of every run | `docs/skills/ci-runner.md` § Disk-exhaustion pitfall is closed by `actions/checkout` |

That last one closes three would-be hazards before they start: a stale
`krytis-push-digests.env` cannot be read by the next run's verify step, a stale
`.load-image-state` cannot short-circuit `load-image`, and a `files/boot-keys/`
left by a hard-killed job cannot survive into the next job's workspace. It does
**not** make key residue safe in the window *between* those two runs — see P6.

---

## Prerequisites — code changes that must land before the first dispatch

These are not optional hardening. Two of them are live defects the moment
`publish.yml` runs on this host.

### P1. `Maximize build space` must be gated off the self-hosted branch

`publish.yml:85` runs `hastd/free-disk-space` unconditionally. On this box that
action runs `swapoff -a && rm -f /mnt/swapfile`, deleting the 8G swap
`files/runner-vps/provision.sh:89` creates as the documented OOM backstop — at
the start of every run, on a box that was OOM-killed twice in 24h
(`docs/skills/ci-runner.md` § The box ships with no swap). `cache-warm.yml:85`
already gates the identical step behind its `runs-on` expression; `publish.yml`
must do the same, reusing the same expression so the two cannot drift.

Its path deletions are also pointless here (~82G free of 197G) and its internal
`df -h` is the exact call that killed runs 34696760836 and 34723320921 on stale
FUSE mounts.

### P2. Scheduler sizing — the `--pull` path bypasses cache-warm's OOM fix

This is the sharpest finding and the one the issue's checklist misses entirely.

`cache-warm.yml:134–178` derives `builders=2`, `max-jobs=3` (≤6 concurrent
compilers, 2 GiB budgeted per slot against 11 GiB) and writes them to
`~/.config/buildstream.conf`. That file is what stopped the OOM kills.

`publish.yml` runs `mise run build --pull`, which routes through
`mise/tasks/bst`. With `--pull` that script writes a **temporary** config
(`mise/tasks/bst:92–125`) carrying `build: max-jobs: 4` and no `scheduler:`
block at all, and passes it as `bst --config <tmp>`. `--config` *replaces* the
user configuration file — it does not merge. Verified against the pinned
BuildStream 2.7.0 rather than read off the help text: a bare `bst` command with
an unknown key in `XDG_CONFIG_HOME/buildstream.conf` dies with
`Error loading user configuration: … Unexpected key`, while the same command
with `--config <other file>` never reads that file at all. So on a VPS publish
run:

- cache-warm's `builders: 2` / `max-jobs: 3` sizing does not apply,
- BST's default `builders: 4` (`data/userconfig.yaml` in the pinned 2.7.0) applies instead,
- **4 × 4 = up to 16 concurrent compilers** on a 6-vCPU/11 GiB box.

That is 2.7× the RAM-safe budget and the same shape of misconfiguration that
produced the 11.4G and 11.1G peaks. Fix in `mise/tasks/bst` (emit a
`scheduler:`/`build:` block derived the same way cache-warm derives it, so one
formula serves both callers), not by duplicating the arithmetic into
`publish.yml`.

**Acceptance:** a `--pull` build on the VPS logs the derived values, and
`ps -eo rss,comm | grep -c cc1` sampled mid-build never exceeds the derived slot
count.

### P3. Third runner option, and an expression that survives `schedule`

`force_self_hosted` is a boolean resolving to the bare
`["self-hosted","linux","x64"]` labels — which the local container runner also
registers under (`RUNNER_LABELS` in `mise.toml`), making routing
nondeterministic whenever both are online (`docs/skills/ci-runner.md` §
Distinct label). Replace with a `choice` input (`blacksmith` | `krytis-local` |
`krytis-vps`).

Write the expression so it is already correct for a `schedule` event, where
every `inputs.*` is null — `cache-warm.yml:41` is the working precedent for
guarding on `github.event_name == 'workflow_dispatch'` first.

### P4. Port cache-warm's stale-FUSE sweep

`publish.yml` has no equivalent of `cache-warm.yml:50` "Clear stale FUSE
mounts". Once `OOMPolicy=continue` keeps the runner alive across a kill, that
residue is *guaranteed* to reach the next job. Gate it on the same self-hosted
expression as P1.

### P5. Disk instrumentation and GC coverage

Add `df -h -x fuse || true` before/after the build (the `-x fuse` is mandatory —
a bare `df` exits 1 on a stale mount and would fail the job; see
`docs/skills/ci-runner.md` § A killed build leaves FUSE mounts).

`files/runner-vps/gc.sh:132–135` prunes `localhost/krytis:iso-payload`,
`krytis-installer:latest`, `iso-tools:latest`. A publish run additionally
strands `localhost/krytis-input:latest` (from `load-image`),
`localhost/krytis:latest`, and — on a sealed run — `localhost/krytis:sealed-base`
and `localhost/krytis:sealed`, plus the two `ghcr.io/starlit-os/krytis:*` tags
`push` creates. At ~8G each that is the dominant new disk consumer. Extend the
list in the same PR.

**Sizing check before the first dispatch:** measured 2026-09-25, **71G used /
119G avail of 197G** — down from the 115G recorded in `files/runner-vps/gc.sh`'s
header on 2026-09-24, so the Sunday 04:27 GC job demonstrably reclaims. An
unsealed publish adds ~16G of podman tags; a sealed one ~32G more across the two
squash phases, before CAS growth. The ≥60G-free precondition holds today; re-check
at dispatch time, or run `mise run runner-vps:gc` first.

---

## V0. Tenancy on the VPS — ANSWERED 2026-09-25, and it splits option B in two

The contradiction was real: `docs/skills/ci-runner.md:103` claimed "This VPS has
no other tenant — the VM itself is the isolation boundary", while
`files/runner-vps/gc.sh:47–50` called it a "Shared box". Resolved against the
live box (`podman inspect`, `systemctl list-units`, `/etc/containers/systemd/`),
not the docs. `ci-runner.md` was the wrong one and is corrected in this PR.

**Measured state:**

| Fact | Value |
|---|---|
| Human tenants | one unused `debian` (uid 1000); `loginctl` shows root only |
| Runner uid | 0 (`RUNNER_ALLOW_RUNASROOT=1`) |
| Co-resident workloads | `beszel-agent` (`docker.io/henrygd/beszel-agent`, running 3d) and `materia-update.container` (`ghcr.io/stryan/materia:stable`, oneshot) — both root |
| `beszel-agent` access | `Privileged=false`, but binds `/run/podman/podman.sock` |
| `materia` access | `Network=host` + `podman.sock`, `/etc/systemd/system`, `/etc/containers/systemd`, `/usr/local/bin`, all rw; image pinned to a **floating `:stable` tag** |
| Disk | 71G used / 119G avail of 197G — the Sunday GC works; P5's ≥60G precondition holds |
| `openssl` / `python3` / `shred` | all present in `/usr/bin` (implicit deps, not declared in `provision.sh`) |
| ghcr credentials | none on the box — clean baseline for V4's residue check |

**Verdict.** A read-only bind of `/run/podman/podman.sock` is not a read-only
capability: anything that can reach that socket can start a privileged container
with `/` mounted. So two third-party images — one of them on a floating tag that
can change under us on any given day — hold root-equivalent access to the host
that would be holding PK/KEK/db.

That is **fine for a build**, which carries no secrets, and **not fine for a
sealed publish**. `publish.yml:227–235` argues key custody on the premise that
the keys "touch the runner's disk only inside this job"; that premise is about
*time*, and it survives here. What does not survive is the unstated premise that
nothing else on the box can read that disk while the job runs.

**Recommendation — split option B:**

- **Unsealed publish → `krytis-vps` is fine.** No secret material beyond the
  ephemeral `GITHUB_TOKEN`, which the box would hold anyway for any job.
- **Sealed publish → stays on Blacksmith.** Ephemeral host, no co-tenants, and
  it is where every sealed image this project has shipped was built.

This is a Security Gate call, not an agent call. If the human prefers sealed
publishes on the VPS anyway, the minimum that would make it defensible is:
pin `materia` to a digest, drop `podman.sock` from `beszel-agent`, and add a
pre-job assertion that no unexpected container is running — none of which this
plan assumes.

V2 below is written for the sealed path regardless, because the human may
overrule this and because `verify-composefs-digest` on a second engine is
worth having either way.

---

## V1. Unsealed publish from `main` on `krytis-vps`

Dispatch **from `main`, not a branch.** The issue's step 2 implies a test
dispatch, but `allow_branch_publish=true` overwrites the public `:latest` with a
branch-identity signature that fails the strict policy in `docs/skills/signing.md`
(`publish.yml:69–72` says so itself). P1–P5 are inert until someone selects the
new runner option, so they can land on `main` first and the test dispatch costs
nothing.

```shell
gh workflow run publish.yml --ref main \
  -f runner=krytis-vps -f publish_sealed=false -f report_only=false
```

| Step under test | First time on this box? | Acceptance |
|---|---|---|
| `mise run vuln-scan --fail-on critical` | yes (static, low risk) | exits 0 |
| `mise run build --pull` | yes — bow `--config` path | completes; derived builders/max-jobs logged (P2); no OOM in `journalctl -u actions.runner.*` |
| `load-image`'s `bst artifact checkout --tar - \| podman load` | **yes** — podman is proven, this pipeline is not | `localhost/krytis-input:latest` present, `.load-image-state` written |
| `bootc container lint` (tail of `mise run build`) | yes | exits 0 |
| `mise run push --fail-on critical` | **yes** — `podman login ghcr.io`, two ~8G pushes, `oras attach` ×2 | `krytis-push-digests.env` has all three digests |
| `mise run sign` (cosign keyless OIDC) | **yes — never run on any self-hosted runner** | cosign obtains a Fulcio cert; step outcome `success` |
| Verify signature | yes | `cosign verify` green for image + SBOM + vuln report, identity `…/publish.yml@refs/heads/main` |

The cosign row is the one with a real chance of failing: ambient OIDC needs
`ACTIONS_ID_TOKEN_REQUEST_URL`/`_TOKEN` in the step environment. `id-token: write`
is already on the job, and self-hosted runners do receive those variables — but
this has never been exercised here, and the verify step is gated on
`steps.sign.outcome == 'success'`, so a silent sign failure would be absorbed by
`continue-on-error` and publish would still go green. **Check the sign step's log
explicitly; a green job is not proof the image was signed.**

---

## V2. Sealed publish from `main` on `krytis-vps`

```shell
gh workflow run publish.yml --ref main -f runner=krytis-vps -f publish_sealed=true
```

| Step | Risk on this box | Acceptance |
|---|---|---|
| `pass-cli login --pat` | network egress to Proton Pass from the VPS, untested | exits 0 |
| `mise run assert-vault-access` | invokes `python3` inline | `/usr/bin/python3` confirmed present 2026-09-25; no `command not found` |
| `mise run pull-keys` | needs `openssl` — present at `/usr/bin/openssl`, but **not declared** in `provision.sh:62–79`; it arrives as an implicit dependency, so a rebuilt box is not guaranteed it | all six secrets fetched, all three keypairs openssl-validated |
| `mise run seal-uki` | two-phase `--squash-all` on podman 5.4.2, never run on this engine here | phases 1–3 complete |
| `verify-composefs-digest` (phase 3/3) | the real engine-sensitivity gate | digests match |
| `push --sealed`, `sign`, verify | as V1 | `:sealed` + `:<version>-sealed` pushed, signatures verify |
| Key wipe step | `shred -u` on ext4, persistent disk | step ran; V4 confirms the disk |

`openssl`, `python3` and `shred` were all confirmed on the box on 2026-09-25, so
the "fails 20 minutes in, after the keys are already on disk" hazard is closed
for the current host. Declare `openssl` in `provision.sh` anyway — the guarantee
should come from provisioning, not from apt's dependency resolution.

---

## V3. Artifact equivalence against Blacksmith

The claim under test is "this runner produces the same artifact", not "this
runner produced an artifact". Precedent:
`docs/plans/done/2026-08-12-verify-baked-composefs-digest.md` established that
podman 4.9.3 and 5.8.2 yield byte-identical sealed images once the digest is
checked directly.

For the same `main` commit, compare the VPS run against the most recent
Blacksmith run (35699550325, 2026-09-22, or a fresh one):

- BST cache key: `bst show --deps none --format '%{full-key}' oci/krytis/image.bst` — must be identical.
- Composefs digest from `verify-composefs-digest` — must be identical.
- Published manifest digest of `:<version>` — identical, or the delta explained (a
  layer-timestamp difference is explainable; a content difference is not).

**Acceptance:** identical cache key and composefs digest. Anything else stops
option B here.

---

## V4. Post-run hygiene audit on the box (Security Gate evidence)

Immediately after V2, before the next job can run:

```shell
ssh "${RUNNER_VPS_HOST}" '
  find /opt/actions-runner/_work -name "*.key" -o -name "db.crt" -o -name "PK.key" 2>/dev/null
  ls -la /run/containers/0/auth.json /root/.config/containers/auth.json 2>/dev/null
  grep -rl "BEGIN.*PRIVATE KEY" /root/.local/share/containers/storage/overlay 2>/dev/null | head
  df -h -x fuse; du -sh /root/.cache/buildstream/cas/tmp'
```

**Acceptance:** no key files anywhere under `_work`; no key material in podman
storage layers; `cas/tmp` not growing orphans. A lingering ghcr `auth.json` is
expected (nothing logs out today) — if V0 finds other root-owned workloads on
the box, add `podman logout ghcr.io` / `oras logout` to the cleanup step and
re-run this check.

Also assert the negative case: cancel a sealed dispatch mid-`seal-uki` and
confirm the `if: always()` wipe still ran — GitHub gives a cancelled job ~5
minutes for `always()` steps, but a runner **OOM kill** skips them entirely, and
that has happened twice here. If the wipe cannot be guaranteed, the next
checkout's `git clean -ffdx` is the only backstop and it does not shred.

---

## V5. Boot gate — human, cannot be run by an agent

`mise run boot-test` shells out to `generate-disk`, which needs real root
(`docs/skills/workflow.md` § The One Verification Gate an Agent Cannot Run).
Against the **VPS-built** artifacts, not a previous image:

```shell
podman pull ghcr.io/starlit-os/krytis:latest
mise run generate-disk --image ghcr.io/starlit-os/krytis:latest \
    --disk /var/tmp/krytis-vps-test.raw --size 15G
mise run boot-test --reuse-disk /var/tmp/krytis-vps-test.raw
mise run generate-ovmf-vars && mise run boot-test --secure   # sealed
```

`verify-sealed.yml` fires automatically on `workflow_run` completion of a
successful publish (`.github/workflows/verify-sealed.yml:21–25`) and runs
`mise run enroll-test` against the published `:sealed` on `ubuntu-26.04` — that
is free evidence for the enrollment path. **Acceptance:** both boot-tests PASS
and the `verify-sealed` run that follows V2 is green.

---

## V6. Scheduling interaction (only relevant if a `schedule:` is then added)

A self-hosted runner executes **one job at a time**. `krytis-vps` already hosts
`cache-warm` (06:41 UTC weekdays, multi-hour on a cold day), `runner-vps-gc`
(04:27 UTC Sunday), and dispatched `build-iso` runs. A publish scheduled at
08:30 does not start at 08:30 — it queues behind whatever is running, and then
blocks everything after it for its own 1–7 hours.

Before adding any cron: measure the V1/V2 wall-clock on this box, compare
against `cache-warm`'s observed tail, and state the resulting `:latest`
publication window. If the answer is "unpredictable, up to N hours late", that
is an argument for option A, not a detail.

---

## V7. The gate that does not exist

`publish.yml` has **no automated boot test**. Today that is survivable because a
human dispatches it and runs V5 by hand around the dispatch. Making publish
unattended removes that human without replacing them: `:latest` would be
promoted publicly on vuln-scan + signature verification alone.

`verify-sealed.yml` is the closest thing and it only covers key enrollment on
the *sealed* tag, after the fact. Nothing gates `:latest`.

This is independent of the runner choice and is the actual blocker for a
schedule. Either an automated boot gate lands first (a QEMU boot on a hosted
runner, as `verify-sealed.yml` already does for enrollment), or the human
accepts publishing unattended without one. **Human decision, Design Gate.**

---

## Summary of verdicts required

| # | Item | Who decides |
|---|---|---|
| P1–P5 | Prerequisite code changes | agent implements |
| V0 | **ANSWERED** — box is root-monolithic with two root-equivalent third-party workloads; recommendation is to keep sealed publishes on Blacksmith | human accepts or overrules (Security Gate) |
| V1–V2 | Dispatches succeed, cosign sign step verified in its own log | agent verifies |
| V3 | Artifact equivalence vs Blacksmith | agent verifies; a mismatch stops option B |
| V4 | No key/credential residue | agent verifies; human signs off |
| V5 | Boot + secure boot PASS on VPS-built images | human runs |
| V6 | Queue behaviour and publication window acceptable | human |
| V7 | Unattended publish with no boot gate | human (Design Gate) |
