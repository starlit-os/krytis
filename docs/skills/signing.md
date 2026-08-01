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

Two independent reasons — the first reflects #392's push reordering, the second is #380's original design decision:

1. **Severity-gate independence.** Since #392, `mise run push --fail-on critical` aborts *before* logging in/tagging/pushing anything — a Critical finding means nothing ever reaches the registry. A separate `mise run sign` task still makes sense here: it only depends on `krytis-push-digests.env` existing on disk, not on *why* the previous step succeeded or failed. When push (or the earlier pre-build `mise run vuln-scan --fail-on` gate in CI) blocks, the digest file was never written, so `mise run sign` cleanly reports "no image digest given" and exits — no special-casing needed to distinguish "blocked" from "genuinely nothing to sign yet." `mise run sign` runs `if: always()` in CI for exactly this reason: it's cheap to attempt and self-explains when there's nothing to do.
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
  --certificate-identity-regexp '^https://github\.com/starlit-os/krytis/\.github/workflows/publish\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/starlit-os/krytis@<digest>
```

`--certificate-identity-regexp` constrains verification to signatures produced by
`publish.yml` running in `starlit-os/krytis` — without it, `cosign verify` accepts a
signature from *any* Sigstore-issued identity, which defeats the point of checking
provenance.

**Note the `@refs/heads/main$` anchor.** This previously ended `@refs/heads/.*`, which
accepted a signature from *any* branch of the repo — so the check proved "some branch of
this repo signed it" rather than naming one. That was noticed when a deliberately-wrong
regexp reported the real SAN of the then-current `:latest`:

```
got "https://github.com/starlit-os/krytis/.github/workflows/publish.yml@refs/heads/392-scan-before-build-not-after-push"
```

i.e. the published `:latest` had been signed from a feature branch. `publish.yml` now
refuses to publish from a non-`main` ref unless `allow_branch_publish=true` is passed
explicitly, and that gate runs **before** the build — because `mise run push` always tags
`:latest` and runs long before verification, so a post-hoc check would publish first and
fail second.

**Consequence of an opt-in branch publish:** the resulting `:latest` is signed with a
non-`main` identity and will **not** satisfy the command above. Re-publish from `main`
afterwards. There is currently no way to test-publish without moving `:latest`
(`mise run push` has no `--skip-latest`), which is the sharp edge here — worth a flag if
branch publishes become routine.

## `cosign login` vs. relying on `oras`/`podman` login side effects

`mise/tasks/sign` calls `cosign login ghcr.io` itself rather than assuming `mise/tasks/push`'s earlier `oras login`/`podman login` calls already populated a credential store cosign will read. `cosign` follows the same Docker-config-file (`~/.docker/config.json`) convention as `oras`, so in practice the credentials would already be there after a plain `push` run (i.e. one where `--skip-sbom` was not passed) — but `mise run sign` is designed to be independently runnable (e.g. re-signing an old digest without re-running `push`, or `--skip-sbom` was passed to `push`), so it does not depend on that side effect.

## CI verification is blocking — but only when signing succeeded

`publish.yml` runs `cosign verify` after `mise run sign`, and **that step fails the job**
(#418). It previously carried `continue-on-error: true` and was labelled "diagnostic",
which meant nothing in the pipeline ever rejected a bad signature — we signed and then
ignored whether the signature was verifiable against our own policy.

The gate is `if: always() && steps.sign.outcome == 'success'`, not unconditional, and the
distinction matters:

| Situation | Outcome |
|---|---|
| Signing failed (Fulcio/Rekor outage, or nothing was pushed) | verify **skipped**, publish still succeeds — preserves #380's best-effort tolerance |
| Signing succeeded, signature verifies | publish succeeds |
| Signing succeeded, signature does **not** verify against the expected identity | publish **fails** — the only case where the signature problem is genuinely ours |

The identity is pinned to the run's own ref (`main` on the normal path — see § Verifying a Signature), and the "only main may publish" policy is enforced by a ref gate that runs before the build.

It verifies every artifact `sign` signed (image, SBOM, vulnerability report), not just the
image: an unverifiable referrer signature is the same class of problem.

## Host-side enforcement does not exist, and cannot today

Signatures are attestations for consumers to check. **Nothing on a krytis host verifies
them before deploying an image** — `bootc` performs no signature check. This is an
upstream limitation, not an oversight, and it is worth knowing before someone tries to
"just add a `policy.json`".

`containers-policy.json`'s `sigstoreSigned.fulcio` block requires **both** `oidcIssuer`
and `subjectEmail`. Upstream's man page: *"Both `oidcIssuer` and `subjectEmail` are
mandatory, exactly specifying the expected identity provider, and the identity of the user
obtaining the Fulcio certificate."*

GitHub Actions OIDC tokens carry no verified email claim. A keyless signature from a
workflow gets a Fulcio certificate whose SAN is a **URI** —
`https://github.com/starlit-os/krytis/.github/workflows/publish.yml@refs/heads/main` — not
an email. So `subjectEmail` can never match, and `policy.json` cannot express "accept
images signed via GitHub Actions OIDC" at all.

Note the asymmetry: `cosign verify` handles URI SANs perfectly well, which is exactly what
the CI step above relies on. It is only `policy.json` that cannot.

Upstream fix: [`containers/image#2235`](https://github.com/containers/image/pull/2235)
adds URI-SAN support to the `fulcio` block. Stalled on DCO/review friction since February
2024, and would then need to reach the `containers/image` version `bootc` vendors.

The workaround — a long-lived static key whose `keyPath` verification `policy.json` *can*
express, signed alongside the keyless signature — means storing and rotating a key, the
exact thing keyless signing was chosen to avoid. That is a Security Gate tradeoff under
AGENTS.md, tracked in **#418**, not a pending chore. The original design for it is at
`docs/design/cosign-keyless-signing.md` §§ 3–4.
