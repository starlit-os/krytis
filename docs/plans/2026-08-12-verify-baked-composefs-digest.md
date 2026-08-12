# Verify Baked Composefs Digest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close issue #528 — `mise/tasks/seal-uki` must fail at build time (not on real hardware) when the `composefs=` digest baked into the UKI's frozen `.cmdline` no longer matches the committed `localhost/krytis:sealed` image.

**Architecture:** A new standalone, reusable mise task (`mise/tasks/verify-composefs-digest`) extracts the baked digest from a sealed image's UKI (byte-scan, no `ukify`/`objcopy` dependency) and independently recomputes the digest against the *committed* image — never a rebuild — using `bootc container compute-composefs-digest` (the primitive `bootc container ukify` calls internally) through a read-only `podman run --mount type=image` view of the same image. `mise/tasks/seal-uki` calls this task automatically as its new `[3/3]` phase, so the check runs on every sealed build with no extra step for the common path. The task also works standalone against any pulled image (e.g. `ghcr.io/starlit-os/krytis:sealed`), which is how #528 was investigated and how this plan's tests are built.

**Tech Stack:** bash (`set -euo pipefail`, matches `mise/tasks/verify-iso-payload`/`ensure-sealed-image.sh` conventions), podman 4.9.3+ (`--mount type=image` — available since podman ~2.x, no version gate needed), bootc 1.16.x (`bootc container compute-composefs-digest`, present inside every krytis image), `grep -aoE`.

## Global Constraints

- Must compare against the **committed** image, never a rebuild — a rebuild can produce a different, equally correct digest and prove nothing (#528 body, explicit).
- Must fail the task (non-zero exit) and **name both digest values** on mismatch (#528 body, explicit).
- No podman/engine version gate — #524 added one on a wrong theory, #527 reverted it; `mise/tasks/seal-uki`'s own header comment forbids re-adding one without evidence. This check is engine-agnostic by design and is meant to be *the* alternative to a version gate.
- No new root/privileged requirement — krytis's existing podman usage is rootless throughout; `--mount type=image` works rootless (verified in the #528 investigation), unlike the `podman mount`/`podman unshare` pairing the by-hand procedure in `docs/skills/secure-boot.md` used, which does not expose its mount path outside the unshare namespace on this project's podman (5.4.2, `overlay` driver).
- New maintenance/check logic must be a mise task, not a loose shell command (AGENTS.md "Mise task integrity").
- Skill-file update for any newly-discovered pattern must land in the same commit as the code that produced it (AGENTS.md self-improvement mandate). `docs/skills/secure-boot.md` already carries the general by-hand technique (committed ahead of this plan, from the #528 investigation); this plan's Task 2 adds one cross-reference sentence pointing at the shipped task file, in the same commit as the `seal-uki` wiring.

---

### Task 1: `mise/tasks/verify-composefs-digest` — standalone digest check

**Files:**
- Create: `mise/tasks/verify-composefs-digest`

**Interfaces:**
- Consumes: nothing from other tasks. Reads `--image <tag>` (default `localhost/krytis:sealed`) or `usage_image` (mise-parsed `#USAGE` value) when invoked directly as `mise run verify-composefs-digest`.
- Produces: exit 0 + `sha512:<digest>` printed on stdout's last line when baked == recomputed. Exit 1 with both values printed to stderr on mismatch. Consumed by Task 2 (`mise/tasks/seal-uki` calls `./mise/tasks/verify-composefs-digest --image localhost/krytis:sealed`).

- [ ] **Step 1: Write the task**

```bash
#!/usr/bin/env bash
#MISE description="Assert the composefs= digest baked into a sealed image's UKI matches the committed image itself (#528)"
#USAGE flag "--image <tag>" default="localhost/krytis:sealed" help="Sealed image to verify"

set -euo pipefail

# Why this exists: `bootc container ukify` bakes a composefs= digest into the UKI's
# frozen .cmdline at seal time (mise/tasks/seal-uki). Nothing checked that the baked
# value still matches the image that was actually committed — a mismatch was invisible
# until a real machine booted and stopped at "The UKI has the wrong composefs=
# parameter" (#528). The two-phase squash in seal-uki exists precisely because this is
# fragile (docs/skills/secure-boot.md § `--composefs-backend` requires a single layer).
#
# Must check the COMMITTED image, never a rebuild — a rebuild can produce a different,
# equally correct digest and prove nothing (the whole point of #528). See
# docs/skills/secure-boot.md § Verifying the baked digest against an already-published
# image, no rebuild, no root for the by-hand procedure this task automates.

# Same $@-then-usage_ fallback as verify-iso-payload/boot-test: mise does not parse
# #USAGE for a child script invoked as a plain path (seal-uki calls this directly).
CLI_IMAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) CLI_IMAGE="$2"; shift 2 ;;
        *) break ;;
    esac
done
IMAGE="${CLI_IMAGE:-${usage_image:-localhost/krytis:sealed}}"

podman image exists "${IMAGE}" || { echo "==> ERROR: ${IMAGE} does not exist locally." >&2; exit 1; }

echo "==> Verifying composefs digest baked into ${IMAGE}'s UKI (#528)..."

UKI_TMP="$(mktemp /var/tmp/krytis-verify-uki-XXXXXX.efi)"
CID=""
cleanup() {
    [ -n "${CID}" ] && podman rm -f "${CID}" >/dev/null 2>&1 || true
    rm -f "${UKI_TMP}"
}
trap cleanup EXIT

CID="$(podman create "${IMAGE}" true)"
if ! podman cp "${CID}:/boot/EFI/Linux/krytis.efi" "${UKI_TMP}" 2>/dev/null; then
    echo "==> ERROR: ${IMAGE} has no /boot/EFI/Linux/krytis.efi — that is not a sealed build." >&2
    echo "    Build one first: mise run seal-uki" >&2
    exit 1
fi

# .cmdline is a plain string inside the PE; SHA-512 hex (128 lowercase chars) is
# specific enough that a raw byte-scan is safe — no ukify/objcopy dependency.
mapfile -t MATCHES < <(grep -aoE 'composefs=[0-9a-f]{128}' "${UKI_TMP}")
if [ "${#MATCHES[@]}" -eq 0 ]; then
    echo "==> ERROR: no composefs= parameter found in ${IMAGE}'s UKI .cmdline section." >&2
    exit 1
fi
if [ "${#MATCHES[@]}" -gt 1 ]; then
    echo "==> ERROR: found ${#MATCHES[@]} composefs= matches in the UKI, expected exactly 1." >&2
    exit 1
fi
BAKED_DIGEST="${MATCHES[0]#composefs=}"

RECOMPUTED_DIGEST="$(podman run --rm \
    --mount type=image,src="${IMAGE}",target=/target,rw=false \
    "${IMAGE}" \
    bootc container compute-composefs-digest /target)"

if [ "${BAKED_DIGEST}" != "${RECOMPUTED_DIGEST}" ]; then
    echo "==> ERROR: composefs digest mismatch (#528) — the UKI's baked digest does not match the committed image." >&2
    echo "    baked in UKI:  sha512:${BAKED_DIGEST}" >&2
    echo "    recomputed:    sha512:${RECOMPUTED_DIGEST}" >&2
    echo "    'bootc install' would abort with: The UKI has the wrong composefs= parameter" >&2
    exit 1
fi

echo "==> Composefs digest verified: sha512:${BAKED_DIGEST}"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x mise/tasks/verify-composefs-digest
```

- [ ] **Step 3: Positive-path test — against a real published sealed image**

```bash
podman pull ghcr.io/starlit-os/krytis:sealed
./mise/tasks/verify-composefs-digest --image ghcr.io/starlit-os/krytis:sealed
```

Expected: exit 0, last line `==> Composefs digest verified: sha512:e0f24c43742626680aaa5650859d5d5db2cbb67d134649b27468bbd2562b7f563175e37e4c8c996c021ce091bbea35c0f94c6c5545d0fedfeab27348f8483815` (the digest verified against this exact tag during the #528 investigation on 2026-08-12; it will differ once the tag is next re-sealed, which is expected — only the *match* is the assertion, not this literal value).

- [ ] **Step 4: Negative-path test — not a sealed image**

```bash
./mise/tasks/verify-composefs-digest --image localhost/krytis:latest
echo "exit=$?"
```

Expected: exit 1, stderr contains `has no /boot/EFI/Linux/krytis.efi — that is not a sealed build.` (`localhost/krytis:latest` is the unsigned build; only `mise run seal-uki`'s output ever has a UKI — `docs/skills/secure-boot.md` § `--secure` picks the tag).

- [ ] **Step 5: Negative-path test — genuine digest mismatch**

Build a fixture whose UKI is byte-identical to a real sealed image's, but whose rootfs is not — so the baked digest and the recomputed digest are guaranteed to disagree, without needing signing keys:

```bash
WORKDIR="$(mktemp -d)"
CID="$(podman create ghcr.io/starlit-os/krytis:sealed true)"
podman cp "${CID}:/boot/EFI/Linux/krytis.efi" "${WORKDIR}/krytis.efi"
podman rm -f "${CID}"
echo "mismatch-fixture" > "${WORKDIR}/extra.txt"
cat > "${WORKDIR}/Containerfile" <<'EOF'
FROM scratch
COPY krytis.efi /boot/EFI/Linux/krytis.efi
COPY extra.txt /extra.txt
EOF
podman build -t localhost/krytis-digest-mismatch-fixture "${WORKDIR}"
rm -rf "${WORKDIR}"

./mise/tasks/verify-composefs-digest --image localhost/krytis-digest-mismatch-fixture
echo "exit=$?"

podman rmi localhost/krytis-digest-mismatch-fixture
```

Expected: exit 1, stderr contains `composefs digest mismatch (#528)` followed by two lines starting `baked in UKI:` and `recomputed:` with two different `sha512:` values, and the closing `'bootc install' would abort with: The UKI has the wrong composefs= parameter` line.

- [ ] **Step 6: Commit**

```bash
git add mise/tasks/verify-composefs-digest
git commit -m "feat(secure-boot): add standalone composefs digest verification task

Extracts the composefs= digest baked into a sealed image's UKI .cmdline
and independently recomputes it against the committed image (never a
rebuild) via bootc container compute-composefs-digest, run through a
read-only podman run --mount type=image view of the same image. Fails
loudly, naming both values, on mismatch.

Refs #528"
```

---

### Task 2: Wire the check into `mise/tasks/seal-uki`

**Files:**
- Modify: `mise/tasks/seal-uki` (renumber phase labels `[1/2]`→`[1/3]`, `[2/2]`→`[2/3]`; add `[3/3]` calling Task 1's task; extend the "NOTE ON ENGINE VERSIONS" comment)
- Modify: `docs/skills/secure-boot.md` (one cross-reference sentence in the section this plan's Task 1 automates)

**Interfaces:**
- Consumes: `./mise/tasks/verify-composefs-digest --image localhost/krytis:sealed` (Task 1's CLI contract — exit 0/1, stderr detail on failure).
- Produces: `seal-uki` now fails (propagates the non-zero exit from `verify-composefs-digest`, `set -euo pipefail` already in effect) before printing its final success line whenever the two phases produced a mismatched digest.

- [ ] **Step 1: Update the `[1/2]` label**

Change the phase-1 echo:

```bash
echo "==> [1/3] Building + squashing sealed rootfs -> localhost/krytis:sealed-base..."
```

- [ ] **Step 2: Update the `[2/2]` label**

Change the phase-2 echo:

```bash
echo "==> [2/3] Building UKI against sealed-base -> localhost/krytis:sealed..."
```

- [ ] **Step 3: Add phase 3, replacing the final echo**

The task currently ends with:

```bash
echo "==> Sealed image built: localhost/krytis:sealed"
```

Replace it with:

```bash
echo "==> [3/3] Verifying baked composefs digest against the committed image (#528)..."
./mise/tasks/verify-composefs-digest --image localhost/krytis:sealed

echo "==> Sealed image built and verified: localhost/krytis:sealed"
```

- [ ] **Step 4: Extend the "NOTE ON ENGINE VERSIONS" comment**

That comment (near the top of the file) currently ends:

```bash
# 4.9.3 and 5.8.2 both produce a correct sealed image. The engine-sensitivity of
# the squash is real, but the way to catch a bad digest is to CHECK THE DIGEST
# (#528), not to guess at version numbers.
```

Append one line so the comment points at the real mechanism instead of only naming the issue:

```bash
# 4.9.3 and 5.8.2 both produce a correct sealed image. The engine-sensitivity of
# the squash is real, but the way to catch a bad digest is to CHECK THE DIGEST
# (#528), not to guess at version numbers. Phase [3/3] below
# (mise/tasks/verify-composefs-digest) is that check — it runs on every
# seal-uki invocation, engine-agnostic, and fails loudly naming both digests
# on a real mismatch instead of guessing from a version number.
```

- [ ] **Step 5: Cross-reference the shipped task from the skill doc**

In `docs/skills/secure-boot.md`, in the section `### Verifying the baked digest against an already-published image, no rebuild, no root` (added ahead of this plan), append one sentence after the by-hand shell walkthrough:

```markdown
`mise/tasks/verify-composefs-digest` (#528) automates exactly these two steps and is
now `mise/tasks/seal-uki`'s `[3/3]` phase — reach for the by-hand version above only
when debugging the task itself or checking an image outside the seal-uki flow (e.g.
a pulled `ghcr.io/starlit-os/krytis:sealed`, as this section's own verification was
done).
```

- [ ] **Step 6: Verify the renumbering and wiring read correctly**

```bash
grep -n '\[1/3\]\|\[2/3\]\|\[3/3\]\|verify-composefs-digest' mise/tasks/seal-uki
```

Expected: four matches — the two build-phase echoes, the new phase-3 echo, and the `./mise/tasks/verify-composefs-digest` call line.

- [ ] **Step 7: Full end-to-end verification (requires signing keys — run where Proton Pass vault access is configured)**

```bash
mise run seal-uki
```

Expected: all three phases print, ending with `==> [3/3] Verifying baked composefs digest against the committed image (#528)...` immediately followed by Task 1's `==> Composefs digest verified: sha512:...` line and then `==> Sealed image built and verified: localhost/krytis:sealed`. This step cannot run in a sandbox without `files/boot-keys/db.key` (`mise run pull-keys` needs vault access) — whoever executes this plan with real keys must run it and paste the actual output into the PR description as the required verification evidence (AGENTS.md "Verification").

`mise run tpm-boot-test` remains the end-to-end check per #528's own notes — this step is a seconds-long build-time gate in front of it, not a replacement.

- [ ] **Step 8: Commit**

```bash
git add mise/tasks/seal-uki docs/skills/secure-boot.md
git commit -m "feat(secure-boot): assert baked composefs digest in seal-uki [3/3]

seal-uki now runs verify-composefs-digest automatically after building
localhost/krytis:sealed, turning a hardware-only 'The UKI has the wrong
composefs= parameter' failure into a build-time one. Point the existing
no-version-gate warning at this as the real mechanism, per #528's own
suggestion.

Refs #528"
```

---

## Self-Review

**1. Spec coverage.** #528 asks for three things: (1) extract the baked `composefs=` digest from the UKI — Task 1 Step 1 (`grep -aoE`); (2) recompute against the committed `:sealed` image, not a rebuild — Task 1 Step 1 (`podman run --mount type=image` against the already-built tag, no `podman build` involved); (3) fail the task naming both values — Task 1 Step 1's mismatch branch. The issue's Notes also ask that (a) the check live in `seal-uki` itself — Task 2; (b) it be engine-agnostic (no version gate) — Global Constraints + Task 2 Step 4; (c) the existing "don't re-add a version gate" comment point at the real mechanism — Task 2 Step 4; (d) `tpm-boot-test` remain the end-to-end check — noted in Task 2 Step 7.

**2. Placeholder scan.** No TBD/TODO markers; every step has literal script content or an exact command with expected output.

**3. Type consistency.** `IMAGE` (Task 1) is the only cross-task name — Task 2 calls the task with `--image localhost/krytis:sealed`, matching Task 1's `#USAGE flag "--image <tag>"`. Exit codes (0/1) and the stderr message shapes referenced in Task 1's tests match what Task 1's own script prints.
