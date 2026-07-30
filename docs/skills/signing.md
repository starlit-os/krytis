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

`mise/tasks/sign` calls `cosign login ghcr.io` itself rather than assuming `mise/tasks/push`'s earlier `oras login`/`podman login` calls already populated a credential store cosign will read. `cosign` follows the same Docker-config-file (`~/.docker/config.json`) convention as `oras`, so in practice the credentials would already be there after a plain `push` run (i.e. one where `--skip-sbom` was not passed) — but `mise run sign` is designed to be independently runnable (e.g. re-signing an old digest without re-running `push`, or `--skip-sbom` was passed to `push`), so it does not depend on that side effect.
