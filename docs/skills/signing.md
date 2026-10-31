# Cosign Keyless Signing

Load when working on `mise run sign`, `mise run promote`, `.github/workflows/publish.yml`, or anything touching cosign/Sigstore/OIDC in krytis. Implements #60; promotion gating is #1458.

## What It Is

`mise run sign` signs the published `oci/krytis/image.bst` image and both of its OCI referrers (SBOM from #40, Grype vulnerability report from #41) using [cosign](https://github.com/sigstore/cosign) **keyless** signing: no private key is generated, stored, or rotated. Each `cosign sign -y <ref>@<digest>` call requests a short-lived code-signing certificate from Sigstore's public Fulcio CA, bound to an OIDC identity, and records the signature in Sigstore's public Rekor transparency log.

## Digest Hand-off from `mise run push`

`mise/tasks/push` writes its digest file (`--digest-file`, default `krytis-push-digests.env` — gitignored, transient) with up to three `KEY=VALUE` lines:

```
image_digest=sha256:...
sbom_digest=sha256:...
vuln_digest=sha256:...
```

`sbom_digest`/`vuln_digest` are only present when the corresponding `push` step actually ran (absent if `--skip-sbom`/`--skip-vuln-scan` was passed). `mise run sign` and `mise run promote` both read this file by default (`--digest-file`, default `krytis-push-digests.env`), so a human running the commands from the same shell in the same directory needs no extra flags:

```bash
mise run push --fail-on critical
mise run sign
```

`--image-digest`/`--sbom-digest`/`--vuln-digest` flags override the file for scripted use (also useful for re-signing a specific historical digest without re-running `push`). CI does not use them. It passes a matching `--digest-file` to `push`, `sign` and `promote` instead, which is what lets the sealed build (#448) run in the same job without clobbering the record: the sealed steps write and read `krytis-sealed-digests.env`, so the primary image's `krytis-push-digests.env` still names the digest its own signature was verified against.

## Why signing is a separate task from `push`

Since #392, `mise run push --fail-on critical` aborts *before* logging in, tagging or pushing anything, so a Critical finding means nothing reaches the registry and no digest file is written. `mise run sign` depends only on that file existing, not on why an earlier step did or didn't run.

Keeping them apart is also what makes the CI ordering in § Promotion gates on the image signature possible: push the version tag, sign, verify, and only then move the floating tag. A `push` that signed internally would have to grow all of that.

The original reason, #380's "signing is best-effort and must not block promotion", no longer holds. #1458 replaced it (see below).

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
explicitly, and that gate runs **before** the build. Verification can't catch a
branch publish by itself: the job pins `SIGNER_IDENTITY` to the run's own ref, so a
branch run signs, verifies and promotes `:latest` under the branch identity.

**Consequence of an opt-in branch publish:** the resulting `:latest` is signed with a
non-`main` identity and will **not** satisfy the command above. Re-publish from `main`
afterwards. `mise run push --version-only` pushes without touching `:latest`, but the
workflow always runs `mise run promote` after it, so a branch publish still moves
`:latest`. Skipping promotion on non-`main` refs would be the fix if branch publishes
become routine.

## `cosign login` vs. relying on `oras`/`podman` login side effects

`mise/tasks/sign` calls `cosign login ghcr.io` itself rather than assuming `mise/tasks/push`'s earlier `oras login`/`podman login` calls already populated a credential store cosign will read. `cosign` follows the same Docker-config-file (`~/.docker/config.json`) convention as `oras`, so in practice the credentials would already be there after a plain `push` run (i.e. one where `--skip-sbom` was not passed) — but `mise run sign` is designed to be independently runnable (e.g. re-signing an old digest without re-running `push`, or `--skip-sbom` was passed to `push`), so it does not depend on that side effect.

## Promotion gates on the image signature (#1458)

`:latest` and `:sealed` are the tags hosts follow, so `publish.yml` never points them at an unsigned digest. Order per half (unsigned, then sealed):

| Step | On failure |
|---|---|
| `mise run push --version-only` pushes `:<version>` (or `:<version>-sealed`) only | job fails, nothing promoted |
| `mise run sign --only image`, each `cosign sign` retried 3× (30 s, 60 s backoff) | job fails; the floating tag stays on the previous signed image; `:<version>` exists unsigned |
| `mise run promote [--sealed] --identity-regexp "$SIGNER_IDENTITY"`: `cosign verify` the image, then `oras tag` the digest and read it back | job fails, nothing promoted. A signature that does not verify against our own identity is the only case where a signature problem is genuinely ours |
| `mise run sign --only referrers` (SBOM + vulnerability report), `continue-on-error` | the floating tag has already moved; `Fail on unsigned referrers`, the job's last step, turns the run red |
| inline `cosign verify` of the referrers, only if they signed | job fails |

**Only the image signature gates promotion.** That was the owner's decision on #1458: a referrer that fails to sign does not hold back a signed image, but the run must not stay green. A red run skips `verify-sealed.yml` (it only runs on a successful publish), so dispatch it by hand if `:sealed` moved.

**Why it changed.** Under #380 the push tagged `:latest` first and signing ran with `continue-on-error: true`, so a signing failure left an unsigned `:latest` public in a green run. The cost of the new rule was measured over all 86 `publish.yml` runs GitHub listed on 2026-10-31 (2026-07-30 to 2026-10-30; 61 unsigned and 49 sealed pushes). Signing failed after a successful push twice, and neither was a declared Sigstore incident:

- Run 31158190488 (2026-08-07): `dial tcp [::]:443: connect: connection refused` to Fulcio on the self-hosted runner. A dial to `[::]` points to the runner's DNS rather than Fulcio [INFERENCE]. Under the new rule, `:latest` would have stayed on the previous image for about 4–5 h, until the next run.
- Run 32241688624 (2026-08-19): the sealed image and SBOM signed, but the vulnerability report hit Rekor `409 createLogEntryConflict` ("an equivalent entry already exists"). Under image-only gating, nothing is lost.

**Retries.** Each `cosign sign` attempt generates fresh ephemeral keys, so a retry is a new Rekor entry and the 409 above should not recur on a retry. Signing a digest twice only adds a second signature, and `cosign verify` accepts either.

**`promote` is also the rollback tool.** `mise run promote --image-digest <older digest>` moves `:latest` back to any image `publish.yml` signed on `main`. Its default `--identity-regexp` is that main-pinned identity. It cannot rescue a failed signing step: a signature made outside `publish.yml` carries another identity and fails verification, so recovery is re-dispatching the workflow. `oras tag` re-uploads nothing and keeps the manifest bytes, so the signature, which is bound to the digest, stays valid.

`SIGNER_IDENTITY` is a job-level env var in `publish.yml`, pinned to the run's own ref (`main` on the normal path; see § Verifying a Signature), so every verification in the job uses the same regexp. The "only main may publish" policy is enforced by a ref gate that runs before the build.

The sealed half repeats the same five steps against `krytis-sealed-digests.env`. It runs only when `publish_sealed` is set (the `workflow_dispatch` input defaults to `true`, and scheduled runs always set it), and deliberately *after* the unsigned image is published, signed, verified and promoted: the sealed build is the newer, less-exercised path, and a failure in it must not cost the primary artifact.

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

An upstream fix exists but has not landed (as of 2026-10-11). [`containers/image#2235`](https://github.com/containers/image/pull/2235)
("Accept URI for Sigstore Signed Images") would have added URI-SAN support to the `fulcio`
block, but after stalling on DCO/review friction from February 2024 it was **closed
unmerged** on 2025-08-26 when `containers/image` folded into the `containers/container-libs`
monorepo (since renamed `podman-container-tools/container-libs`). The demand moved to
[`podman-container-tools/container-libs#34`](https://github.com/podman-container-tools/container-libs/issues/34)
("Extend Fulcio signature acceptance options to support 'workflow identity'"), and
[`podman-container-tools/container-libs#625`](https://github.com/podman-container-tools/container-libs/pull/625)
(opened 2026-02-04) implements it: a `buildSignerURI` match on Fulcio's OID
`1.3.6.1.4.1.57264.1.9` extension, closing #34. As of 2026-10-11 it is open and blocked,
with one contributor LGTM, repeated pings to the maintainers, and no maintainer review;
last activity 2026-05-25. So the timeline is: #625 merges, *then* it reaches the
`containers/image` version `bootc` vendors. Treat host-side keyless enforcement as
unavailable, not imminent.

The workaround — a long-lived static key whose `keyPath` verification `policy.json` *can*
express, signed alongside the keyless signature — means storing and rotating a key, the
exact thing keyless signing was chosen to avoid. That is a Security Gate tradeoff under
AGENTS.md, tracked in **#418**, not a pending chore. The original design for it is at
`docs/design/cosign-keyless-signing.md` §§ 3–4.

## Where a `policy.json` has to live, and why the sketched path is wrong

*Source: zirconium-hawaii `4229691` → `d4e641b` → `f251073` — three commits, one thread.*

Prerequisites for the day #418's static-key half is actually built. zirconium-hawaii does
ship a container signature policy, and learned all three of these the hard way.

**1. Ship it at `%{datadir}/containers` (`/usr/share/containers`), not `/etc/containers`.**
Podman 6.0 — the version freedesktop-sdk 26.08 ships — and current bootc both read the
`/usr/share` path. `/etc` is mutable state on a bootc system; image-owned policy belongs
in `/usr`.

**2. fdsdk's own `/etc/containers/policy.json` overrides yours.** zirconium shipped
`/usr/share/containers/policy.json`, saw no error, and unsigned `zirconium-dev` images
stayed pullable anyway — the `/etc` copy wins at runtime and nothing warns you. The fix
is `integration-commands` that delete and relocate the inherited files:

```yaml
integration-commands:
- rm /etc/containers/policy.json
- mv /etc/containers/registries.conf /usr/share/containers/registries.conf
- mkdir -p /usr/share/containers/registries.d /usr/share/containers/registries.conf.d
# … plus mv of registries.d/* and registries.conf.d/*
```

The same commit dropped two Red Hat registry entries from the policy whose referenced
keys did not exist on the image. Not cosmetic: a policy entry naming an absent `keyPath`
is a hard failure for that scope, and it had broken pulls from those registries outright.

**3. bootc on the ostree backend breaks when `"default"` is `insecureAcceptAnything`.**
The workaround is `"default": [{"type": "reject"}]` plus an explicit
`insecureAcceptAnything` entry under *every* transport — `docker`, `docker-daemon`,
`atomic`, `containers-storage`, `dir`, `oci`, `oci-archive`, `docker-archive`,
`tarball`. Semantically identical, "just a lot uglier" in the commit's own words.

**krytis exposure.** `docs/design/cosign-keyless-signing.md:189` opens the host-side
enforcement design with "No existing element manages `/etc/containers/` config", then
sketches a never-written `elements/core/container-sigpolicy.bst` writing
`/etc/containers/policy.json` and `/etc/containers/registries.d/ghcr-starlit-os.yaml`.
Both halves are wrong. `files/fakecap-manifest.tsv:353-356` shows krytis already inherits
`/etc/containers/{policy.json,registries.conf,registries.conf.d/000-shortnames.conf,registries.d/default.yaml}`
from `components/containers-common.bst` (plus `toolbox.conf` from
`gnomeos-deps/toolbox.bst`) — so that element would land on an already-owned mutable
path, which is also the wrong destination per point 1. Rewrite the sketch against
`%{datadir}/containers` plus the `rm`/`mv` integration commands before anyone builds it.

Point 3 is the one thing the design already got right: it uses
`"default": [{"type": "reject"}]`. What is missing is *why* that is mandatory rather than
merely strict — a permissive default is what breaks bootc's ostree backend, so the
per-transport `insecureAcceptAnything` expansion is load-bearing verbosity, not something
to simplify away later.
