# Host ISO Downloads via Cloudflare R2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the sealed ISO that `build-iso.yml` (#844/#861/#862) builds to a stable, publicly reachable URL — `https://iso.ririi.dev/krytis-live-sealed.iso` — via Cloudflare R2, instead of only as a 7-day GitHub Actions artifact behind GitHub auth. Closes #867.

**Architecture:** A new Cloudflare R2 bucket (`krytis-iso`) holds exactly two objects, both overwritten in place on every successful publish run: `krytis-live-sealed.iso` and `krytis-live-sealed.iso.sha256`. The bucket is bound to a Cloudflare-managed Custom Domain (`iso.ririi.dev`), which terminates TLS and fronts the bucket with Cloudflare's CDN — R2 has **zero egress fees**, which is the entire reason this is R2 and not S3/GCS for a multi-GB file downloaded repeatedly. `build-iso.yml` uploads via `rclone` (Cloudflare's own documented R2 tool) using a fully environment-variable-configured S3-compatible remote — no config file, no secret ever touches disk on the runner beyond process environment. Upload is gated behind a new `publish_r2` boolean input, independent of `sealed`, so a sealed test dispatch doesn't have to touch the public "latest" object.

**Decisions already made (2026-09-16, via `ask` during planning):**
- Domain: `iso.ririi.dev` — reuses the existing `ririi.dev` zone (already fronts `bst-cache.ririi.dev` for bow).
- Scope: **sealed ISO only.** The unsealed build stays a GH Actions artifact for internal testing; it is never uploaded to R2 or exposed publicly. Publishing an unsigned/non-Secure-Boot image at a "download Krytis here" URL would be a trust-model footgun.
- Versioning: **latest only.** One stable, overwritten object — no dated archive. See the Known Limitation note in Task 4 for the tradeoff this implies and the deferred fix if it ever matters.

**Tech Stack:** Cloudflare R2 (S3-compatible object storage), Cloudflare Custom Domains for R2, `rclone`, GitHub Actions secrets, `build-iso.yml` (this repo), `provision.sh` (VPS runner).

## Global Constraints

- R2 credentials are a scoped API token — **Object Read & Write, scoped to the `krytis-iso` bucket only**, never an account-wide token and never `Admin Read & Write` (which can create and delete buckets). Bucket scoping is a step *inside* the account-level token flow, not a separate bucket-scoped panel — see Task 1 Step 3.
- Secrets (`R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) are GitHub Actions repo secrets, matching the `TRACKING_APP_*` precedent (#699/#793) for CI-only credentials with no local-dev use case — not Proton Pass/fnox, which this repo reserves for credentials a human also needs locally (signing keys, Buildbarn tokens, the VPS SSH host). Bucket name (`krytis-iso`) is not sensitive and is hardcoded in the workflow, not a secret.
- `publish_r2: true` with `sealed: false` must fail the job loudly at the top, before any build work — there is no unsealed-to-R2 path, ever (see Scope decision above).
- `rclone` runs with credentials passed as `RCLONE_CONFIG_*` environment variables scoped to the single upload step — no `rclone.conf` file written to the runner's persistent disk.
- No new `uses:` GitHub Action is introduced — `rclone` is a `run:` shell step after an apt install, so this plan does not touch the org's external-action allowlist (docs/skills/ci-runner.md § Org allowlist).
- This is additive to `build-iso.yml` (#861) — no existing step's behavior changes when `publish_r2` is omitted/false (the default).

---

### Task 1: Create the R2 bucket and scoped API token — human, Security Gate

Per AGENTS.md, provisioning auth/secrets is a human decision point. Do this in the Cloudflare dashboard, not via an agent.

**Files:** none — this is entirely in the Cloudflare dashboard.

- [x] **Step 1: Enable R2 on the Cloudflare account** (if not already)

Dashboard → R2 → follow the enablement flow. R2 requires a payment method on file even though a single ~3-5GB ISO overwritten in place costs well under R2's free tier (10GB-month storage, 1M Class A / 10M Class B ops free) — actual spend should round to $0.

- [x] **Step 2: Create the bucket**

R2 → Create bucket → name `krytis-iso` → Location: Automatic → Storage class: Standard.

Then, on the new bucket: Settings → **Object lifecycle rules** → Create rule → *Abort incomplete multipart uploads* after **1 day**, applied to the whole bucket (no prefix filter).

This is the one way the "one ISO at a time" assumption can silently stop holding. R2's free tier is 10 GB-month billed as the monthly average of each day's *peak* storage, and a 4.5 GB ISO (`docs/design/secure-boot-testing.md`) leaves roughly 2x headroom — a publish briefly peaks near 9 GB (old object still live while the new upload's parts accumulate) and that spike costs 9/30 = 0.3 GB-month, which is nothing. But **unfinished multipart uploads are billed as storage and do not appear in the bucket's object listing.** A cancelled workflow run or a dead runner leaves ~4.5 GB of orphaned parts behind forever; the bucket still shows exactly two objects while storage climbs per failed run. `AbortMultipartUpload` is a free operation, so the lifecycle rule costs nothing to run.

- [x] **Step 3: Create a bucket-scoped API token**

R2 Object Storage → **Overview** ([direct link](https://dash.cloudflare.com/?to=/:account/r2/overview)) → **Account Details** panel → **API Tokens** → **Manage** → **Create Account API token** → Permissions: **Object Read & Write** → a bucket selector unfolds once that permission is chosen: select **`krytis-iso`** (not "all buckets") → Create.

**This is not the bucket's own settings page.** An earlier revision of this plan sent the reader to a per-bucket "Manage API tokens" panel; that panel is gone from the dashboard, and scoping now lives at step 5 of the account-level flow instead (Cloudflare's own docs at `developers.cloudflare.com/r2/api/tokens/`, as of their 2026-08-18 revision, document only the account flow). The *intent* of the original instruction still holds exactly — the token must not be all-buckets — the UI location for satisfying it moved.

Choose **Account** API token, not **User** API token. A user token is tied to your individual Cloudflare user, inherits your personal permissions, and goes inactive if that user is ever removed from the account — unacceptable for a credential CI depends on. Account tokens stay valid until manually revoked and require the Super Administrator role to create or view.

`Object Read & Write` is supported by the S3-compatible API only, not Cloudflare's REST API. That is the correct choice here: `rclone` speaks S3 to `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

Record the three values shown **once**: Access Key ID, Secret Access Key, and the Account ID (also visible in the dashboard sidebar / any existing R2 endpoint URL, format `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`).

- [x] **Step 4: Provision as GitHub Actions secrets**

```bash
gh secret set R2_ACCOUNT_ID --repo starlit-os/krytis --body "<Account ID from Step 3>"
gh secret set R2_ACCESS_KEY_ID --repo starlit-os/krytis --body "<Access Key ID from Step 3>"
gh secret set R2_SECRET_ACCESS_KEY --repo starlit-os/krytis --body "<Secret Access Key from Step 3>"
```

- [x] **Step 5: Verify (names only — GitHub never returns secret values)** — confirmed 2026-09-24: all three present, set 09:37–09:38.

```bash
gh secret list --repo starlit-os/krytis
```

Expected: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` all listed.

### Task 2: Bind the custom domain — human, Security/Design Gate (external DNS)

**Files:** none — Cloudflare dashboard only.

- [x] **Step 1: Confirm `ririi.dev` is on Cloudflare DNS** — done 2026-09-24: `austin.ns.cloudflare.com`, `tara.ns.cloudflare.com`. The zone is Cloudflare-managed, so the blocking branch below does not apply.

```bash
dig NS ririi.dev +short
```

Expected: Cloudflare nameservers (`*.ns.cloudflare.com`). `bst-cache.ririi.dev` already resolves for bow, but confirm rather than assume — that record could in principle be a plain CNAME/A record on a non-Cloudflare DNS provider with TLS terminated by materia's own reverse proxy, which would NOT satisfy R2 Custom Domain's requirement that Cloudflare manage the zone. If the zone is not on Cloudflare, this task blocks on adding it there first (out of scope for this plan — coordinate with whoever owns `ririi.dev`'s registrar/DNS, likely via the `materia` repo/infra, before continuing).

- [x] **Step 2: Connect the custom domain to the bucket**

R2 → `krytis-iso` bucket → Settings → **Custom Domains** → Connect Domain → `iso.ririi.dev` → Continue. Cloudflare auto-creates the proxied CNAME record in the zone and issues a managed TLS certificate.

- [x] **Step 3: Wait for Active status** — verified from outside the dashboard 2026-09-24: `iso.ririi.dev` now resolves to Cloudflare anycast (`172.67.130.180`, `104.21.3.126`), not materia's `46.62.242.208`, and returns `HTTP/2 404` with `server: cloudflare` — the correct response for a bucket with nothing published yet. Control: `nonexistent-probe-8712.ririi.dev` now fails TLS outright, since materia holds no certificate for it, which is what distinguishes a real Custom Domain from the wildcard that previously answered here.

The custom domain's status shows "Initializing" → "Active" (usually under a few minutes since the zone is already on Cloudflare — no external DNS propagation wait). Do not proceed to Task 6 until it reads Active.

**While waiting, the dashboard status is the only valid readiness signal — do not substitute `dig` or `curl`.** The `ririi.dev` zone carries a wildcard `*.ririi.dev` A record pointing at materia (`46.62.242.208`), verified 2026-09-24 by resolving a name that cannot exist: `nonexistent-probe-8712.ririi.dev` returned that same address. So `iso.ririi.dev` already resolved, and already answered requests, before this bucket existed. A 200 during the wait proves nothing.

*After* the cutover, DNS does become a valid confirmation — the name resolves to Cloudflare anycast instead of materia, as Step 3 records — but that is a post-hoc check, not a way to tell "not ready yet" from "ready". Both look alike from outside until the switch actually happens.

- [x] **Step 4: Add a Cache Rule for edge caching**

R2 serves the origin correctly without this, but a multi-GB file repeatedly downloaded by users worldwide benefits from Cloudflare's edge cache, not just R2's zero-egress-to-Cloudflare pricing. Dashboard → `ririi.dev` zone → **Caching** → **Cache Rules** → Create rule ([direct link](https://dash.cloudflare.com/?to=/:account/:zone/caching/cache-rules)). Not `Rules` → `Cache Rules`, which is where an earlier revision of this step sent the reader.
- When incoming requests match: **Custom filter expression**, Hostname equals `iso.ririi.dev`. Not "All incoming requests" — that would apply the rule to the whole zone, including everything the `*.ririi.dev` wildcard serves from materia.
- Then: Cache eligibility = **Eligible for cache**; Edge TTL = **"Use cache-control header if present, use default Cloudflare caching behavior if not"**.

That Edge TTL wording is the UI label; **"Respect origin TTL"**, which this step said previously, is the *API* value (`respect_origin`) and appears nowhere in the dropdown. The intent is unchanged — defer to the `Cache-Control: public, max-age=3600, must-revalidate` header Task 4's upload sets, so there is no second TTL to keep in sync by hand. Take care not to pick the adjacent **"Use cache control-header if present, bypass cache if not"**: it reads almost identically and skips caching entirely for any response without the header.

At Deploy, Cloudflare may offer to create a proxied DNS record for the hostname in the expression. Seeing that prompt means Step 2 has not been done — go connect the Custom Domain rather than hand-creating the record here.

### Task 3: Provision `rclone` on the VPS runner — agent

**Files:**
- Modify: `files/runner-vps/provision.sh`

Mirrors the `squashfs-tools`/`mtools`/`dosfstools` addition in #861 — same file, same `apt-get install` line, same "whatever Debian trixie's apt carries is fine" reasoning.

**Correction to that reasoning:** there *is* a version floor, unlike the rest of that package list. The `provider = Cloudflare` value Task 4 sets was added in rclone **v1.59.0** (2022-07-09, "New S3 providers" in the upstream changelog). Trixie ships **1.60.1**, which clears it — verified on the live box after Step 2 — so the conclusion holds, but "no known floor" was wrong and an older base image would have broken quietly: an unrecognised provider value degrades to generic-S3 behaviour rather than failing loudly.

- [x] **Step 1: Add `rclone` to the package list**

```diff
     podman \
     squashfs-tools \
     mtools \
-    dosfstools
+    dosfstools \
+    rclone
```

- [x] **Step 2: Re-run provisioning against the live VPS** — done 2026-09-24, `rclone 1.60.1+dfsg-4` newly installed; swap and runner binary steps correctly skipped as already-present (the script is idempotent).

```bash
mise run runner-vps:install
```

FIDO2 resident key required (touch, sometimes PIN — retry on failure per the standing instruction: pause and ask the operator to stay ready after two consecutive failures rather than silently retrying a third time).

- [x] **Step 3: Verify** — `/usr/bin/rclone`, `rclone v1.60.1-DEV`, debian 13.7.

```bash
. scripts/runner-vps-host.sh && ssh_vps 'command -v rclone && rclone version'
```

Expected: a path under `/usr/bin/rclone` and a version banner.

- [x] **Step 4: Commit** — `c523e78`

```bash
git add files/runner-vps/provision.sh
git commit -m "ci(runner-vps): add rclone for R2 ISO uploads

Part of #867. Same pattern as squashfs-tools/mtools/dosfstools
(#861/#844): host tool the VPS runner needs that no prior workflow
required."
```

### Task 4: Wire the R2 upload into `build-iso.yml` — agent

**Files:**
- Modify: `.github/workflows/build-iso.yml`

- [x] **Step 1: Add the `publish_r2` input**

In the `workflow_dispatch.inputs` block, after `sealed`:

```yaml
      publish_r2:
        description: 'Upload the sealed ISO to Cloudflare R2 as the public "latest" download (iso.ririi.dev) — only valid with sealed=true (#867)'
        type: boolean
        default: false
```

- [x] **Step 2: Gate the invalid combination at the top of the job**

New first step, before "Checkout repository":

```yaml
      - name: Reject publish_r2 without sealed
        if: ${{ inputs.publish_r2 && !inputs.sealed }}
        run: |
          echo "::error::publish_r2=true requires sealed=true — there is no unsealed-to-R2 publish path (#867)."
          exit 1
```

- [x] **Step 3: Add the upload step after "Build ISO", before "Print disk usage after build"**

```yaml
      - name: Publish sealed ISO to R2
        if: ${{ inputs.sealed && inputs.publish_r2 }}
        env:
          RCLONE_CONFIG_R2_TYPE: s3
          RCLONE_CONFIG_R2_PROVIDER: Cloudflare
          RCLONE_CONFIG_R2_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          RCLONE_CONFIG_R2_ENDPOINT: https://${{ secrets.R2_ACCOUNT_ID }}.r2.cloudflarestorage.com
          RCLONE_CONFIG_R2_REGION: auto
        run: |
          ISO=output/krytis-live-sealed.iso
          sha256sum "${ISO}" | awk '{print $1}' > "${ISO}.sha256"

          echo "==> Uploading ${ISO} to r2://krytis-iso/krytis-live-sealed.iso..."
          rclone copyto "${ISO}" r2:krytis-iso/krytis-live-sealed.iso \
            --header-upload "Content-Type: application/x-iso9660-image" \
            --header-upload "Cache-Control: public, max-age=3600, must-revalidate" \
            --progress

          echo "==> Uploading checksum..."
          rclone copyto "${ISO}.sha256" r2:krytis-iso/krytis-live-sealed.iso.sha256 \
            --header-upload "Content-Type: text/plain" \
            --header-upload "Cache-Control: public, max-age=3600, must-revalidate"

      - name: Verify the public download
        if: ${{ inputs.sealed && inputs.publish_r2 }}
        run: |
          LOCAL_SIZE=$(stat -c%s output/krytis-live-sealed.iso)
          REMOTE_SIZE=$(curl -sI https://iso.ririi.dev/krytis-live-sealed.iso | awk 'BEGIN{IGNORECASE=1} /^content-length:/{print $2}' | tr -d '\r')
          echo "local=${LOCAL_SIZE} remote=${REMOTE_SIZE}"
          [ "${LOCAL_SIZE}" = "${REMOTE_SIZE}" ] || { echo "::error::Published object size does not match the built ISO — upload may have been served from stale edge cache or truncated." >&2; exit 1; }

          REMOTE_SHA=$(curl -sL https://iso.ririi.dev/krytis-live-sealed.iso.sha256)
          LOCAL_SHA=$(cat output/krytis-live-sealed.iso.sha256)
          [ "${REMOTE_SHA}" = "${LOCAL_SHA}" ] || { echo "::error::Published checksum does not match the built ISO." >&2; exit 1; }
          echo "==> iso.ririi.dev serves the ISO this run built (size + checksum both match)."
```

**Known limitation, deliberately not engineered around for this "latest only" MVP:** the upload is a plain object overwrite, not atomic-swap-via-new-key-then-redirect. A client mid-download across a very long-lived connection (or one that re-issues HTTP Range requests without `If-Range`) during the brief window of a new publish could theoretically mix bytes from two builds. Mitigated today by the `.sha256` file every download should be checked against (the ISO also carries an embedded `implantisomd5` checksum, checkable from the boot menu) — not eliminated. If this ever bites in practice, the fix is: upload to a content-addressed key (e g. `builds/<sha256>.iso`), then flip `krytis-live-sealed.iso` to a 302 redirect (Cloudflare Bulk Redirect or a tiny Worker) — deferred, not built now, since the "latest only" decision was made explicitly to avoid this complexity for v1.

- [x] **Step 4: Validate YAML**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/build-iso.yml'))
inputs = d[True]['workflow_dispatch']['inputs']
assert 'publish_r2' in inputs, 'publish_r2 input missing'
print('YAML OK, inputs:', list(inputs.keys()))
"
```

Expected: `YAML OK, inputs: ['compression', 'sealed', 'publish_r2']`.

- [x] **Step 5: Commit** — `b206c2d`

```bash
git add .github/workflows/build-iso.yml
git commit -m "feat(ci): publish sealed ISO to R2 (#867)

Adds a publish_r2 workflow_dispatch input, independent of sealed, so
a sealed test dispatch does not have to touch the public latest
object. Uploads via rclone with a fully env-var-configured S3
remote -- no config file, no secret written to disk. A same-run
verification step confirms iso.ririi.dev serves an object matching
this build's size and checksum before the job is considered green."
```

- [x] **Step 6: Stop uploading an ISO artifact when the run published one** (added 2026-09-24, after the plan was written)

The original plan left the `Upload ISO artifact` step untouched, so a publishing run produced the ISO twice: once at `iso.ririi.dev` and once as a 4.5 GB Actions artifact billed against repo storage for seven days, of a file anyone can now fetch anonymously. The step is now conditional:

```yaml
        if: ${{ !(inputs.sealed && inputs.publish_r2) || failure() }}
```

Scope is narrower than "no ISO artifacts": unsealed builds and sealed dispatches with `publish_r2=false` still upload, because neither has another route off the runner and #867's recorded scope decision keeps the unsealed artifact for internal testing.

The `|| failure()` clause is the part worth remembering. GitHub steps run on success by default, so the skip condition on its own would also throw the ISO away when the *upload* or the public-download check failed — the one case where a 4.5 GB build artifact is most valuable, since the next run's `git clean -ffdx` wipes `output/` before a retry could reuse it. With the clause, a failed publish falls back to the artifact and a retry need not rebuild. A failed *build* produces no file, and `upload-artifact`'s default `if-no-files-found: warn` leaves the genuine error as the only one reported.

### Task 5: Document the design — agent, same-commit skill mandate

**Files:**
- Create: `docs/design/iso-distribution.md`
- Modify: `docs/skills/ci-runner.md`

- [x] **Step 1: Write the living-reference design doc**

`docs/design/iso-distribution.md` — why R2 (zero egress vs S3/GCS for a repeatedly-downloaded multi-GB file), the sealed-only trust-model decision, the latest-only/no-archive decision and its known limitation (cross-reference Task 4's note), the bucket/domain/credential inventory (`krytis-iso` bucket, `iso.ririi.dev` custom domain, `R2_ACCOUNT_ID`/`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY` GH secrets), and the rotation procedure (create a new bucket-scoped token in the Cloudflare dashboard, `gh secret set` the three values, revoke the old token — no in-flight upload to invalidate since `rclone` runs a single short-lived job).

Also record the cost model, because it is the constraint that makes "latest only" viable rather than merely simple: 4.5 GB of steady-state storage against a 10 GB-month free tier billed as the monthly average of daily peaks, with the abort-incomplete-multipart-uploads lifecycle rule (Task 1 Step 2) as the guard against orphaned parts — invisible in the object listing, billed as storage — accumulating from cancelled runs. Anyone later proposing a dated archive needs those numbers to see that it moves the bucket off the free tier at the third ISO.

- [x] **Step 2: Add the CI-facing operational notes to the skill file**

Added as `### R2 publish (\`publish_r2\`, issue #867)` — a **subsection of the existing `## \`build-iso.yml\`** section, not the new top-level `##` this step originally specified. It is the same workflow, and someone editing that job needs both halves together rather than finding them 80 lines apart. Covers the `publish_r2`-requires-`sealed` gate, why credentials are plain GH secrets rather than Proton Pass/fnox (no local-dev use case, matching the `TRACKING_APP_*` precedent), the same-run size+checksum verification rationale, the wildcard-DNS trap from Task 2 Step 3, and the lifecycle rule to recreate if the bucket ever is.

- [x] **Step 3: Verify docs links**

```bash
mise run docs-links
```

Expected: `docs-links passed.`

- [x] **Step 4: Commit** — `244dd21`

```bash
git add docs/design/iso-distribution.md docs/skills/ci-runner.md
git commit -m "docs: document R2 ISO hosting design (#867)"
```

### Task 6: Verify end to end — agent + human

**Files:** none — verification only.

- [ ] **Step 1: Push the branch and open the PR**

```bash
git push -u origin <branch>
gh pr create --repo starlit-os/krytis --title "feat(ci): host sealed ISO downloads via Cloudflare R2" --body "Closes #867"
```

- [ ] **Step 2: Merge it**

Merge Gate — human clicks merge. `build-iso.yml` can only be dispatched with the new inputs once they're live on `main` (agents cannot dispatch a workflow_dispatch run using inputs that only exist on an unmerged branch).

- [ ] **Step 3: Dispatch with `sealed=true, publish_r2=true`**

```bash
gh workflow run build-iso.yml --repo starlit-os/krytis --ref main -f sealed=true -f publish_r2=true -f compression=release
```

- [ ] **Step 4: Confirm the run's own verification step passed**

```bash
gh run list --repo starlit-os/krytis --workflow build-iso.yml --limit 1 --json databaseId,conclusion
```

Expected: `conclusion: success` — which already proves the same-run size+checksum check (Task 4 Step 3) passed, so this step and the next are belt-and-braces, not the only evidence.

- [ ] **Step 5: Independently confirm from outside CI**

```bash
curl -sI https://iso.ririi.dev/krytis-live-sealed.iso | head -5
curl -sL https://iso.ririi.dev/krytis-live-sealed.iso.sha256
```

Expected: `HTTP/2 200`, a `content-type: application/x-iso9660-image`, and a 64-char hex checksum. Optionally download the full ISO and verify `sha256sum` locally against the printed checksum for full confidence beyond the CI job's own self-check.

- [ ] **Step 6: Archive this plan and close the issue**

```bash
git mv docs/plans/2026-09-16-r2-iso-hosting.md docs/plans/done/2026-09-16-r2-iso-hosting.md
git commit -m "docs: archive R2 ISO hosting plan (#867 complete)"
git push
gh issue comment 867 --repo starlit-os/krytis --body "Closed via <PR URL>. Verified: iso.ririi.dev serves krytis-live-sealed.iso, size+checksum match a real workflow_dispatch build (run <run-id>). Closing."
gh issue close 867 --repo starlit-os/krytis
```

---

## Self-Review

**Spec coverage:** Both explicit asks — "upload the built ISO to R2" (Tasks 1, 3, 4) and "serve it on a custom domain" (Task 2) — have dedicated tasks. The three `ask`-clarified decisions (domain, sealed-only scope, latest-only versioning) are load-bearing constraints repeated in Global Constraints and enforced in code (Task 4 Step 2's hard gate for the sealed-only rule), not just prose.

**Placeholder scan:** No TBD/TODO. Every code/config step (provision.sh diff, workflow YAML, rclone invocation, verification commands) is the actual content, not a description of one. Bucket name, domain, secret names, and object keys are concrete throughout — no `<TODO>` left for a future pass.

**Type/reference consistency:** `publish_r2` input name matches across Task 4 Steps 1–3 and the Task 4/6 verification commands. `R2_ACCOUNT_ID`/`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY` secret names match between Task 1 Step 4 (provisioning) and Task 4 Step 3 (consumption). `iso.ririi.dev` and `krytis-iso` are the same strings in every task that references them.

**Gate placement:** Human/Security/Design gates (Tasks 1, 2, and the merge/dispatch steps of Task 6) are kept to actions genuinely requiring a browser session or credential a human must hold — matching the `docs/plans/2026-09-02-tracking-bot-github-app.md` precedent this plan's structure is modeled on. Every other task is agent-executable without new human input beyond what Tasks 1–2 provision.
