# Sealed ISO Payload Implementation Plan (#371)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `mise run build-iso --sealed` produces a live ISO whose offline install payload is `localhost/krytis:sealed` (the signed UKI image from #32/#33), such that installing from it yields a system that boots under Secure Boot with the keys #309 enrolls — and that still boots with Secure Boot disabled. The live ISO itself stays unsigned (Design Gate decision, issue comment 2026-07-29).

**Architecture:** Three moving parts, two repos.

1. **krytis** — `mise/tasks/build-iso` gains `--sealed`: it selects `localhost/krytis:sealed` (auto-running `mise run seal-uki` on the same `.Created` staleness rule `mise run push --sealed` uses), tags it as `ghcr.io/starlit-os/krytis:sealed` rather than `:latest`, hands dakota-iso two new environment knobs, renames the output ISO, and asserts after the build that the ISO really embedded the byte-identical sealed image.
2. **dakota-iso** (`kitten-lily/dakota-iso`, sibling checkout) — two new env inputs on the ISO pipeline: `PAYLOAD_REF` (override `<target>/payload_ref`, and the imgref baked into the live installer's `recipe.json`) and `PAYLOAD_SEALED` (pass the payload through **byte-identically**, skipping every rootfs mutation the current pipeline performs). Plus a Secure Boot variant of the existing QEMU install gate.
3. **Verification** — the sealed payload's correctness is not asserted by a bespoke digest recomputation. `bootc install` itself recomputes the composefs digest over the image it installs and fails loudly (`The UKI has the wrong composefs= parameter (is 'sha512:X', should be sha512:Y')`) on mismatch, so a successful install *is* the digest proof. A cheap artifact-level gate (image-ID equality between the ISO's embedded store and `localhost/krytis:sealed`) catches regressions without a 40-minute QEMU run.

**Tech Stack:** podman/buildah/skopeo, `bootc install` (v1.16.6) via projectbluefin/fisherman, dakota-iso's `just` pipeline, QEMU + OVMF (secboot variant), `virt-fw-vars` (already wrapped by `mise run generate-ovmf-vars`), `xorriso -osirrox` + `unsquashfs` for the artifact gate.

---

## Findings that change the issue's scope

Read these before starting. Each was verified against the sibling checkout at `ab94dcf`, not inferred.

### F1. The issue names the wrong script — the bug lives in `live/iso-tools/payload-prep.sh`

The issue attributes the `00-defaults.toml` injection to `scripts/build-live-squashfs.sh`. That script is **not on krytis's code path**. `mise run build-iso` → `just iso-sd-boot krytis` → `scripts/iso-sd-boot.sh`, which:

- exports the payload with `podman save --format oci-archive` (line 102), then `podman rmi`s the ref (line 103),
- runs the injection in **`live/iso-tools/payload-prep.sh`** (invoked directly on the host, or inside `ISO_TOOLS_IMAGE` — krytis always uses the container, since the host has no buildah),
- assembles the squashfs with its own inline `_ns_build_squashfs`, a third copy of the store-embedding logic.

`scripts/build-live-squashfs.sh` carries a duplicate of the same injection for a different (CI/multi-arch) entry point. Fix `payload-prep.sh` because that is what krytis executes; fix `build-live-squashfs.sh` in the same PR because leaving a known digest-corrupting path in the sibling script is a trap for the next agent, and the guard is four lines.

### F2. The composefs path injects **two** files, not one — and re-commits twice

`payload-prep.sh` lines 28–50, composefs branch, mutates the payload rootfs:

| Mutation | Effect on a sealed payload |
|---|---|
| `buildah run … mkdir -p /usr/lib/bootc/install && cp … 00-defaults.toml` | new file — krytis ships no such file (`grep` of `elements/` + `files/`: zero hits) |
| `buildah run … mkdir -p /etc/containers` + `buildah copy … /etc/containers/storage.conf` (`driver = "vfs"`) | new file — krytis ships no `/etc/containers/storage.conf` either (verified by grep) |
| `buildah commit --squash` (twice: once for the payload, once for the `ostree.final-diffid` relabel) | each `buildah run`/`commit` round trip can perturb `/tmp` and `/var/tmp` mtimes — the exact, and *entire*, discrepancy that already broke the digest once (`docs/skills/secure-boot.md` § `bootc container ukify` must run in a throwaway stage) |

So skipping only `00-defaults.toml` is insufficient. The sealed payload must bypass `payload-prep.sh` **entirely**: any `buildah from … commit` round trip is a digest hazard, and none of the three mutations is needed for a sealed install:

- `root-mount-spec = "LABEL=root"` sets the `root=` karg bootc would write. A UKI's cmdline is frozen at seal time and bootc's composefs docs state it "can omit the `root=` kernel argument entirely" for UKI+composefs installs — the file is inert for this payload.
- `/etc/containers/storage.conf` (vfs) is a live-environment concern that leaks onto the installed system; it is not required for `bootc install` to read the offline store (the *live* env's own storage config drives that). Aside, out of scope, worth reporting upstream in the dakota-iso PR description: this file lands on every dakota install today and pins the installed system's podman to the vfs driver.
- `ostree.final-diffid` is a *config label*, not rootfs content, so it cannot change the digest — but its implementation (`buildah from` + `commit --squash`) can. `localhost/krytis:sealed` carries no such label today (`podman inspect … '{{index .Labels "ostree.final-diffid"}}'` → empty) and neither does `:latest`, whose installs work; the relabel is a no-op-with-risk for krytis and is dropped on the sealed path.

Squashing for VFS compactness is also unnecessary: `mise run seal-uki` already builds `:sealed` with `--squash-all`, so it is single-layer by construction (`podman inspect … '{{json .RootFS.Layers}}'` → exactly one diff_id).

### F3. `targetImgref` must change too, or the first `bootc upgrade` breaks the boot chain

`live/src/configure-live-krytis.sh` line 179 hardcodes `KRYTIS_IMGREF="ghcr.io/starlit-os/krytis:latest"` and writes it into **four** recipe.json fields at live-container build time: `imgref`, `targetImgref`, `image` (`containers-storage:…`), `local_imgref`. `krytis/payload_ref` holds the same ref and is what `iso-sd-boot.sh` embeds under.

Consequences if only the *content* behind `:latest` is swapped for the sealed image:

- the install succeeds (store key matches `local_imgref`), but
- `targetImgref` is `…/krytis:latest` → the installed sealed system's first `bootc upgrade` pulls the **unsigned** image, replacing the signed UKI and signed systemd-boot with artifacts the enrolled firmware refuses. The machine stops booting under enforcement.

And if only `payload_ref` changes, `local_imgref` no longer resolves in the store and the install fails immediately. Both refs must move together — hence `PAYLOAD_REF` has to reach *both* `iso-sd-boot.sh` and the live-container build (`just container` → `--build-arg` → `configure-live-krytis.sh`).

### F4. Blockers are clear; no fisherman change is needed

#309 is **closed/completed** and #32 is **closed** — both stated blockers are cleared. The issue's own research (comment 2026-07-29) established that `--boot=uki` does not exist and that `composeFsBackend: true` + `bootloader: "systemd"` — already set by `configure-live-krytis.sh` lines 220–221 — are the only flags bootc needs. Confirmed still true in the current sibling checkout. No fisherman or recipe-schema work in this plan.

### F5. The live ISO and the installed system need *different* firmware var files

The Design Gate decision keeps the live ISO unsigned. So the E2E test must boot the **live ISO with plain OVMF vars** (no enforcement — an unsigned live environment cannot boot under a firmware that trusts only krytis's keys) and the **installed disk with `.ovmf-vars-secure.fd`** (enforcement, krytis PK/KEK/db enrolled). A single-varstore test design cannot express this and will produce a false negative on the live-boot phase.

---

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only (AGENTS.md). This plan adds no BST element, so the **Update path gate does not apply**.
- All maintenance tasks must be `mise` tasks — no loose shell commands (AGENTS.md). Every new krytis capability here is a `mise` task or a flag on one; the dakota-iso side stays `just`, invoked from a mise task exactly as `build-iso` already does.
- Do not rename existing tasks without explicit human approval — `build-iso`, `boot-test`, `generate-ovmf-vars` keep their names and their current default behaviour.
- `mise lint` must pass; the image must be shown to boot. No WIP PRs (AGENTS.md).
- Agents MUST NOT push to `main`. Worktree + branch: #371's `parent:` is **#16**, so per AGENTS.md's "Issue with parent issue" row the worktree is `.worktrees/gh16/371-add-sealed-payload-to-iso` (base `.worktrees/` exists) and the branch is `371-add-sealed-payload-to-iso` — flat, no parent encoding. **Already created** by the session that wrote this plan.
- Skill entries land in the **same commit** as the change that produced the learning (AGENTS.md Self-Improvement Loop). Each task below names its skill file; do not batch them into a docs commit at the end. The one exception is Task 8's `--boot=uki` correction, which fixes a pre-existing error rather than recording a new learning.
- Cross-repo work invokes AGENTS.md's **Cross-repo exception**: the dakota-iso PR (`kitten-lily/dakota-iso`) and the krytis PR are opened in the same session, the dakota-iso skill entry lands in the dakota-iso PR, and each side's commit message references the other (krytis commit → dakota-iso PR URL; dakota-iso commit → krytis commit SHA or PR URL).
- `docs/plans/done/` is frozen; `mise run docs-links` must pass before opening any PR that touches docs.
- Sealed images are tagged `:sealed`, never `:latest` (`docs/skills/secure-boot.md` § Sealed images push under `:sealed` tags) — the same discipline now applies to the ISO's payload ref and to the ISO filename.
- `files/boot-keys/` is gitignored. Never commit key material; `--secret` mounts only.

## Prerequisites (before starting any task)

- [ ] Read `AGENTS.md`, `docs/SKILL.md`, `docs/skills/secure-boot.md`, `docs/skills/bootc-vm.md`, `docs/skills/mise.md`, `docs/design/secure-boot-uki.md`
- [ ] Read the sibling checkout's `docs/skills/krytis-live-config.md` and `docs/skills/e2e-ci.md` (dakota-iso)
- [ ] `cd .worktrees/gh16/371-add-sealed-payload-to-iso && mise trust`
- [ ] Sibling checkout present and on a clean `main`: `git -C ../../../../dakota-iso status --short` (empty), `git -C … branch --show-current` → `main`. Path resolution: `mise/tasks/build-iso` resolves `DAKOTA_ISO_DIR` from the **main** worktree via `git rev-parse --git-common-dir`, so it finds `/var/home/lily/Projects/StarlitOS/dakota-iso` even from inside `.worktrees/` — do not hand-set `DAKOTA_ISO_DIR` unless testing an alternate checkout.
- [ ] `mise run pull-keys` — `files/boot-keys/{PK,KEK,db}.{key,crt}` present
- [ ] `mise run generate-ovmf-vars` — `.ovmf-vars-secure.fd` present (needed by Task 6/7)
- [ ] `localhost/krytis:latest` and `localhost/krytis:sealed` both exist and `:sealed` is newer (`podman inspect --format '{{.Created}}'` on each); rebuild with `mise build` / `mise run seal-uki` otherwise
- [ ] Record the baseline invariants for later comparison:
      `podman inspect localhost/krytis:sealed --format '{{.Id}}'` and
      `podman create` + `podman cp /boot/EFI/Linux/krytis.efi` + `objcopy -O binary --only-section=.cmdline … | tr -d '\0'`
      → the cmdline must contain `composefs=<128 hex chars>`. Observed on 2026-08-01: single-layer diff_id `sha256:e2ae30e0…`, `composefs=536edc7a…8ccff`.
- [ ] ~60 GB free on the `output`/`WORKDIR` filesystem and on `/var/tmp` (ISO ~5 GB, payload archives ~7 GB each, install disks 15 GB × 2)

---

# Phase A — dakota-iso mechanism (must land first)

Krytis's `--sealed` flag cannot work until the sibling pipeline honours the two new env knobs. Do Phase A first, in the sibling checkout, on its own branch and PR.

## Task 1: `PAYLOAD_REF` override — payload ref and baked imgref move together

**Repo:** `kitten-lily/dakota-iso`
**Branch/worktree:** `feat/sealed-payload-support` (dakota-iso has no issue for this; descriptive Conventional-Commits-style name per AGENTS.md's "No issue" row)

**Files:**
- Modify: `justfile` (`container`, `iso-sd-boot` recipes)
- Modify: `live/Containerfile` (final stage `ARG`/`ENV`)
- Modify: `live/src/configure-live-krytis.sh`
- Modify: `scripts/iso-sd-boot.sh`

**Interfaces:**
- Consumes: `PAYLOAD_REF` (env, optional). Empty/unset → today's behaviour, byte for byte.
- Produces: the ref used for `podman save`, for the store key, and for recipe.json's `imgref`/`targetImgref`/`image`/`local_imgref`.

- [ ] **Step 1: `iso-sd-boot.sh` — env override with file fallback**

Replace line 28 so the file remains the default and the env wins:

```bash
PAYLOAD_IMAGE="${PAYLOAD_REF:-$(cat "${TARGET}/payload_ref" | tr -d '[:space:]')}"
```

Document `PAYLOAD_REF` (and `PAYLOAD_SEALED`, Task 2) in the script's header comment block alongside `TARGET`/`OUTPUT_DIR`/`DEBUG`/`COMPRESSION`.

- [ ] **Step 2: forward `PAYLOAD_REF` into the live-container build**

`iso-sd-boot.sh` line 50 calls `just … container "${TARGET}"`. The recipe must pass the ref through as a build arg:

```make
container target:
    #!/usr/bin/bash
    …
    podman build --cap-add sys_admin --security-opt label=disable \
        --layers \
        …
        --build-arg PAYLOAD_REF="${PAYLOAD_REF:-}" \
        -t {{target}}-installer -f ./live/Containerfile ./live
```

`just` recipes inherit the caller's environment, so `PAYLOAD_REF` reaches the recipe body without a new `just` variable. Keep it an env var, not a `just` parameter — `iso-sd-boot.sh` already invokes `just container` positionally and adding a parameter would change that call signature for every target.

- [ ] **Step 3: `live/Containerfile` — declare the ARG in the final stage**

Next to the existing `ARG INSTALLER_CHANNEL=stable` / `ARG DEBUG=0` (lines ~102–104) in the **final** stage:

```dockerfile
ARG PAYLOAD_REF=
ENV PAYLOAD_REF=${PAYLOAD_REF}
```

The `ENV` is required: `configure-live-krytis.sh` runs as a `RUN` step and reads the value from the environment, matching how `TARGET`/`INSTALLER_CHANNEL`/`DEBUG` are already plumbed.

- [ ] **Step 4: `configure-live-krytis.sh` — honour it**

Line 179 becomes:

```bash
# PAYLOAD_REF (build-arg) overrides the default when the ISO embeds a non-default
# payload — e.g. krytis's `mise run build-iso --sealed`, which embeds
# ghcr.io/starlit-os/krytis:sealed. Must match the ref iso-sd-boot.sh imports into
# the offline store, or recipe.json's local_imgref will not resolve at install time.
# targetImgref matters just as much as imgref: it is what `bootc upgrade` follows
# after install, so a sealed install pointing at :latest would replace its own
# signed boot chain on the first upgrade.
KRYTIS_IMGREF="${PAYLOAD_REF:-ghcr.io/starlit-os/krytis:latest}"
```

No other change — all four recipe.json fields already interpolate `${KRYTIS_IMGREF}`.

- [ ] **Step 5: verify the default path is untouched**

```bash
cd ../dakota-iso
git stash list   # ensure nothing else in flight
just container krytis           # no PAYLOAD_REF set
podman run --rm --entrypoint="" localhost/krytis-installer:latest \
    python3 -c 'import json;r=json.load(open("/etc/bootc-installer/recipe.json"));print(r["imgref"],r["targetImgref"],r["local_imgref"])'
```

Expect all three to read `ghcr.io/starlit-os/krytis:latest` / `containers-storage:ghcr.io/starlit-os/krytis:latest` — identical to pre-change. Then repeat with `PAYLOAD_REF=ghcr.io/starlit-os/krytis:sealed just container krytis` and expect `:sealed` in all three.

**Acceptance:** unset `PAYLOAD_REF` reproduces today's recipe.json exactly; set `PAYLOAD_REF` changes all four fields and the store key together.

---

## Task 2: `PAYLOAD_SEALED` — byte-identical payload pass-through

**Repo:** `kitten-lily/dakota-iso` (same branch/PR as Task 1)

**Files:**
- Modify: `scripts/iso-sd-boot.sh`
- Modify: `live/iso-tools/payload-prep.sh`
- Modify: `scripts/build-live-squashfs.sh`
- Modify: `docs/skills/krytis-live-config.md` (same commit — dakota-iso's own skill mandate)

**Interfaces:**
- Consumes: `PAYLOAD_SEALED` (env, `1` to enable; default `0` = today's behaviour)
- Guarantees: with `PAYLOAD_SEALED=1`, the OCI image imported into the offline store has the **same config digest (image ID) and the same layer diff_id** as the image `podman save` exported. No `buildah` container is created, no file is injected, no layer is re-committed.

- [ ] **Step 1: `payload-prep.sh` — early pass-through**

After the existing `: "${…:?}"` guards, before the `printf`/`buildah from` sequence:

```bash
# A sealed payload carries a UKI whose .cmdline has a composefs= digest baked in
# at seal time. `bootc install` recomputes that digest over the image it installs
# and refuses a mismatch ("The UKI has the wrong composefs= parameter"). EVERY
# mutation below would invalidate it: the two injected files (00-defaults.toml,
# /etc/containers/storage.conf), and the `buildah run`/`commit --squash` round
# trips themselves, which perturb /tmp and /var/tmp mtimes — the exact, and only,
# discrepancy that broke this digest before (krytis
# docs/skills/secure-boot.md § `bootc container ukify` must run in a throwaway stage).
#
# None of the three is needed for a sealed install:
#   • root-mount-spec sets the root= karg; a UKI's cmdline is frozen and bootc
#     omits root= entirely for UKI+composefs installs.
#   • /etc/containers/storage.conf configures the LIVE env's storage, not the
#     payload's; injecting it into the payload only leaks vfs onto the installed
#     system.
#   • ostree.final-diffid is a config label (digest-neutral), but the buildah
#     round trip that applies it is not.
# Squashing is likewise unnecessary: a sealed image is already single-layer
# (krytis builds it with --squash-all).
if [[ "${PAYLOAD_SEALED:-0}" == "1" ]]; then
    echo "=== PAYLOAD_SEALED=1 — passing ${PAYLOAD_IMAGE} through unmodified (preserving UKI composefs digest) ==="
    cp --reflink=auto "${PAYLOAD_INPUT}" "${PAYLOAD_OCI}"
    exit 0
fi
```

- [ ] **Step 2: `iso-sd-boot.sh` — skip the copy entirely, and forward the flag**

The `cp` above is ~7 GB. On krytis's path both archives live in `OUTPUT_DIR`, so the copy is avoidable: when sealed, alias the output at the input and skip the payload-prep invocation. Around lines 99–123:

```bash
PAYLOAD_SEALED="${PAYLOAD_SEALED:-0}"
…
if [[ "${PAYLOAD_SEALED}" == "1" ]]; then
    # Byte-identical embed — see live/iso-tools/payload-prep.sh for why a sealed
    # payload must not be re-committed. Aliasing avoids a ~7GB copy of the archive.
    echo "=== PAYLOAD_SEALED=1 — skipping payload prep, embedding ${PAYLOAD_IMAGE} as exported ==="
    PAYLOAD_OCI="${PAYLOAD_INPUT}"
else
    export PAYLOAD_IMAGE PAYLOAD_INPUT PAYLOAD_OCI OUTPUT_DIR COMPOSEFS_BACKEND
    … existing host / ISO_TOOLS_IMAGE branch, plus `-e PAYLOAD_SEALED` on the podman run …
fi
```

Two follow-through edits this creates — both are real bugs if missed:

- the unconditional `rm -f "${PAYLOAD_INPUT}"` (line 123) must become `[[ "${PAYLOAD_SEALED}" == "1" ]] || rm -f "${PAYLOAD_INPUT}"`, or the archive is deleted before `_ns_build_squashfs` imports it;
- the `trap` on line 100 already lists both paths, so cleanup still happens on exit — verify it does not double-`rm` (harmless with `-f`, but confirm the trap fires after the store import, not before).

Add `PAYLOAD_SEALED` to the header comment block. Keep `-e PAYLOAD_SEALED` on the `ISO_TOOLS_IMAGE` `podman run` even though the sealed path skips it — a direct caller of `payload-prep.sh` inside the container must still be able to set it.

- [ ] **Step 3: `scripts/build-live-squashfs.sh` — same guard on both branches**

That script is not on krytis's path (see F1) but duplicates the injection in both its composefs (lines 158–166) and non-composefs (lines 208–210) branches. Wrap each mutation block in the same `PAYLOAD_SEALED`/`SEALED` check so the next agent who wires a sealed payload through the multi-arch/CI entry point does not rediscover this. Do not restructure the script beyond the guard.

- [ ] **Step 4: skill entry (same commit)**

Append to `docs/skills/krytis-live-config.md`:

```markdown
### Sealed (UKI) payloads must be embedded byte-identically (2026-08-01)

**What:** krytis's `mise run build-iso --sealed` embeds `ghcr.io/starlit-os/krytis:sealed`,
whose UKI has a `composefs=<sha512>` digest baked into its frozen kernel cmdline at seal
time. `bootc install` recomputes that digest over the image it installs and aborts with
"The UKI has the wrong composefs= parameter" on any mismatch.

**Why it bites here:** the payload pipeline mutates every payload it embeds —
`00-defaults.toml`, `/etc/containers/storage.conf`, and two `buildah commit --squash`
round trips whose only observable effect can be a `/tmp` + `/var/tmp` mtime bump. All
three invalidate the digest. Harmless for unsealed payloads (no digest to invalidate),
which is why it went unnoticed until krytis became the first sealed payload.

**Fix:** `PAYLOAD_SEALED=1` makes `iso-sd-boot.sh` skip payload prep entirely and
`payload-prep.sh` pass the archive through, so the store receives the exported image
byte for byte. `PAYLOAD_REF` moves the store key and recipe.json's
imgref/targetImgref/image/local_imgref together — moving only one breaks either the
install (local_imgref unresolvable) or the first `bootc upgrade` (targetImgref points at
the unsigned image, which the enrolled firmware then refuses).

**Aside, unrelated to sealing:** the `/etc/containers/storage.conf` injection lands on
every *installed* dakota system too, pinning its podman to the vfs driver. Probably not
intended; not changed here because unsealed behaviour is deliberately left byte-identical.
```

**Acceptance:** `PAYLOAD_SEALED=1` run produces a `${TARGET}-payload.oci.tar` whose `skopeo inspect --config` `rootfs.diff_ids[0]` equals `podman inspect localhost/krytis:sealed --format '{{index .RootFS.Layers 0}}'`; unset/`0` reproduces today's output.

---

# Phase B — krytis `build-iso --sealed`

## Task 3: `--sealed` flag on `mise run build-iso`

**Files:**
- Modify: `mise/tasks/build-iso`
- Create: `scripts/ensure-sealed-image.sh`
- Modify: `mise/tasks/push` (call the extracted helper)
- Modify: `docs/skills/secure-boot.md` (same commit)

**Interfaces:**
- Produces: `output/krytis-live-sealed.iso` (sealed) / `output/krytis-live.iso` (default, unchanged)
- Consumes: `localhost/krytis:sealed`, `localhost/krytis:latest` (freshness reference)
- Calls: `scripts/ensure-sealed-image.sh`, `mise/tasks/seal-uki`, `just iso-sd-boot krytis` with `PAYLOAD_REF` + `PAYLOAD_SEALED`

**Issue:** Part of #371

- [ ] **Step 1: extract the staleness rule into `scripts/ensure-sealed-image.sh`**

`mise/tasks/push` lines 30–45 implement it inline. A second copy in `build-iso` would be the third place the `.Created` comparison rule lives (the skill file being the second). Extract verbatim — no behaviour change:

```bash
#!/usr/bin/env bash
# ensure-sealed-image.sh — guarantee localhost/krytis:sealed exists and is no
# older than localhost/krytis:latest, re-running `mise run seal-uki` if not.
#
# --squash-all erases parent/layer provenance, so `.Created` is the only usable
# content-identity proxy: podman build is content-addressed, so rebuilding
# :latest from byte-identical inputs reuses the image ID *and* its original
# Created timestamp. Only a genuine content change produces a fresh one. See
# docs/skills/secure-boot.md § `--squash-all` erases parent/layer provenance.
#
# Scope note: tracks :latest's content only, not signing-key freshness —
# rotating files/boot-keys/ without another content change will not re-seal.
set -euo pipefail

SEALED_TAG="localhost/krytis:sealed"
LATEST_TAG="localhost/krytis:latest"

if ! podman image exists "${LATEST_TAG}"; then
    echo "==> ERROR: ${LATEST_TAG} not found locally — run mise build first (needed as the freshness reference for the sealed image)" >&2
    exit 1
fi

LATEST_CREATED=$(date -d "$(podman inspect "${LATEST_TAG}" --format '{{.Created}}')" +%s)
if podman image exists "${SEALED_TAG}"; then
    SEALED_CREATED=$(date -d "$(podman inspect "${SEALED_TAG}" --format '{{.Created}}')" +%s)
else
    SEALED_CREATED=0
fi

if [[ "${SEALED_CREATED}" -lt "${LATEST_CREATED}" ]]; then
    echo "==> ${SEALED_TAG} is missing or older than ${LATEST_TAG} — running mise run seal-uki..."
    ./mise/tasks/seal-uki
fi

if ! podman image exists "${SEALED_TAG}"; then
    echo "==> ERROR: ${SEALED_TAG} still missing after seal-uki" >&2
    exit 1
fi
```

`chmod +x`. Then replace `push`'s inline block (lines 30–45) with `./scripts/ensure-sealed-image.sh`, keeping `SOURCE_TAG`/`DEST_*_TAG` assignments where they are. `push`'s later `podman image exists "$SOURCE_TAG"` guard (line 52) stays — it also covers the non-sealed branch.

- [ ] **Step 2: add the flag and the payload selection to `build-iso`**

New annotation, after `--compression`:

```bash
#USAGE flag "--sealed" help="Embed the signed UKI image (localhost/krytis:sealed) as the offline install payload instead of the unsigned one"
```

Replace the payload-tagging block (current lines 29–43):

```bash
# `mise build` only tags the freshly built image as localhost/krytis:latest, and
# `mise run seal-uki` only tags localhost/krytis:sealed. iso-sd-boot.sh does
# `podman save` on the payload ref it is given, so re-tag on every run: without a
# matching local tag it either fails outright or silently embeds a stale image
# pulled/pushed earlier.
#
# --sealed diverges in three ways, all of which matter:
#   1. the payload image is :sealed, not :latest;
#   2. the payload REF is …/krytis:sealed, so recipe.json's targetImgref makes the
#      installed system follow the sealed stream — pointing it at :latest would make
#      the first `bootc upgrade` replace the signed boot chain with unsigned
#      artifacts the enrolled firmware then refuses (#371);
#   3. PAYLOAD_SEALED=1 tells dakota-iso to embed the payload byte-identically,
#      because the UKI's baked composefs= digest cannot survive the pipeline's
#      normal inject-and-recommit pass. See docs/skills/secure-boot.md
#      § A sealed ISO payload must be embedded byte-identically.
SEALED=$([[ "${usage_sealed:-}" == "true" ]] && echo 1 || echo 0)

if [[ "${SEALED}" -eq 1 ]]; then
    ./scripts/ensure-sealed-image.sh
    LOCAL_IMAGE="localhost/krytis:sealed"
    PAYLOAD_REF="ghcr.io/starlit-os/krytis:sealed"
    ISO_NAME="krytis-live-sealed.iso"
else
    LOCAL_IMAGE="localhost/krytis:latest"
    PAYLOAD_REF="$(tr -d '[:space:]' < "${DAKOTA_ISO_DIR}/krytis/payload_ref")"
    ISO_NAME="krytis-live.iso"
fi

if ! podman image exists "${LOCAL_IMAGE}"; then
    echo "ERROR: ${LOCAL_IMAGE} not found — run '$([[ "${SEALED}" -eq 1 ]] && echo 'mise run seal-uki' || echo 'mise build')' first." >&2
    exit 1
fi

echo "==> Tagging ${LOCAL_IMAGE} → ${PAYLOAD_REF} for offline embed..."
podman tag "${LOCAL_IMAGE}" "${PAYLOAD_REF}"
```

Note the non-sealed branch still reads `krytis/payload_ref` from the sibling checkout, so the default path keeps its single source of truth.

- [ ] **Step 3: preflight the sibling checkout's support**

`iso-sd-boot.sh` ignores unknown env vars, so an out-of-date sibling would silently build a **broken sealed ISO** — the worst possible failure mode, discovered only 40 minutes later in QEMU. Add, next to the existing `justfile` existence check:

```bash
if [[ "${SEALED}" -eq 1 ]]; then
    if ! grep -q 'PAYLOAD_SEALED' "${DAKOTA_ISO_DIR}/scripts/iso-sd-boot.sh" \
       || ! grep -q 'PAYLOAD_REF' "${DAKOTA_ISO_DIR}/live/src/configure-live-krytis.sh"; then
        echo "ERROR: ${DAKOTA_ISO_DIR} predates sealed-payload support (#371)." >&2
        echo "       --sealed needs PAYLOAD_SEALED in scripts/iso-sd-boot.sh and PAYLOAD_REF in" >&2
        echo "       live/src/configure-live-krytis.sh. Update the sibling checkout:" >&2
        echo "         git -C ${DAKOTA_ISO_DIR} pull" >&2
        echo "       Without them the ISO would embed a mutated payload whose UKI composefs" >&2
        echo "       digest no longer matches, and the install would fail late." >&2
        exit 1
    fi
fi
```

- [ ] **Step 4: pass the knobs through and name the output**

Extend the `just` invocation's env block with `PAYLOAD_REF="${PAYLOAD_REF}"` and `PAYLOAD_SEALED="${SEALED}"`, add `sealed:      ${SEALED}` / `payload:     ${PAYLOAD_REF}` to the echoed summary, and rename the artifact afterwards (dakota-iso always writes `${TARGET}-live.iso`; two variants must not clobber each other):

```bash
if [[ "${SEALED}" -eq 1 ]]; then
    mv "${OUTPUT_DIR}/krytis-live.iso" "${OUTPUT_DIR}/${ISO_NAME}"
fi
echo "==> ISO ready: ${OUTPUT_DIR}/${ISO_NAME}"
```

- [ ] **Step 5: skill entry (same commit)**

Append to `docs/skills/secure-boot.md`:

```markdown
## A sealed ISO payload must be embedded byte-identically, and its ref must move too

`mise run build-iso --sealed` embeds `localhost/krytis:sealed` as the offline install
payload. Two non-obvious requirements, both of which produce late, confusing failures:

**1. Byte identity.** dakota-iso's payload pipeline
(`live/iso-tools/payload-prep.sh`, and a duplicate in `scripts/build-live-squashfs.sh`
— note `iso-sd-boot.sh` uses the former; the latter is a different entry point) injects
`/usr/lib/bootc/install/00-defaults.toml` and `/etc/containers/storage.conf` into every
payload and re-commits it twice with `buildah commit --squash`. Krytis ships neither
file, and each `buildah run`/`commit` round trip can bump `/tmp` and `/var/tmp` mtimes —
the same, and only, discrepancy that broke the UKI digest before (§ `bootc container
ukify` must run in a throwaway stage). Any of the three invalidates the `composefs=`
digest baked into the UKI's frozen cmdline, and `bootc install` then aborts with
"The UKI has the wrong composefs= parameter (is 'sha512:X', should be sha512:Y')".
`PAYLOAD_SEALED=1` makes the pipeline pass the payload through untouched. Skipping only
the `00-defaults.toml` injection is NOT enough.

**2. `targetImgref`, not just the store key.** `configure-live-krytis.sh` bakes one ref
into four recipe.json fields: `imgref`, `targetImgref`, `image`, `local_imgref`. Change
only the embedded content and the install succeeds while `targetImgref` still points at
`…/krytis:latest` — so the first `bootc upgrade` on the freshly sealed system pulls the
*unsigned* image, overwrites the signed UKI and signed systemd-boot, and the enrolled
firmware refuses to boot it. Change only `payload_ref` and `local_imgref` no longer
resolves in the offline store, failing the install immediately. `PAYLOAD_REF` moves both
together; `build-iso --sealed` sets it to `ghcr.io/starlit-os/krytis:sealed`.

Because `iso-sd-boot.sh` ignores env vars it does not know, an out-of-date sibling
checkout would silently produce a broken sealed ISO. `build-iso --sealed` therefore
greps the sibling for both knobs and refuses up front — the same "fail before the
expensive step, not during it" discipline as `boot-test`'s UKI presence check.
```

**Acceptance:** `mise run build-iso` (no flag) produces `output/krytis-live.iso` with `ghcr.io/starlit-os/krytis:latest` embedded, byte-for-byte the same pipeline as before. `mise run build-iso --sealed` produces `output/krytis-live-sealed.iso`, auto-seals when `:sealed` is stale, and refuses early against an unpatched sibling checkout.

---

## Task 4: `mise run verify-iso-payload` — artifact-level embed gate

**Files:**
- Create: `mise/tasks/verify-iso-payload`
- Modify: `mise/tasks/build-iso` (invoke it after a `--sealed` build)
- Modify: `docs/skills/secure-boot.md` (same commit)

**Interfaces:**
- Consumes: an ISO path + an expected local image tag
- Asserts: the image ID recorded in the ISO's embedded VFS store equals `podman inspect <tag> --format '{{.Id}}'`

**Rationale:** the pass-through in Task 2 makes byte identity true *by construction*, so asserting it inside dakota-iso would be tautological. This gate reads the **finished ISO** instead, which is the only place that proves the whole chain (`podman save` → archive → `skopeo copy` → VFS store → squashfs → ISO) preserved the image. It also catches the "wrong tag embedded" class of bug that has already bitten once (#417/#425). Unprivileged, no QEMU, a few minutes.

- [ ] **Step 1: write the task**

```bash
#!/usr/bin/env bash
#MISE description="Assert an ISO's embedded offline payload is the exact image expected (sealed-payload digest gate)"
#USAGE flag "--iso <path>" default="output/krytis-live-sealed.iso" help="ISO to inspect"
#USAGE flag "--image <tag>" default="localhost/krytis:sealed" help="Local image tag the payload must match"
```

Body outline (keep the comments — they explain why this exists):

1. `EXPECTED_ID=$(podman inspect "${IMAGE}" --format '{{.Id}}')`.
2. Extract the rootfs squashfs from the ISO without root:
   `xorriso -osirrox on -indev "${ISO}" -extract /LiveOS/squashfs.img "${WORK}/squashfs.img"`
   (route `xorriso` through `${ISO_TOOLS_IMAGE:-localhost/iso-tools:latest}` exactly as `iso-sd-boot.sh` does — the host has no xorriso).
3. Extract only the VFS store metadata:
   `unsquashfs -d "${WORK}/store" -e var/lib/containers/storage/vfs-images "${WORK}/squashfs.img"`
4. Read the store's image record and compare:
   `python3 -c` over `${WORK}/store/var/lib/containers/storage/vfs-images/images.json` → the entry whose `names` contains the payload ref; its `id` must equal `${EXPECTED_ID#sha256:}`.
5. On mismatch, print both IDs plus the store's `names`, and explain the two likely causes: the sibling checkout mutated the payload (`PAYLOAD_SEALED` not honoured), or the wrong tag was embedded.

If the `vfs-images` layout differs from the assumption, discover it before coding the comparison: `unsquashfs -l "${WORK}/squashfs.img" | grep var/lib/containers/storage | head -40`. Adapt the path, do not weaken the assertion into a name-only check.

- [ ] **Step 2: wire it into `build-iso --sealed`**

After the `mv`:

```bash
if [[ "${SEALED}" -eq 1 ]]; then
    ./mise/tasks/verify-iso-payload --iso "${OUTPUT_DIR}/${ISO_NAME}" --image "${LOCAL_IMAGE}"
fi
```

Note the flag-parsing hazard documented in `boot-test` (lines 12–34) and `docs/skills/mise.md` § Propagating flags through tasks that call other tasks: a task invoked as a plain script does **not** get its `#USAGE` flags parsed and inherits the *parent's* `usage_*` env. `verify-iso-payload` must therefore consume `--iso`/`--image` from `$@` first and fall back to `usage_*` — the same `CLI_*` pattern `boot-test` uses. Copy that pattern; do not rely on `usage_iso` being set.

- [ ] **Step 3: skill entry (same commit)** — append to `docs/skills/secure-boot.md` under the Task 3 section: the ISO artifact is the only honest place to assert the embed (an in-pipeline assertion is tautological once the pipeline is a pass-through), image ID equality is the exact invariant, and `xorriso`/`unsquashfs` make it unprivileged.

**Acceptance:** passes on a `--sealed` ISO; fails with a readable diagnostic when pointed at the default (unsealed) ISO, whose payload is legitimately re-committed and therefore has a different ID.

---

# Phase C — E2E test harness

## Task 5: dakota-iso — Secure Boot QEMU install gate

**Repo:** `kitten-lily/dakota-iso` (same branch/PR as Tasks 1–2)

**Files:**
- Modify: `justfile` (`plain-boot-qemu-installed`, `plain-verify-qemu`, new `sealed-test-qemu`)
- Modify: `scripts/plain-install-qemu.sh` (honour `PAYLOAD_REF`)
- Modify: `docs/skills/e2e-ci.md` (same commit)

**Design (see F5 — this is the part most easily got wrong):** the live ISO boots with **plain** OVMF (unsigned live environment, by krytis's Design Gate decision); the installed disk boots with the **enrolled secboot** varstore. Two phases, two firmware configurations, one recipe.

- [ ] **Step 1: `plain-install-qemu.sh` — payload ref override**

It builds the fisherman recipe from `<target>/payload_ref`. Make it `${PAYLOAD_REF:-$(cat …)}`, matching Task 1's idiom, so the sealed run installs `containers-storage:ghcr.io/starlit-os/krytis:sealed`.

- [ ] **Step 2: `plain-boot-qemu-installed` — env-overridable firmware**

The recipe hardcodes a search loop for plain OVMF (lines 1126–1141) and `-machine q35`. Let the caller override, defaulting to today's behaviour:

- if `OVMF_CODE_OVERRIDE`/`OVMF_VARS_OVERRIDE` are set, use them (copy the vars file to the scratch path as the loop does, so the enrolled varstore is never mutated in place);
- if `SECURE_BOOT=1`, use `-machine q35,smm=on` and add `-global driver=cfi.pflash01,property=secure,value=on`.

Both are required: without `smm=on` + the pflash `secure` property the varstore is writable and enforcement is not actually tested. This mirrors `mise/tasks/boot-test` lines 229–257, which is the known-good reference for this exact QEMU configuration — copy it rather than re-deriving.

- [ ] **Step 3: `plain-verify-qemu` — negative mode**

Add `EXPECT_FAIL=1`: instead of waiting for `Reached target …Graphical`, grep the serial log for `[Aa]ccess [Dd]enied|Security Violation` and pass only on a match. Report **INCONCLUSIVE** (non-zero, distinct message) if the guest merely never booted with no rejection line — a silent disk proves nothing. This rule and its evidence are in krytis's `docs/skills/secure-boot.md` § A negative test must assert the *rejection*, not just the absence of a boot; reference it in the recipe comment.

- [ ] **Step 4: `sealed-test-qemu` recipe**

```
# Secure Boot E2E: install from a live ISO, then boot the installed disk under
# enforcement. The live ISO is deliberately UNSIGNED (krytis #371 Design Gate),
# so phase 1 boots with plain OVMF and only phase 2 enables enforcement.
#   OVMF_VARS_SECURE — varstore with PK/KEK/db enrolled (krytis: mise run generate-ovmf-vars)
#   PAYLOAD_REF      — payload image ref for the fisherman recipe
#   EXPECT_FAIL      — assert the installed system is REJECTED (negative test)
sealed-test-qemu target:
```

Sequence: `plain-boot-qemu-live` (plain OVMF, unchanged) → `plain-install-qemu` (with `PAYLOAD_REF`) → `plain-boot-qemu-installed` with `SECURE_BOOT=1` + `OVMF_VARS_OVERRIDE=${OVMF_VARS_SECURE}` → `plain-verify-qemu` (honouring `EXPECT_FAIL`). Use distinct disk/socket/serial/port paths (`sealed-` prefix) so a sealed run and a plain run can coexist, as the existing luks/plain split already does.

- [ ] **Step 5: skill entry (same commit)** — append to `docs/skills/e2e-ci.md`: the two-varstore requirement (live unsigned / installed enforced) and why a single varstore yields a false negative on the live-boot phase; `smm=on` + pflash `secure=on` are both mandatory or enforcement is not exercised.

**Acceptance:** `just sealed-test-qemu krytis` runs both phases; `EXPECT_FAIL=1` inverts the verdict and distinguishes rejection from a silent non-boot.

---

## Task 6: krytis — `mise run iso-install-test` wrapper

**Files:**
- Create: `mise/tasks/iso-install-test`
- Modify: `docs/skills/bootc-vm.md` (same commit)

**Interfaces:**
- Consumes: `output/krytis-live-sealed.iso` (or `--iso`), `.ovmf-vars-secure.fd`, the sibling checkout
- Delegates to: `just sealed-test-qemu krytis` — QEMU/fisherman orchestration stays in dakota-iso, where it already lives, exactly as `build-iso` delegates ISO assembly

**Issue:** Part of #371

- [ ] **Step 1: write the task**

```bash
#!/usr/bin/env bash
#MISE description="Install Krytis from a live ISO in QEMU and assert the installed system boots (secure boot optional)"
#USAGE flag "--iso <path>" help="ISO to install from. Default: output/krytis-live-sealed.iso under --secure, output/krytis-live.iso otherwise"
#USAGE flag "--secure" help="Boot the INSTALLED disk with secure boot enforced (requires 'mise run generate-ovmf-vars'). The live ISO always boots unsigned — it is not signed by design (#371)"
#USAGE flag "--expect-fail" help="Invert the result: the installed system MUST be rejected by secure boot (negative test)"
#USAGE flag "--payload-ref <ref>" help="Payload image ref for the fisherman recipe. Default: matches the ISO variant"
```

Requirements:

- resolve `DAKOTA_ISO_DIR` with the same `git rev-parse --git-common-dir` block `build-iso` uses (copy it; a naive `${REPO_ROOT}/..` is wrong inside a worktree — that comment in `build-iso` exists because it already broke);
- mode-dependent defaults resolved **in the script, not in `#USAGE`**, for the reason documented in `boot-test` lines 43–48 and `docs/skills/secure-boot.md` § `--secure` picks the tag: a `default=` there cannot be told apart from the user typing the same value. `--secure` (without `--expect-fail`) → sealed ISO + `…/krytis:sealed`; otherwise → default ISO + `…/krytis:latest`;
- refuse up front, before the multi-minute QEMU run, when: `--secure` and `.ovmf-vars-secure.fd` is missing; the ISO does not exist; `--secure` without `--expect-fail` and the ISO is not the sealed one (run `verify-iso-payload` against it — a cheap, exact check that the ISO really carries the sealed payload, and the direct analogue of `boot-test`'s "does this image even have a UKI" guard);
- **sshd gate:** the E2E flow drives fisherman over SSH into the live session, and the live env ships sshd disabled unless the ISO was built with `--debug` (dakota-iso patches its own CI ISOs for this — `docs/skills/e2e-ci.md` § sshd is only enabled in debug ISOs). Detect it and fail with `run: mise run build-iso --sealed --debug`, rather than surfacing as `kex_exchange_identification: Connection reset`. Cheapest reliable detection: `verify-iso-payload`-style extraction is overkill — instead check the ISO's squashfs for the `sshd.service` enablement symlink, or (simpler and sufficient) document the requirement and let the SSH poll fail with an explicit hint after its first timeout;
- copy `.ovmf-vars-secure.fd` to a scratch path before handing it to QEMU so the enrolled varstore is never mutated by a test boot (`boot-test` line 235 does exactly this);
- invoke `just --justfile … --working-directory … sealed-test-qemu krytis` with `OVMF_VARS_SECURE`, `PAYLOAD_REF`, `EXPECT_FAIL`, `output_dir` pointing at the ISO's directory;
- print the serial-log paths on failure.

- [ ] **Step 2: skill entry (same commit)** — append to `docs/skills/bootc-vm.md`: `boot-test` covers the image→disk install path; `iso-install-test` covers the ISO→fisherman→disk path, which is the only one that exercises the offline store, recipe.json, and `targetImgref`. Note the debug-ISO/sshd prerequisite and that the live phase is deliberately unsigned.

**Acceptance:** `mise run iso-install-test --secure` completes both phases against a sealed debug ISO; every prerequisite failure is reported before QEMU starts.

---

# Phase D — Verification (the acceptance criteria)

## Task 7: run the matrix and record evidence

No code changes. Every run's command and verdict goes in the PR description; this section is the evidence AGENTS.md's Verification gate requires.

- [ ] **V1 — default path is unaffected** (acceptance criterion 5)
  `mise run build-iso` → `output/krytis-live.iso`. Confirm from the log that payload prep ran (`=== Squashing … to single layer ===` present, `PAYLOAD_SEALED=1` absent) and that recipe.json in `localhost/krytis-installer:latest` still says `:latest` for all four fields. This is the regression gate for Phase A; run it **before** any sealed run.
- [ ] **V2 — sealed ISO builds and embeds the right image** (acceptance criterion 1)
  `mise run build-iso --sealed --debug` → `output/krytis-live-sealed.iso`; `mise run verify-iso-payload` passes (it runs automatically at the end of the build). `--debug` is required for V3–V5's SSH-driven install.
- [ ] **V3 — sealed install boots under Secure Boot** (acceptance criterion 2)
  `mise run generate-ovmf-vars && mise run iso-install-test --secure`. Expect `Reached target …Graphical`. A `The UKI has the wrong composefs= parameter` abort here means the payload was mutated — re-check Task 2 Step 2's `rm -f` follow-through and `verify-iso-payload`.
- [ ] **V4 — sealed install boots without Secure Boot** (acceptance criterion 3)
  `mise run iso-install-test` against the **sealed** ISO (`--iso output/krytis-live-sealed.iso --payload-ref ghcr.io/starlit-os/krytis:sealed`, no `--secure`). The sealed image must remain a valid ordinary bootable image; bootc's composefs docs describe this as intentional and supported.
- [ ] **V5 — unsigned install is rejected under enforcement** (acceptance criterion 4)
  `mise run build-iso --debug` then `mise run iso-install-test --secure --expect-fail`. Pass requires `Access Denied`/`Security Violation` in the installed-boot serial log — not merely a silent non-boot, which is INCONCLUSIVE. Note in the PR that this variant does not *isolate* the signature (any other failure in the unsigned image looks the same); the byte-flip test that does isolate it is already covered by `mise run boot-test --secure --expect-fail`.
- [ ] **V6 — `targetImgref` is right** (F3, no acceptance criterion but a boot-path regression if wrong)
  On the V3-installed system: `bootc status --json | jq '.spec.image.image'` → must be `ghcr.io/starlit-os/krytis:sealed`. Do **not** run `bootc upgrade`; existence of the right ref is the assertion.
- [ ] **V7 — live ISO is still ordinary** (acceptance criterion 6)
  Already implied by V3/V4 booting the live phase with plain OVMF. State explicitly in the PR that nothing in `scripts/iso-sd-boot.sh`'s boot-chain assembly changed and no signing material entered dakota-iso.
- [ ] **V8 — `mise lint`** passes (AGENTS.md). Run it **last**: it rebuilds `:latest`, and a fresh `:latest` ID would make `:sealed` look stale to `ensure-sealed-image.sh` on the next sealed build.

---

# Phase E — Cleanup

Do not start Phase E until V1–V8 pass. Skill entries are **not** in this phase — they land with their tasks.

## Task 8: correct the `--boot=uki` claim

**Files:** `docs/skills/secure-boot.md`

- [ ] Rewrite the second sentence of § *Sealed images push under `:sealed` tags, never `:latest`* (line 194). It currently says a sealed image "needs `bootc install --composefs-backend --boot=uki`". `--boot=uki` does not exist on any `bootc install` subcommand — verified against the `bootc install to-filesystem` man page, whose full flag set is `--source-imgref`, `--target-imgref`, `--bootloader {grub,grub-cc,systemd,none}`, `--composefs-backend`, `--allow-missing-verity`, `--uki-addon`, plus disk/selinux/karg flags. Replacement, preserving the section's actual point (tag hygiene):

  > A sealed/UKI image is installed differently from an unsigned one — bootc **auto-detects** the UKI in the image and switches to the composefs backend itself ("Whenever the container image has a UKI, bootc automatically selects the composefs backend during installation"), so the installer only supplies `--composefs-backend` and `--bootloader systemd`. There is no `--boot=uki` flag; earlier revisions of this file claimed one, copied from a Fedora doc reference that has since been debunked. The consequence for tagging is unchanged: silently reusing `:latest` for the sealed variant would hand anyone expecting the ordinary install path an image whose boot chain only verifies against enrolled keys.

- [ ] Grep the repo for any other `--boot=uki` occurrence (`docs/`, `mise/`, `Containerfile*`) and correct each. This is a correction, not a new learning, so it is its own commit: `docs(secure-boot): correct the non-existent --boot=uki flag claim`.

## Task 9: docs plumbing, PR pairing, archival

- [ ] `docs/SKILL.md` — no new skill *file* is created, so the router needs no new row. Confirm the existing "Secure boot, signed UKI…" row still points where the new entries live, and add `iso-install-test` to the mise/bootc-vm row only if the existing wording would leave an agent unable to find it.
- [ ] `mise run docs-links` — passes (required before opening a docs-touching PR).
- [ ] Open the dakota-iso PR first (Tasks 1, 2, 5). Its commits reference this plan and the krytis PR; the krytis commits reference the dakota-iso PR URL. This satisfies AGENTS.md's Cross-repo exception; note the pairing explicitly in both PR descriptions so the §3 skills-check does not read the unavoidable two-repo split as a timing failure.
- [ ] Flag the **Breakage Gate** in the krytis PR description: this changes the ISO install path and what the installed system follows for upgrades (`targetImgref`). Include the V1–V8 evidence table. Human approves and merges.
- [ ] `git mv docs/plans/2026-08-01-add-sealed-payload-to-iso.md docs/plans/done/` in the same PR.
- [ ] Do not close #371 from the krytis PR alone — its dakota-iso checkbox lands in the other repo. Use `Closes #371` only once both PRs are merged; otherwise reference it (`Part of #371`) and close manually.

---

## Design decisions and rejected alternatives

1. **Pass the sealed payload through untouched rather than making `00-defaults.toml` "digest-safe."** The issue offered a second option: bake the injected content into krytis's sealed image *before* `ukify` computes the digest. Rejected — it would put a dakota-iso implementation detail (`root-mount-spec = LABEL=root`, plus a vfs `storage.conf` that has no business on an installed system) permanently into krytis's own image, to satisfy a file that is inert for UKI installs anyway. It also would not help: the `buildah run`/`commit --squash` round trips are themselves digest hazards independent of what they write.

2. **Explicit `PAYLOAD_SEALED` env flag, not auto-detection.** bootc auto-detects a UKI from image *content*, and mirroring that in dakota-iso would need a privileged mount or a `buildah from` just to probe `/boot/EFI/Linux/*.efi`. Krytis already knows — the user typed `--sealed` — and the flag flows exactly like `DEBUG`/`COMPRESSION` already do. The cost of the explicit flag is the stale-sibling hazard, which Task 3 Step 3's preflight closes.

3. **`PAYLOAD_REF` as one knob for all five ref sites.** Splitting the store key from `targetImgref` would allow "install sealed content but track `:latest`", which is exactly the footgun F3 describes. One knob makes the coupling unbreakable.

4. **`verify-iso-payload` asserts image-ID equality, not a recomputed composefs digest.** Recomputing the digest would mean re-running `bootc container ukify --rootfs` against a mounted copy of the embedded payload — heavy, privileged, and duplicating the check `bootc install` already performs authoritatively (with a better error message). Byte identity is a *stronger* invariant than digest equality and is what the pass-through design intends, so it is the right thing to assert; the install is the end-to-end proof.

5. **QEMU orchestration stays in dakota-iso.** krytis gets a thin `mise` wrapper. The alternative — reimplementing the ISO-boot/fisherman/verify cycle in `mise/tasks/` — would duplicate ~200 lines of already-debugged QEMU handling (ENOSPC scratch disk, KVM fallback, monitor screendumps) and diverge on the first fix. `build-iso` already establishes the delegation precedent.

6. **`ensure-sealed-image.sh` extracted rather than copy-pasted.** Third occurrence rule: `push` had it, `build-iso` now needs it, and the `.Created` rule has non-obvious semantics documented in a skill file. One caller each is not enough to justify extraction; two callers plus a documented invariant is.

7. **No CI job.** There is no ISO workflow in `.github/workflows/` today (grep: zero `build-iso` references), so `--sealed` and `iso-install-test` are local tasks like `boot-test`. Adding an ISO CI pipeline is its own issue — it needs a runner with ~60 GB scratch and ~40 minutes per matrix cell.

## Risks

- **The pass-through may reveal a second digest hazard downstream.** `_ns_build_squashfs` imports the archive via `skopeo copy` into a VFS store, which is content-preserving — but this has never been exercised with a sealed image. V3's `bootc install` is the detector; the error message names both digests, which is enough to localise it. Mitigation if it fires: compare the store's diff_id against `:sealed`'s (`verify-iso-payload` already does), which separates "the store is wrong" from "the digest computation disagrees for another reason."
- ~~**`podman save --format oci-archive` may not preserve the config digest.**~~ **Verified 2026-08-01, not a risk:** `podman save --format oci-archive -o /var/tmp/p.tar localhost/krytis:sealed` then `skopeo inspect --raw`/`--config` on the archive returned config digest `sha256:0b00a10aad1a…` and layer diff_id `sha256:e2ae30e0f0ac…` — both identical to `podman inspect localhost/krytis:sealed --format '{{.Id}} {{index .RootFS.Layers 0}}'`. Krytis images are already OCI-format, so no manifest conversion occurs and no digest is rewritten. `verify-iso-payload`'s image-ID equality gate is therefore sound as specified; the observed pair is the expected value to compare against until `:sealed` is rebuilt.
- **`bootc upgrade` on a sealed system needs `ghcr.io/starlit-os/krytis:sealed` to exist in the registry.** It does today (pushed 3 days ago by `mise run push --sealed`), but a sealed ISO shipped while that tag is stale would upgrade a machine backwards. Out of scope here; worth an issue on the publish workflow if sealed ISOs are ever released.
- **`mise lint` rebuilds `:latest`** and can therefore make `:sealed` look stale, silently triggering a full re-seal on the next `build-iso --sealed`. Known behaviour of the `.Created` rule (already documented); V8 runs lint last to avoid conflating it with a test failure.
