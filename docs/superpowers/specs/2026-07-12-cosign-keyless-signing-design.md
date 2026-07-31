# Design: Cosign keyless signing + verification policy

**Issue:** #60 — Add cosign keyless signing
**Milestone:** v0.5 — secure
**Date:** 2026-07-12

> ## Status: historical design record — implementation diverged
>
> Written 2026-07-12, **before** implementation. #60 was ultimately implemented by
> **#388** (`feat(ci): add manual publish workflow — build, push, scan, sign`) along a
> narrower path than this design proposes, and #60 is now closed. This document is
> merged as the record of *why* the shape was chosen — in particular the `policy.json`
> constraint below, which is still true and is not captured anywhere else — not as a
> description of the current system. **For how signing actually works today, read
> `docs/skills/signing.md`.**
>
> | This design proposed | Shipped? |
> |---|---|
> | CI workflow that publishes + signs **on every push to `main`** | **Diverged** — `publish.yml` is `workflow_dispatch` only (manual) |
> | **Dual** signatures: keyless (OIDC) + static key pair | **No** — keyless only |
> | Host-side `bootc`/`policy.json` enforcement using the static key | **No** — tracked in #418 |
> | Docs page for manual/CI verification via the keyless signature | **Yes** — `docs/skills/signing.md` |
> | `mise` tasks for key generation and manual verification | **Partial** — `mise/tasks/sign` exists; no cosign key generation (unnecessary without the static key) and no separate verify task (verification is inline in `publish.yml` plus documented). Note `mise run generate-keys`/`pull-keys` are the **secure boot** PK/KEK/db keys, unrelated to cosign. |
>
> Sections **3. Key management (Security Gate)** and **4. Host-side enforcement** are
> therefore unimplemented proposals, not documentation. Both hinge on introducing a
> long-lived signing key — the exact thing keyless signing was chosen to avoid — so
> they remain a Security Gate decision under AGENTS.md rather than a pending chore.
> See #418 for the current framing of that tradeoff.

## Problem

Krytis builds an OCI image (`oci/krytis/image.bst`) but has no supply-chain
signing. `mise run push` already pushes the built image to
`ghcr.io/starlit-os/krytis`, but nothing signs it, and nothing on the
publishing or consuming side verifies it. #60 asks for cosign keyless
(OIDC-based) signing; this design also covers what "verification policy"
means concretely — both host-side enforcement and manual/CI verification.

## Scope

- A CI workflow that publishes and signs the image on every push to `main`.
- Dual cosign signatures: keyless (OIDC) and a static key pair, for reasons
  explained in [Constraint](#constraint-upstream-policyjson-cannot-verify-keyless-github-actions-signatures).
- Host-side (`bootc`/`policy.json`) enforcement using the static key.
- A docs page for manual/CI verification using the keyless signature (the
  stronger identity check).
- `mise` tasks for key generation and manual verification.

**Out of scope** (tracked separately):
- SBOM generation / `cosign attest` (#40).
- Vulnerability scanning (#41).
- Version-tag-triggered releases — this design only covers `push: main`
  publishing floating `latest` + a date-based version tag (matching the
  existing `mise run push` behavior). A release/tag process is a separate
  concern.

## Constraint: upstream `policy.json` cannot verify keyless GitHub Actions signatures

This is the load-bearing discovery behind this design's shape, so it's
called out before the architecture.

`containers-policy.json`'s `sigstoreSigned.fulcio` requirement block is
documented as requiring **both** `oidcIssuer` and `subjectEmail` — the
upstream man page states plainly: "Both `oidcIssuer` and `subjectEmail` are
mandatory, exactly specifying the expected identity provider, and the
identity of the user obtaining the Fulcio certificate."

GitHub Actions OIDC tokens do not carry a verified email claim. When cosign
signs keylessly from a GitHub Actions workflow, the Fulcio-issued
certificate's SAN is a **URI** (the workflow ref, e.g.
`https://github.com/starlit-os/krytis/.github/workflows/publish.yml@refs/heads/main`),
not an email address. `subjectEmail` will never match, so `policy.json`'s
native `fulcio` verification path cannot express "accept images signed via
GitHub Actions OIDC" at all today.

There is an open upstream PR, [`containers/image#2235`](https://github.com/containers/image/pull/2235),
adding URI-SAN support (`subjectURI` or similar) to the `fulcio` block. It
has been open and stalled (DCO / review friction) since February 2024 and
is unmerged as of this writing. Until it merges and ships in the
`containers/image` version `bootc` vendors, **host-side enforcement of the
keyless signature is not possible**.

**Resolution: dual-sign.** Every publish gets both a keyless signature
(satisfies #60, gives public Rekor transparency and strong workflow-identity
provenance, used for manual/CI verification) and a signature from a
maintained static cosign key pair (weaker identity binding — proves
"signed by whoever holds the repo's cosign key," not "signed by this exact
workflow run" — but `policy.json`'s `keyPath` verification can check it
today). When `containers/image#2235` lands and bootc picks it up, the
static-key host enforcement can be replaced by keyless enforcement; track
that as a follow-up issue referencing this design.

## Architecture

### 1. Publish workflow — `.github/workflows/publish.yml`

New workflow, separate from `cache-warm.yml` (which is schedule-triggered
and exists purely to keep the build cache warm — publishing on every
schedule tick would be wrong).

- **Trigger:** `push` to `main`.
- **Runner:** Blacksmith (same as `cache-warm.yml` — full BST build needs
  the RAM/disk).
- **Concurrency:** `krytis-publish`, `cancel-in-progress: false` (never
  cancel a signing run mid-flight).
- **Permissions:** `contents: read`, `packages: write` (GHCR push),
  `id-token: write` (required for GitHub Actions OIDC → Fulcio keyless
  signing).

Steps (reusing the existing bootstrap pattern from `cache-warm.yml` and the
existing `mise` tasks — no reinvention of the build/push logic):

1. `jdx/mise-action@<pinned-sha>` — installs Python + uv.
2. Write `~/.config/buildstream.conf`.
3. `actions/cache` restore (same key strategy as `cache-warm.yml`).
4. `apt-get install bubblewrap lzip xz-utils bzip2 gzip`.
5. `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.
6. `mise run build` (generate-image-version + load-image + lint — this
   *is* blocking here, unlike `cache-warm.yml`'s non-blocking build; a
   publish must not proceed past a failed lint).
7. `mise run push` — tags and pushes `ghcr.io/starlit-os/krytis:<version>`
   and `:latest`; capture the pushed digest from its output.
8. `sigstore/cosign-installer@<pinned-sha>`.
9. `mise run cosign-sign --digest <digest>` (see [mise tasks](#4-mise-tasks))
   — runs both signatures against the digest.
10. `mise run cosign-verify --digest <digest>` — smoke-test both
    signatures verify against the just-published image. Fails the job
    (and therefore the publish) if either does not. This step is the
    evidence artifact for the Verification gate.

### 2. Dual signing

Both signatures target the same resolved image **digest**, not a mutable
tag (`cosign`-created signatures only claim a repository identity, not a
tag — signing by digest avoids any ambiguity about which build was signed).

- **Keyless:**
  ```shell
  cosign sign --yes ghcr.io/starlit-os/krytis@<digest>
  ```
  No key material. Identity comes from the GH Actions OIDC token exchanged
  with Fulcio for a short-lived signing cert; the signature (and cert) are
  logged to the public Rekor transparency log.

- **Static key pair:**
  ```shell
  cosign sign --yes --key env://COSIGN_PRIVATE_KEY ghcr.io/starlit-os/krytis@<digest>
  ```
  `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` come from GitHub Actions
  secrets (see [Key management](#3-key-management-security-gate)).

**cosign version / bundle-format compatibility note:** a real-world gotcha
(observed in `ublue-os/image-template#215`) is that cosign v3's default
signing flow produces bundle/referrer formats that `containers/image`'s
legacy `use-sigstore-attachments` discovery path cannot find, producing "A
signature was required, but no signature exists" even though `cosign
verify` succeeds. Pin the cosign version installed in CI to a 2.x release
(or, if using a 3.x installer, pass `--new-bundle-format=false
--registry-referrers-mode=legacy` on `sign`) so the static-key signature
stays discoverable by `policy.json`'s `use-sigstore-attachments` path. This
constraint applies to the static-key signature only — the keyless
signature is verified out-of-band via `cosign verify` (§5), which is not
affected.

### 3. Key management (Security Gate)

This is a human action, not something an agent executes autonomously —
flagged per AGENTS.md's Security Gate ("Auth, signing, supply chain,
secrets handling").

1. Human runs `mise run cosign-generate-keys` locally (produces
   `cosign.key` + `cosign.pub`, password-prompted).
2. Human stores `cosign.key`'s contents as the `COSIGN_PRIVATE_KEY` GitHub
   Actions secret, and the password as `COSIGN_PASSWORD`.
3. Human commits `cosign.pub` to the repo root (matches the convention
   already established in the sibling `zirconium-hawaii` project — "Cosign
   public key is at `cosign.pub` in the repo root").
4. `cosign.key` itself is never committed (mirrors `files/boot-keys/`
   already being `.gitignore`d for the secure-boot key material).

### 4. Host-side enforcement — new element

No existing element manages `/etc/containers/` config. New
`elements/core/container-sigpolicy.bst` ships:

- `/etc/pki/containers/krytis.pub` — copy of the committed `cosign.pub`.
- `/etc/containers/policy.json`:
  ```json
  {
    "default": [{"type": "reject"}],
    "transports": {
      "docker": {
        "ghcr.io/starlit-os/krytis": [
          {
            "type": "sigstoreSigned",
            "keyPath": "/etc/pki/containers/krytis.pub",
            "signedIdentity": {"type": "matchRepository"}
          }
        ]
      }
    }
  }
  ```
- `/etc/containers/registries.d/ghcr-starlit-os.yaml`:
  ```yaml
  docker:
    ghcr.io/starlit-os/krytis:
      use-sigstore-attachments: true
  ```

This is a `local` source element (static files), not `git_repo`/`tar`/
`remote` — the Update path gate does not apply.

**Adoption path (documented, not automated):** a system not already
trusting this policy needs the first switch to explicitly opt in:
```shell
sudo bootc switch --enforce-container-sigpolicy ghcr.io/starlit-os/krytis:latest
sudo systemctl reboot
```
After that, ordinary `sudo bootc upgrade` enforces the shipped policy
automatically, since the policy ships inside the image itself.

### 5. Manual / CI verification docs

New docs page (`docs/verifying-signatures.md`, user-facing — not a
`docs/skills/` file) covering both verification paths:

- **Keyless (strong identity check)** — pins to the exact workflow and
  ref, the strongest guarantee available:
  ```shell
  cosign verify \
    --certificate-identity-regexp 'https://github.com/starlit-os/krytis/\.github/workflows/publish\.yml@refs/heads/main' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/starlit-os/krytis:latest
  ```
- **Key-based (matches what the host enforces):**
  ```shell
  cosign verify --key cosign.pub ghcr.io/starlit-os/krytis:latest
  ```

The page explains why both exist (§ Constraint) and links to the Rekor
public log for independent transparency verification of the keyless
signature.

### 6. mise tasks

- `mise run cosign-generate-keys` — one-time, human-run. Wraps `cosign
  generate-key-pair`. Modeled on the `generate-keys` precedent already
  planned for secure-boot key material (`docs/plan/secure-boot-uki.md`).
- `mise run cosign-sign --digest <digest>` — runs both signing commands
  from §2. Used by `publish.yml`; also runnable manually for a re-sign.
- `mise run cosign-verify --ref <digest-or-tag>` — runs both verification
  commands from §5. Used by `publish.yml`'s smoke test; also the
  human-facing command referenced from the docs page.

## Testing / verification plan

- `mise lint` must pass (existing gate, runs bootc container lint via
  `Containerfile`).
- `publish.yml`'s own `cosign-verify` step is the CI evidence that signing
  worked, captured in the workflow run link for the PR.
- Manually verify the new `container-sigpolicy.bst` element by building the
  image (`mise run build`) and checking `/etc/containers/policy.json` and
  `/etc/containers/registries.d/` exist with the expected content inside
  the built image (`podman run --rm localhost/krytis:latest cat
  /etc/containers/policy.json`).
- `mise boot-test` for the normal boot-path regression check (this change
  touches files under `/etc/containers/`, not the boot path itself, but
  the gate applies to every PR).
- Because this crosses the Security Gate and Breakage Gate (new signing
  keys, changes to how images are trusted), open as a draft PR per
  AGENTS.md and request explicit human review before merge — do not
  self-merge.

## Skill file updates required (same commit)

`docs/skills/` currently has no signing-specific file. This design commits
a new `docs/skills/signing.md` capturing:

- The `containers/image` URI-SAN gap (`containers/image#2235`) and why
  dual-signing exists — so a future agent doesn't waste time trying to
  configure `policy.json` fulcio verification directly against a
  GH-Actions-keyless signature.
- The cosign v3 bundle-format / `use-sigstore-attachments` discovery
  gotcha.
- Where the mise tasks and workflow live, and the digest-not-tag signing
  rationale.
