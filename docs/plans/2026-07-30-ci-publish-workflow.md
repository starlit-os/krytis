# CI Image Publish Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual, human-run `mise run push` publish step with a GitHub Actions workflow (`.github/workflows/publish.yml`, `workflow_dispatch` only) that builds `oci/krytis/image.bst`, pushes it to `ghcr.io/starlit-os/krytis`, attaches the SBOM (#40) and Grype vulnerability report (#41) as OCI referrers, gates on vulnerability severity, and signs the image + both referrers with cosign keyless/OIDC (#60).

**Architecture:** One `workflow_dispatch`-triggered job on a Blacksmith runner runs the existing `mise run build` → `mise run push` pipeline unmodified in spirit, with two additions: (1) `mise/tasks/push` gains a `--digest-file` output so the manifest digests of the pushed image and both OCI referrers survive past the step boundary, and (2) a new `mise/tasks/sign` task performs `cosign sign -y` against each of those digests using GitHub Actions' ambient OIDC token (`id-token: write`). The severity gate (`mise run push --fail-on critical`, default) and signing (`mise run sign`, `continue-on-error: true`) are independent steps — a blocked push (severity gate tripped) does not skip signing, and a signing failure does not fail the job. This is the practical form of "parallel/best-effort" available without splitting the multi-hour BST build across jobs.

**Tech Stack:** GitHub Actions (`workflow_dispatch`), Blacksmith runner (`blacksmith-8vcpu-ubuntu-2404`), mise tasks (bash), BuildStream 2, podman, `oras` CLI, Grype, cosign (keyless/OIDC via Sigstore Fulcio/Rekor) — `oras` and `grype` already mise-managed tools; `cosign` is newly added the same way.

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only
- All maintenance tasks must be `mise` tasks — no loose shell commands (AGENTS.md "Mise task integrity")
- `mise lint` must pass before opening a PR
- Agents MUST NOT push directly to `main` — all changes via PR from a feature branch
- Worktree + branch required before touching files (AGENTS.md convention)
- Skill file updates must land in the same commit as the change that produced the learning
- SHA-pin every new `uses:` action reference — `mise lint` (`actionlint`) auto-upgrades floating tags on commit, per `docs/skills/ci-runner.md`
- Any new `uses: <owner>/<repo>` action must already be on the `starlit-os` org allowlist, or the human must be prompted to add it before merge (`docs/skills/ci-runner.md` § Org allowlist)
- **Design decisions locked in for this plan (do not re-litigate):**
  - **Trigger:** `workflow_dispatch` only — no `push`/`schedule` trigger for now.
  - **Runner:** `blacksmith-8vcpu-ubuntu-2404` (matches `cache-warm.yml`'s default label) — no self-hosted fallback input in this iteration. If Blacksmith proves unfeasible (disk/time), swap `runs-on:` to `["self-hosted","linux","x64"]` in a follow-up; nothing else in this workflow is Blacksmith-specific.
  - **Severity gate:** default blocking at `critical` (`mise run push --fail-on critical`). A `report_only` boolean `workflow_dispatch` input (default `false`) switches to warn-only (`mise run push` with no `--fail-on`). See Task 5 for the empirical basis of picking `critical` over `high`.
  - **Signing:** parallel/best-effort — the sign step runs `if: always()` (regardless of whether the severity gate step passed or failed) with `continue-on-error: true` (a signing failure never fails the job).

## Prerequisites (before starting any task)

- [ ] Read `AGENTS.md`, `docs/SKILL.md`, `docs/skills/sbom.md`, `docs/skills/ci-runner.md`, `docs/skills/mise.md` § Propagating flags through tasks that call other tasks
- [ ] Read `.github/workflows/cache-warm.yml` and `.github/workflows/track-bst-sources.yml` for house style (SHA-pinned actions, `permissions:` blocks, `concurrency:` groups)
- [ ] Create a worktree: `git worktree add -b 380-add-ci-image-publish-workflow .worktrees/feat/gh380-add-ci-image-publish-workflow`
- [ ] `mise trust` in the worktree
- [ ] Confirm `BUILDBARN_PULL_TOKEN` repo secret already exists (used by `cache-warm.yml`) — this workflow reuses it for `mise run build --pull`
- [ ] Confirm `secrets.GITHUB_TOKEN` has `packages: write` available (standard on `starlit-os/krytis`; verified by `mise/tasks/push` already using this exact token-resolution pattern for local `gh auth token` fallback)

**Empirical baseline gathered for Task 5** (do not re-run unless the SBOM/scan pipeline changes): a real `mise run sbom` + `scripts/enrich-sbom-purls.py` + `grype` run against the current `oci/krytis/image.bst` on 2026-07-30 produced **125 matches: 5 Critical, 69 High, 40 Medium, 11 Low**. The 5 Critical hits are `libidn2@2.3.8` (GHSA-j6m4-68hc-mqq9), `networkx@3.6.1` (GHSA-m4cf-q2p6-q6pv), `shaderc@2025.3` (GHSA-3h68-ppv2-8p9v), and `tar@1.35` (GHSA-23hp-3jrh-7fpw, appearing twice via two separate `tar`-sourced packages). None are blank-version wrapper false positives (that class was already eliminated by #41's enrichment step) — they're real CPE-fallback matches on real installed versions, unverified as true/false positives at this level (out of scope here; that triage is Grype's/#41's existing behavior, not something this workflow changes).

---

## Task 1: Add `cosign` as a mise-managed tool

**Files:**
- Modify: `mise.toml:5-23` (the `[tools]` table)

**Interfaces:**
- Produces: `cosign` binary on `PATH` after `mise install` (already run by `jdx/mise-action` in every existing workflow, and by `mise bootstrap`/`uv sync` locally)
- Consumes: nothing

- [ ] **Step 1: Add the tool declaration**

Current `mise.toml:20-23`:

```toml
oras = "latest"
# grype: required by `mise run vuln-scan` / `mise run push` to scan the SBOM
# for known CVEs (#41). Dev-host tooling only.
grype = "latest"
```

Add immediately after:

```toml
# cosign: required by `mise run sign` to sign the published image and its
# OCI referrers with Sigstore keyless/OIDC signing (#60). Dev-host tooling
# only — in CI it needs the `id-token: write` job permission for ambient
# GitHub Actions OIDC detection; locally it falls back to an interactive
# browser-based Sigstore login.
cosign = "latest"
```

- [ ] **Step 2: Verify resolution**

Run: `mise install cosign && mise exec cosign -- cosign version`
Expected: prints a `cosign` version (3.x as of 2026-07-30), no error

- [ ] **Step 3: Commit**

```bash
git add mise.toml
git commit -m "chore(mise): add cosign tool for keyless image signing (#60)"
```

---

## Task 2: Teach `mise/tasks/push` to emit a digest hand-off file

**Files:**
- Modify: `mise/tasks/push` (full file, 143 lines)

**Interfaces:**
- Produces: `krytis-push-digests.env` (default path, overridable via `--digest-file`) containing `image_digest=sha256:...`, and (when not skipped) `sbom_digest=sha256:...` / `vuln_digest=sha256:...` — one `KEY=VALUE` line per digest, sourceable by bash or readable by `mise/tasks/sign` (Task 3)
- Consumes: nothing new — same `SOURCE_TAG` / `REGISTRY` / `--fail-on` inputs as today

**Why:** `mise/tasks/sign` needs the exact manifest digest of the image and each OCI referrer to sign them individually (`cosign sign -y <ref>@<digest>`). Today those digests are computed transiently inside `push` (`$DIGEST` from `podman push --digestfile`) and never captured for the SBOM/vuln-report `oras attach` calls at all. This task makes all three digests durable on disk so a later, independent step (CI or a human) can sign them without re-deriving state.

- [ ] **Step 1: Read the current file for the exact line numbers to replace**

Run: `read mise/tasks/push` (or open it) and confirm it still matches the version below before editing — this task assumes PR #379's merged shape.

- [ ] **Step 2: Replace the full file**

```bash
#!/usr/bin/env bash
#MISE description="Push krytis image to ghcr.io/starlit-os/krytis — run mise build first (or mise run seal-uki --sealed)"
#USAGE flag "--registry <registry>" default="ghcr.io/starlit-os/krytis" help="Registry and image path to push to"
#USAGE flag "--sealed" help="Push the signed UKI image (localhost/krytis:sealed) instead of the unsigned one"
#USAGE flag "--skip-sbom" help="Skip SBOM generation and OCI-referrer attach (#40) — faster iteration, no supply-chain artifact"
#USAGE flag "--skip-vuln-scan" help="Skip Grype vulnerability scan and OCI-referrer attach (#41) — faster iteration, no scan artifact"
#USAGE flag "--fail-on <severity>" help="Exit non-zero if the vuln scan finds a vulnerability >= this severity (negligible|low|medium|high|critical). Default: warn-only, never fails the push"
#USAGE flag "--digest-file <path>" default="krytis-push-digests.env" help="Write image_digest/sbom_digest/vuln_digest here for mise run sign (#60) to consume"

set -euo pipefail

REGISTRY="${usage_registry:-ghcr.io/starlit-os/krytis}"
SEALED=$([[ "${usage_sealed:-}" == "true" ]] && echo 1 || echo 0)
SKIP_SBOM=$([[ "${usage_skip_sbom:-}" == "true" ]] && echo 1 || echo 0)
SKIP_VULN_SCAN=$([[ "${usage_skip_vuln_scan:-}" == "true" ]] && echo 1 || echo 0)
FAIL_ON="${usage_fail_on:-}"
OUT_DIGESTS="${usage_digest_file:-krytis-push-digests.env}"
VERSION=$(grep '^image-version:' include/image-version.yml | awk '{print $2}' | tr -d "'")

if [[ -z "$VERSION" ]]; then
  echo "==> ERROR: include/image-version.yml missing or has no image-version — run mise build first" >&2
  exit 1
fi

if [[ "$SEALED" -eq 1 ]]; then
  SOURCE_TAG="localhost/krytis:sealed"
  DEST_VERSION_TAG="${REGISTRY}:${VERSION}-sealed"
  DEST_LATEST_TAG="${REGISTRY}:sealed"

  if ! podman image exists localhost/krytis:latest; then
    echo "==> ERROR: localhost/krytis:latest not found locally — run mise build first (needed as the freshness reference for --sealed)" >&2
    exit 1
  fi

  LATEST_CREATED=$(date -d "$(podman inspect localhost/krytis:latest --format '{{.Created}}')" +%s)
  if podman image exists "$SOURCE_TAG"; then
    SEALED_CREATED=$(date -d "$(podman inspect "$SOURCE_TAG" --format '{{.Created}}')" +%s)
  else
    SEALED_CREATED=0
  fi

  if [[ "$SEALED_CREATED" -lt "$LATEST_CREATED" ]]; then
    echo "==> ${SOURCE_TAG} is missing or older than localhost/krytis:latest — running mise run seal-uki..."
    ./mise/tasks/seal-uki
  fi
else
  SOURCE_TAG="localhost/krytis:latest"
  DEST_VERSION_TAG="${REGISTRY}:${VERSION}"
  DEST_LATEST_TAG="${REGISTRY}:latest"
fi

if ! podman image exists "$SOURCE_TAG"; then
  echo "==> ERROR: ${SOURCE_TAG} not found locally — run $([[ "$SEALED" -eq 1 ]] && echo 'mise run seal-uki' || echo 'mise build') first" >&2
  exit 1
fi

# GITHUB_TOKEN is injected by mise hook-env (OAuth) or by CI. Fall back to gh auth token
# for local dev where mise OAuth is not configured. See mise.jdx.dev/dev-tools/github-tokens.html
TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "token")

# Verify write:packages scope before attempting a 4GB push.
# gh auth token won't have it by default — run: gh auth refresh -s write:packages
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  SCOPES=$(gh auth status 2>&1 | grep 'Token scopes:' || true)
  if [[ "$SCOPES" != *"write:packages"* ]]; then
    echo "==> ERROR: gh token is missing write:packages scope." >&2
    echo "    Run: gh auth refresh -s write:packages" >&2
    exit 1
  fi
fi

echo "==> Logging in to ghcr.io as ${GH_USER}..."
echo "$TOKEN" | podman login ghcr.io --username "$GH_USER" --password-stdin

echo "==> Tagging ${SOURCE_TAG} → ${DEST_VERSION_TAG} and ${DEST_LATEST_TAG}..."
podman tag "$SOURCE_TAG" "$DEST_VERSION_TAG"
podman tag "$SOURCE_TAG" "$DEST_LATEST_TAG"

echo "==> Pushing ${DEST_VERSION_TAG}..."
DIGEST_FILE=$(mktemp)
podman push --digestfile "$DIGEST_FILE" "$DEST_VERSION_TAG"

echo "==> Pushing ${DEST_LATEST_TAG}..."
podman push "$DEST_LATEST_TAG"

echo "==> Done: pushed ${DEST_VERSION_TAG} and ${DEST_LATEST_TAG}"

# Both tags above are pushed from the same SOURCE_TAG image ID, so they
# share one content-addressed manifest digest — capture it once, regardless
# of whether SBOM/vuln-scan run, so `mise run sign` (#60) always has an
# image digest to work with.
IMAGE_DIGEST=$(cat "$DIGEST_FILE")
rm -f "$DIGEST_FILE"
echo "image_digest=${IMAGE_DIGEST}" > "$OUT_DIGESTS"
echo "==> Image digest: ${IMAGE_DIGEST} (written to ${OUT_DIGESTS})"

if [[ "$SKIP_SBOM" -eq 0 ]]; then
  echo "==> Generating SBOM (#40)..."
  ./mise/tasks/sbom --output krytis.spdx.json

  echo "==> Attaching SBOM as OCI referrer to ${REGISTRY}@${IMAGE_DIGEST}..."
  echo "$TOKEN" | oras login ghcr.io --username "$GH_USER" --password-stdin
  SBOM_DIGEST=$(oras attach \
    --artifact-type application/vnd.spdx+json \
    --format go-template --template '{{.digest}}' \
    "${REGISTRY}@${IMAGE_DIGEST}" \
    krytis.spdx.json:application/vnd.spdx+json)
  echo "sbom_digest=${SBOM_DIGEST}" >> "$OUT_DIGESTS"

  echo "==> Done: SBOM attached to ${REGISTRY}@${SBOM_DIGEST}"

  if [[ "$SKIP_VULN_SCAN" -eq 0 ]]; then
    echo "==> Preparing SBOM for vulnerability scanning (#41)..."
    uv run python3 scripts/enrich-sbom-purls.py krytis.spdx.json krytis.enriched.spdx.json

    FAIL_FLAG=()
    if [[ -n "$FAIL_ON" ]]; then
      FAIL_FLAG=(-f "$FAIL_ON")
    fi

    echo "==> Scanning with Grype..."
    set +e
    grype "sbom:krytis.enriched.spdx.json" -o "json=krytis.grype.json" -o table "${FAIL_FLAG[@]}"
    GRYPE_EXIT=$?
    set -e

    echo "==> Attaching vulnerability report as OCI referrer to ${REGISTRY}@${IMAGE_DIGEST}..."
    VULN_DIGEST=$(oras attach \
      --artifact-type application/vnd.grype.report+json \
      --format go-template --template '{{.digest}}' \
      "${REGISTRY}@${IMAGE_DIGEST}" \
      krytis.grype.json:application/vnd.grype.report+json)
    echo "vuln_digest=${VULN_DIGEST}" >> "$OUT_DIGESTS"

    echo "==> Done: vulnerability report attached to ${REGISTRY}@${VULN_DIGEST}"

    if [[ "$GRYPE_EXIT" -eq 2 ]]; then
      echo "==> ERROR: Grype found vulnerabilities >= ${FAIL_ON} severity — see krytis.grype.json" >&2
      exit 1
    elif [[ "$GRYPE_EXIT" -ne 0 ]]; then
      echo "==> ERROR: Grype exited unexpectedly (code ${GRYPE_EXIT})" >&2
      exit "$GRYPE_EXIT"
    fi
  else
    echo "==> Skipped vulnerability scan (--skip-vuln-scan)"
  fi
else
  echo "==> Skipped SBOM attach (--skip-sbom)"
  echo "    Note: vulnerability scan also skipped — it scans the SBOM generated here."
fi

echo "==> Digests written to ${OUT_DIGESTS}:"
cat "$OUT_DIGESTS"
```

Note what changed vs. the merged #379 version: `$DIGEST` renamed to `$IMAGE_DIGEST` throughout (clarity — there are now three digests in play); digest capture moved above the `SKIP_SBOM` branch so it always runs; both `oras attach` calls now use `--format go-template --template '{{.digest}}'` to capture the referrer's own manifest digest instead of relying on default text output; a new `--digest-file`-driven `$OUT_DIGESTS` file accumulates all three as they become available. Behavior for every existing flag (`--sealed`, `--skip-sbom`, `--skip-vuln-scan`, `--fail-on`) is unchanged.

- [ ] **Step 3: Add `.gitignore` entry for the new output file**

`.gitignore` already has (near the bottom):

```
include/image-version.yml
*.spdx.json
krytis.grype.json
```

Add immediately after `krytis.grype.json`:

```
krytis-push-digests.env
```

- [ ] **Step 4: Verify with `bash -n` and a dry run against a local test registry**

```bash
bash -n mise/tasks/push
```
Expected: no output (syntax OK).

Local registry smoke test (mirrors PR #379's own verification method):

```bash
podman run -d -p 5000:5000 --name test-registry docker.io/library/registry:2
mise run build   # or reuse an already-built localhost/krytis:latest
mise run push --registry localhost:5000/krytis --fail-on critical
cat krytis-push-digests.env
```
Expected: `krytis-push-digests.env` contains three `KEY=sha256:...` lines (`image_digest`, `sbom_digest`, `vuln_digest`); command exits non-zero (Critical findings exist per the Prerequisites baseline) but the file is still fully written before the exit.

```bash
podman rm -f test-registry
```

- [ ] **Step 5: Commit**

```bash
git add mise/tasks/push .gitignore
git commit -m "feat(push): emit image/SBOM/vuln digests for cosign signing (#60)"
```

---

## Task 3: Add `mise/tasks/sign` (cosign keyless signing)

**Files:**
- Create: `mise/tasks/sign`

**Interfaces:**
- Consumes: `krytis-push-digests.env` (or explicit `--image-digest`/`--sbom-digest`/`--vuln-digest` flags) as written by Task 2's `mise/tasks/push`
- Produces: nothing on disk — signs in place on the registry (Sigstore transparency log entries + `.sig` OCI referrers on `ghcr.io/starlit-os/krytis`)

**Issue:** #60 (referenced from #380)

- [ ] **Step 1: Create the task**

```bash
#!/usr/bin/env bash
#MISE description="Sign the published krytis image + OCI referrers with cosign keyless/OIDC (#60)"
#USAGE flag "--registry <registry>" default="ghcr.io/starlit-os/krytis" help="Registry and image path the signed artifacts live under"
#USAGE flag "--digest-file <path>" default="krytis-push-digests.env" help="Digest file written by mise run push — read image_digest/sbom_digest/vuln_digest from here when the flags below are not given"
#USAGE flag "--image-digest <digest>" help="sha256 digest of the pushed image manifest — required unless present in --digest-file"
#USAGE flag "--sbom-digest <digest>" help="sha256 digest of the attached SBOM OCI referrer manifest — signed if given or present in --digest-file"
#USAGE flag "--vuln-digest <digest>" help="sha256 digest of the attached vulnerability report OCI referrer manifest — signed if given or present in --digest-file"

# Cosign keyless (OIDC) signing (#60). In GitHub Actions, cosign detects the
# Actions OIDC token ambiently (the job needs `id-token: write`; no explicit
# token wiring here) and signs via Sigstore's public Fulcio (cert issuance)
# and Rekor (transparency log) instances — no signing key ever stored in
# this repo or as a secret. Locally (no GHA ambient credential), cosign
# falls back to an interactive browser-based Sigstore OIDC login: usable,
# but the CI path is the intended primary use per #380.
set -euo pipefail

REGISTRY="${usage_registry:-ghcr.io/starlit-os/krytis}"
DIGEST_FILE="${usage_digest_file:-krytis-push-digests.env}"
IMAGE_DIGEST="${usage_image_digest:-}"
SBOM_DIGEST="${usage_sbom_digest:-}"
VULN_DIGEST="${usage_vuln_digest:-}"

if [[ -f "$DIGEST_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DIGEST_FILE"
    : "${IMAGE_DIGEST:=${image_digest:-}}"
    : "${SBOM_DIGEST:=${sbom_digest:-}}"
    : "${VULN_DIGEST:=${vuln_digest:-}}"
fi

if [[ -z "$IMAGE_DIGEST" ]]; then
    echo "==> ERROR: no image digest given (--image-digest, or image_digest in ${DIGEST_FILE}) — run mise run push first" >&2
    exit 1
fi

# Same GITHUB_TOKEN/gh-auth-token resolution as mise/tasks/push, so this
# task is independently runnable (does not depend on push's oras/podman
# login side effects surviving in the same shell/job).
TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "token")

echo "==> Logging in to ghcr.io as ${GH_USER} (cosign)..."
echo "$TOKEN" | cosign login ghcr.io --username "$GH_USER" --password-stdin

sign_ref() {
    local label="$1" digest="$2"
    echo "==> Signing ${label} (${REGISTRY}@${digest})..."
    cosign sign -y "${REGISTRY}@${digest}"
    echo "==> Signed ${label}"
}

sign_ref "image" "$IMAGE_DIGEST"
[[ -n "$SBOM_DIGEST" ]] && sign_ref "SBOM" "$SBOM_DIGEST"
[[ -n "$VULN_DIGEST" ]] && sign_ref "vulnerability report" "$VULN_DIGEST"

echo "==> Done signing ${REGISTRY}@${IMAGE_DIGEST} and its OCI referrers"
```

- [ ] **Step 2: `chmod +x`**

```bash
chmod +x mise/tasks/sign
```

- [ ] **Step 3: Verify with `bash -n` and `mise tasks`**

```bash
bash -n mise/tasks/sign
mise tasks | grep sign
```
Expected: no syntax errors; `sign` appears with its description.

- [ ] **Step 4: End-to-end local verification against a local test registry**

Cosign keyless requires a real Sigstore OIDC identity — a local test registry still works for the push/attach/verify mechanics, but keyless signing itself needs either GHA ambient credentials or an interactive browser login. Verify the non-OIDC-dependent parts locally:

```bash
# From Task 2's Step 4 local-registry smoke test, krytis-push-digests.env exists.
cosign login localhost:5000 --username test --password test 2>&1 || true  # confirms the CLI/flag surface parses
mise run sign --registry localhost:5000/krytis --digest-file krytis-push-digests.env
```
Expected: reaches the `cosign sign -y` calls (may fail on OIDC identity resolution against `localhost:5000` in a sandboxed environment with no browser — capture and note the exact failure point; the digest-resolution and flag-parsing logic above it must succeed). Full keyless verification happens for real in Task 6 once the workflow runs in GitHub Actions (ambient OIDC available there).

- [ ] **Step 5: Commit**

```bash
git add mise/tasks/sign
git commit -m "feat(sign): add cosign keyless signing task (#60)"
```

---

## Task 4: Update `docs/skills/sbom.md` and add `docs/skills/signing.md`

**Files:**
- Modify: `docs/skills/sbom.md:55` (the stale "#60 not implemented" paragraph)
- Create: `docs/skills/signing.md`
- Modify: `docs/SKILL.md:22` (index — add a row)

**Interfaces:** none (documentation only)

- [ ] **Step 1: Fix the stale line in `docs/skills/sbom.md`**

Current line 55:

```markdown
**Signing is explicitly out of scope here** — tracked separately in #60 (cosign keyless signing), not implemented yet. The SBOM (and the image) are attached/pushed unsigned. Do not add cosign steps to this SBOM flow without checking #60 first; wire signing into whatever `mise run push`/CI mechanism #60 lands, not by extending `mise/tasks/sbom`.
```

Replace with:

```markdown
**Signing is handled separately** — `mise run sign` (#60, see `docs/skills/signing.md`) signs the pushed image and both OCI referrers by digest after `mise run push` completes. Deliberately not built into `mise/tasks/sbom`/`mise/tasks/push` directly: signing needs the three manifest digests `push` already writes to `krytis-push-digests.env`, and keeping it a separate task lets it be best-effort (`.github/workflows/publish.yml` runs it with `continue-on-error: true`) without coupling its failure mode to the SBOM/scan pipeline's.
```

- [ ] **Step 2: Create `docs/skills/signing.md`**

```markdown
# Cosign Keyless Signing

Load when working on `mise run sign`, `.github/workflows/publish.yml`, or anything touching cosign/Sigstore/OIDC in krytis. Implements #60.

## What It Is

`mise run sign` signs the published `oci/krytis/image.bst` image and both of its OCI referrers (SBOM from #40, Grype vulnerability report from #41) using [cosign](https://github.com/sigstore/cosign) **keyless** signing: no private key is generated, stored, or rotated. Each `cosign sign -y <ref>@<digest>` call requests a short-lived code-signing certificate from Sigstore's public Fulcio CA, bound to an OIDC identity, and records the signature in Sigstore's public Rekor transparency log.

## Digest Hand-off from `mise run push`

`mise/tasks/push` writes `krytis-push-digests.env` (gitignored, transient) with up to three `KEY=VALUE` lines:

```
image_digest=sha256:...
sbom_digest=sha256:...
vuln_digest=sha256:...
```

`sbom_digest`/`vuln_digest` are only present when the corresponding `push` step actually ran (absent if `--skip-sbom`/`--skip-vuln-scan` was passed). `mise run sign` reads this file by default (`--digest-file`, default `krytis-push-digests.env`) — a human running both commands from the same shell in the same directory needs no extra flags:

```bash
mise run push --fail-on critical
mise run sign
```

`--image-digest`/`--sbom-digest`/`--vuln-digest` flags override the file for scripted/CI use (also useful for re-signing a specific historical digest without re-running `push`).

## Why Signing Isn't Wired Into `mise/tasks/push`/`mise/tasks/sbom` Directly

Two independent reasons, both from #380's design decisions:

1. **Severity-gate independence.** `mise run push --fail-on critical` can legitimately `exit 1` (Critical vulnerability found) *after* the image and both referrers already exist on the registry — the push already happened, only the exit code changed. Signing should still run in that case (the artifacts exist and are worth signing regardless of the scan outcome) — a separate task/step makes that trivial: `mise run sign` runs `if: always()` in CI regardless of the previous step's exit code, because it only depends on files being on disk, not the previous step's success.
2. **Best-effort semantics.** #380's design decision: signing does not block promotion (`continue-on-error: true` in CI, matching dakota's `publish-sbom` job pattern). Keeping it a separate task means a signing failure (e.g. a transient Fulcio/Rekor outage) can't accidentally propagate into `push`'s exit code and be conflated with an actual severity-gate failure.

## GitHub Actions OIDC (Ambient Credential Detection)

cosign auto-detects a GitHub Actions run via the `ACTIONS_ID_TOKEN_REQUEST_URL`/`ACTIONS_ID_TOKEN_REQUEST_TOKEN` environment variables GitHub injects into any job with the `id-token: write` permission — no explicit token-fetching step is needed in the workflow. `.github/workflows/publish.yml`'s job declares:

```yaml
permissions:
  contents: read
  packages: write
  id-token: write
```

Locally (no ambient GHA credential), `cosign sign -y` falls back to an interactive browser-based Sigstore OIDC login. This works but is a materially worse experience than running from CI (no browser in most CI-like sandboxes, and every invocation needs a fresh login) — CI is the intended primary path per #380's issue body.

## Verifying a Signature

```bash
cosign verify \
  --certificate-identity-regexp '^https://github\.com/starlit-os/krytis/\.github/workflows/publish\.yml@refs/heads/.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/starlit-os/krytis@<digest>
```

The `--certificate-identity-regexp` constrains verification to signatures produced specifically by `publish.yml` running in `starlit-os/krytis` — without it, `cosign verify` would accept a signature from *any* Sigstore-issued identity, which defeats the point of checking provenance.

## `cosign login` vs. relying on `oras`/`podman` login side effects

`mise/tasks/sign` calls `cosign login ghcr.io` itself rather than assuming `mise/tasks/push`'s earlier `oras login`/`podman login` calls already populated a credential store cosign will read. `cosign` follows the same Docker-config-file (`~/.docker/config.json`) convention as `oras`, so in practice the credentials would already be there after a `push --skip-sbom=false` run — but `mise run sign` is designed to be independently runnable (e.g. re-signing an old digest without re-running `push`, or `--skip-sbom` was passed to `push`), so it does not depend on that side effect.
```

- [ ] **Step 3: Add the `docs/SKILL.md` index row**

Current `docs/SKILL.md:22`:

```markdown
| Generate/attach the SBOM or run the Grype vuln scan (`mise run sbom`, `mise run vuln-scan`, `mise run push`) | [`docs/skills/sbom.md`](skills/sbom.md) |
```

Add immediately after:

```markdown
| Sign the published image/SBOM/vuln report with cosign, or work on the publish workflow (`mise run sign`, `.github/workflows/publish.yml`) | [`docs/skills/signing.md`](skills/signing.md) |
```

- [ ] **Step 4: Commit**

```bash
git add docs/skills/sbom.md docs/skills/signing.md docs/SKILL.md
git commit -m "docs(signing): document cosign keyless signing and digest hand-off (#60)"
```

---

## Task 5: Create `.github/workflows/publish.yml`

**Files:**
- Create: `.github/workflows/publish.yml`

**Interfaces:**
- Consumes: `mise run build --pull`, `mise run push --fail-on critical` (or no flag when `report_only`), `mise run sign` — all from Tasks 1–3
- Produces: a pushed, scanned, and (best-effort) signed `ghcr.io/starlit-os/krytis` image on every manual dispatch

**Severity threshold rationale (evidence, not assumption):** the Prerequisites baseline shows 5 Critical / 69 High / 40 Medium / 11 Low across 125 total matches on the current image. Defaulting the blocking threshold to `high` would make nearly every dispatch fail immediately (69 matches, many via Grype's unscoped CPE fallback per `docs/skills/sbom.md`'s documented false-positive risk for non-purl-enriched packages) — not yet a meaningfully triaged gate. `critical` (5 matches) is small enough to triage individually and is the threshold this plan uses; revisit once the 5 current Criticals are triaged (fixed, upgraded, or explicitly accepted).

- [ ] **Step 1: Create the workflow file**

```yaml
name: Publish krytis image

on:
  workflow_dispatch:
    inputs:
      report_only:
        description: 'Report vulnerabilities without blocking the run (default: block on Critical)'
        type: boolean
        default: false

permissions:
  contents: read
  packages: write
  id-token: write

concurrency:
  group: krytis-publish
  cancel-in-progress: false

jobs:
  publish:
    # Blacksmith to start (#380) — no self-hosted fallback input yet. If
    # Blacksmith proves unfeasible (disk/time), swap this to
    # ["self-hosted","linux","x64"] (docs/skills/ci-runner.md); nothing
    # else in this job is Blacksmith-specific.
    runs-on: blacksmith-8vcpu-ubuntu-2404
    timeout-minutes: 420
    steps:
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7

      - name: Maximize build space
        uses: ublue-os/remove-unwanted-software@695eb75bc387dbcd9685a8e72d23439d8686cba6 # v10
        with:
          remove-dotnet: "true"
          remove-android: "true"
          remove-haskell: "true"
          remove-codeql: "true"

      - name: Setup mise
        uses: jdx/mise-action@9e7f7633ff6f6d6048a9418a68d48f288f50eb14 # v4.2.3
        with:
          experimental: true

      - name: Install system dependencies
        run: mise bootstrap --yes

      - name: Install Python dependencies
        run: uv sync

      - name: Enable unprivileged user namespaces
        run: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true

      - name: Build oci/krytis/image.bst
        env:
          BUILDBARN_PULL_TOKEN: ${{ secrets.BUILDBARN_PULL_TOKEN }}
        run: mise run build --pull

      - name: Push, attach SBOM + vulnerability report
        id: push
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if [[ "${{ inputs.report_only }}" == "true" ]]; then
            echo "::notice::report_only=true — vulnerability scan will not block this run"
            mise run push
          else
            mise run push --fail-on critical
          fi

      - name: Sign image and referrers with cosign (best-effort)
        # Runs regardless of whether the severity gate above tripped — the
        # image and referrers already exist on the registry by then.
        # continue-on-error: signing failure never fails this job (#380
        # design decision: parallel/best-effort, matching dakota's
        # publish-sbom job).
        if: always()
        continue-on-error: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: mise run sign

      - name: Verify signature (diagnostic, non-blocking)
        if: always()
        continue-on-error: true
        run: |
          if [[ -f krytis-push-digests.env ]]; then
            # shellcheck disable=SC1091
            source krytis-push-digests.env
            cosign verify \
              --certificate-identity-regexp "^https://github.com/${{ github.repository }}/.github/workflows/publish.yml@refs/heads/.*\$" \
              --certificate-oidc-issuer https://token.actions.githubusercontent.com \
              "ghcr.io/starlit-os/krytis@${image_digest}"
          else
            echo "::warning::krytis-push-digests.env missing — push step likely failed before writing it"
          fi

      - name: Report severity gate outcome
        if: always()
        run: |
          if [[ "${{ steps.push.outcome }}" == "success" ]]; then
            echo "::notice::Publish succeeded (severity gate: $([[ '${{ inputs.report_only }}' == 'true' ]] && echo 'report-only' || echo 'blocking at Critical'))"
          else
            echo "::error::Publish step failed — see logs above (severity gate breach, or an earlier build/push failure)"
            exit 1
          fi
```

- [ ] **Step 2: Confirm no new action allowlist entries are needed**

Every `uses:` in this workflow (`actions/checkout`, `ublue-os/remove-unwanted-software`, `jdx/mise-action`) is already used in `.github/workflows/cache-warm.yml`/`track-bst-sources.yml` and therefore already on the `starlit-os` org allowlist — `cosign`/`oras`/`grype` are installed via `mise install` (already declared in `mise.toml`), not separate GitHub Actions, so no new allowlist request is needed for this PR.

- [ ] **Step 3: Lint the workflow**

```bash
mise lint
```
Expected: passes; `actionlint` (run as part of `mise lint`) reports no errors on the new workflow file and auto-pins any floating action tags to full commit SHAs with version comments (they're already written as full SHAs above, so this should be a no-op — confirm by diffing `git diff .github/workflows/publish.yml` before/after `mise lint`).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/publish.yml
git commit -m "feat(ci): add manual publish workflow — build, push, scan, sign (#380, #60)"
```

---

## Task 6: Dispatch and verify a real run

**Files:** none (verification only)

- [ ] **Step 1: Push the branch and dispatch the workflow**

```bash
git push -u origin 380-add-ci-image-publish-workflow
gh workflow run publish.yml --ref 380-add-ci-image-publish-workflow -f report_only=true
```

Use `report_only=true` for the first real run — confirms the full pipeline (build → push → SBOM attach → vuln-scan attach → sign → verify) works end to end without the known 5 Critical findings aborting it mid-plan-execution.

- [ ] **Step 2: Watch the run**

```bash
gh run watch --exit-status
```
Expected: all steps green except possibly "Sign image and referrers" / "Verify signature" if OIDC/Fulcio has a transient issue (both are `continue-on-error: true`, so the job overall still succeeds) — capture the run URL either way.

- [ ] **Step 3: Verify the signature independently (outside the workflow)**

```bash
gh run view --json databaseId --jq .databaseId   # note the run ID for the identity regexp check below
DIGEST=$(gh api repos/starlit-os/krytis/actions/runs/<run-id>/jobs --jq '.jobs[0]' | true)  # or read from workflow logs directly
cosign verify \
  --certificate-identity-regexp '^https://github\.com/starlit-os/krytis/\.github/workflows/publish\.yml@refs/heads/.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/starlit-os/krytis@<image_digest-from-run-logs>
```
Expected: `Verification for ghcr.io/starlit-os/krytis@sha256:...` with a matching certificate identity printed — this is the literal evidence for the AC "Image + both referrers are signed with cosign keyless (OIDC) — verifiable via cosign verify."

- [ ] **Step 4: Dispatch a second, blocking run to confirm the default gate actually blocks**

```bash
gh workflow run publish.yml --ref 380-add-ci-image-publish-workflow -f report_only=false
gh run watch --exit-status
```
Expected: the "Push, attach SBOM + vulnerability report" step fails (`GRYPE_EXIT=2` → `mise run push` exits 1) given the 5 known Critical findings from the Prerequisites baseline; "Sign image and referrers" and "Verify signature" still run and succeed (they're `if: always()`); the final "Report severity gate outcome" step surfaces `::error::` and the job is red overall. This is the literal evidence that the default (`report_only=false`) gate blocks as designed.

- [ ] **Step 5: Link both run URLs as evidence in the PR** (AGENTS.md Verification mandate — "Every PR must confirm `mise lint` passed and the image booted" plus "Link to a CI run... that exercises your change")

---

## Self-Review Checklist (confirm before opening the PR)

- [ ] Acceptance criterion "builds and pushes `oci/krytis/image.bst`" — Task 5 Step 1 (`mise run build --pull` + `mise run push`)
- [ ] Acceptance criterion "SBOM and vulnerability report attached as OCI referrers" — already implemented by #40/#41's `mise/tasks/push`, unchanged by this plan except digest capture (Task 2)
- [ ] Acceptance criterion "signed with cosign keyless (OIDC) — verifiable via `cosign verify`" — Tasks 1, 3, 5; verified for real in Task 6 Step 3
- [ ] Acceptance criterion "workflow run linked as evidence" — Task 6 Step 5
- [ ] Acceptance criterion "`docs/skills/` updated" — Task 4 (new `signing.md`, `sbom.md` correction, `SKILL.md` index)
- [ ] Design Gate answers from this conversation are reflected verbatim: manual-only trigger (Task 5), Blacksmith runner with a documented self-hosted escape hatch (Task 5), blocking-by-default severity gate with a `report_only` boolean (Task 5), parallel/best-effort signing via `if: always()` + `continue-on-error: true` (Task 5)
- [ ] No placeholders — every task above has complete, runnable code, not a sketch
- [ ] `mise/tasks/sign`'s flag names (`--image-digest`, `--sbom-digest`, `--vuln-digest`, `--digest-file`, `--registry`) match exactly between Task 3's implementation and every caller in Task 5/Task 6
