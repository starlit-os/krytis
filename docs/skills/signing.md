# Cosign Keyless Signing

Load when working on `mise run sign`, `mise run promote`, `mise run cosign-generate-keys`, `.github/workflows/publish.yml`, or anything touching cosign/Sigstore/OIDC in krytis. Implements #60; promotion gating is #1458; the static key hosts enforce is #418.

## What It Is

`mise run sign` signs the published `oci/krytis/image.bst` image and both of its OCI referrers (SBOM from #40, Grype vulnerability report from #41) using [cosign](https://github.com/sigstore/cosign) **keyless** signing: no private key is generated, stored, or rotated. Each `cosign sign -y <ref>@<digest>` call requests a short-lived code-signing certificate from Sigstore's public Fulcio CA, bound to an OIDC identity, and records the signature in Sigstore's public Rekor transparency log.

The image itself (not the referrers) also carries a second signature, from a **static key** kept in Proton Pass. That one exists for hosts: `policy.json` can verify a key but not a GitHub Actions identity. See § Static-key signature (#418).

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

The static-key signature verifies against the committed public key. `--new-bundle-format=false` is required, not optional (§ Static-key signature (#418)):

```bash
cosign verify --key cosign.pub --new-bundle-format=false ghcr.io/starlit-os/krytis@<digest>
```

## `cosign login` vs. relying on `oras`/`podman` login side effects

`mise/tasks/sign` calls `cosign login ghcr.io` itself rather than assuming `mise/tasks/push`'s earlier `oras login`/`podman login` calls already populated a credential store cosign will read. `cosign` follows the same Docker-config-file (`~/.docker/config.json`) convention as `oras`, so in practice the credentials would already be there after a plain `push` run (i.e. one where `--skip-sbom` was not passed) — but `mise run sign` is designed to be independently runnable (e.g. re-signing an old digest without re-running `push`, or `--skip-sbom` was passed to `push`), so it does not depend on that side effect.

## Promotion gates on the image signature (#1458)

`:latest` and `:sealed` are the tags hosts follow, so `publish.yml` never points them at an unsigned digest. Order per half (unsigned, then sealed):

| Step | On failure |
|---|---|
| `mise run push --version-only` pushes `:<version>` (or `:<version>-sealed`) only | job fails, nothing promoted |
| `mise run sign --only image`: keyless, then static key (#418); each `cosign sign` retried 3× (30 s, 60 s backoff) | job fails; the floating tag stays on the previous signed image; `:<version>` exists unsigned or keyless-only |
| `mise run promote [--sealed] --identity-regexp "$SIGNER_IDENTITY"`: `cosign verify` the keyless signature, then the static one against `cosign.pub`, then `oras tag` the digest and read it back | job fails, nothing promoted. A signature that does not verify against our own identity or key is the only case where a signature problem is genuinely ours |
| `mise run sign --only referrers` (SBOM + vulnerability report), `continue-on-error` | the floating tag has already moved; `Fail on unsigned referrers`, the job's last step, turns the run red |
| inline `cosign verify` of the referrers, only if they signed | job fails |

**Only the image signature gates promotion.** That was the owner's decision on #1458: a referrer that fails to sign does not hold back a signed image, but the run must not stay green. A red run skips `verify-sealed.yml` (it only runs on a successful publish), so dispatch it by hand if `:sealed` moved.

**Why it changed.** Under #380 the push tagged `:latest` first and signing ran with `continue-on-error: true`, so a signing failure left an unsigned `:latest` public in a green run. The cost of the new rule was measured over all 86 `publish.yml` runs GitHub listed on 2026-10-31 (2026-07-30 to 2026-10-30; 61 unsigned and 49 sealed pushes). Signing failed after a successful push twice, and neither was a declared Sigstore incident:

- Run 31158190488 (2026-08-07): `dial tcp [::]:443: connect: connection refused` to Fulcio on the self-hosted runner. A dial to `[::]` points to the runner's DNS rather than Fulcio [INFERENCE]. Under the new rule, `:latest` would have stayed on the previous image for about 4–5 h, until the next run.
- Run 32241688624 (2026-08-19): the sealed image and SBOM signed, but the vulnerability report hit Rekor `409 createLogEntryConflict` ("an equivalent entry already exists"). Under image-only gating, nothing is lost.

**Retries.** Each `cosign sign` attempt generates fresh ephemeral keys, so a retry is a new Rekor entry and the 409 above should not recur on a retry. Signing a digest twice only adds a second signature, and `cosign verify` accepts either.

**`promote` is also the rollback tool.** `mise run promote --image-digest <older digest>` moves `:latest` back to any image `publish.yml` signed on `main` with both signatures. Its default `--identity-regexp` is that main-pinned identity. Digests published before the static key existed carry only the keyless signature, so promote refuses them, as hosts enforcing the static key would. It cannot rescue a failed signing step: a signature made outside `publish.yml` carries another identity and fails verification, so recovery is re-dispatching the workflow. `oras tag` re-uploads nothing and keeps the manifest bytes, so the signatures, which are bound to the digest, stay valid.

`SIGNER_IDENTITY` is a job-level env var in `publish.yml`, pinned to the run's own ref (`main` on the normal path; see § Verifying a Signature), so every verification in the job uses the same regexp. The "only main may publish" policy is enforced by a ref gate that runs before the build.

The sealed half repeats the same five steps against `krytis-sealed-digests.env`. It runs only when `publish_sealed` is set (the `workflow_dispatch` input defaults to `true`, and scheduled runs always set it), and deliberately *after* the unsigned image is published, signed, verified and promoted: the sealed build is the newer, less-exercised path, and a failure in it must not cost the primary artifact.

## Static-key signature (#418)

Hosts can't check the keyless signature (§ Hosts can't check the keyless signature), so on
2026-11-02 the owner chose option 1 of #418: sign every published image a
second time with a long-lived key that `policy.json` *can* verify, until upstream supports
workflow identities. Keyless signing stays; it is what CI verifies against `publish.yml`'s
identity and what puts the image in Rekor.

**Custody.** The private key is the body of a Proton Pass *note*, `Krytis/Cosign Signing
Key`, read as `COSIGN_PRIVATE_KEY` through `fnox.toml`. The public half is `cosign.pub` in
the repo root. CI reaches the vault through the one `PROTON_PASS_PAT` secret, the same path
as the UEFI keys, which is why `publish.yml`'s `Authenticate to Proton Pass` step runs on
every publish, not only sealed ones. `mise run sign` holds the key in a shell variable and
hands it to `cosign` through a per-command `env://COSIGN_PRIVATE_KEY`, so it never touches
the runner's disk. Before signing anything it derives the public key from the vault copy
and compares it with `cosign.pub`: a vault key that drifted from the committed one would
sign images every host refuses.

**The key has an empty password.** cosign insists on encrypting the PEM, but a password kept
next to the key protects nothing the vault doesn't, and would be a second secret to fetch.
The UEFI keys in the same vault are unencrypted (`openssl -nodes`) for the same reason.

**Creating it: `mise run cosign-generate-keys`, run by a human once.** It refuses when
`cosign.pub` or the vault item already exists, because a second pair would silently fork the
trust chain. It generates on `/dev/shm`, creates the note, reads it back through `fnox`,
and writes `cosign.pub` only if the vault copy derives the same public key.

Two `pass-cli` facts shaped the item type, both found by probing a throwaway item in the
vault on 2026-11-02 (pass-cli 2.5.1):

- **A custom item doesn't work.** `pass-cli item create custom --from-template -` puts every
  field in a *section*, and `pass://<vault>/<item>/<field>`, which is how fnox reads, answers
  `Field does not exist` for section fields. The UEFI item's fields are top-level
  `extra_fields`, which the template has no way to create. `pass-cli item update --field
  name=value` does create a top-level field, but takes the value on the command line, where
  `/proc/<pid>/cmdline` exposes it.
- **A note does.** `item create note --from-template -` takes the PEM on stdin, and
  `fnox get` of `<item>/note` returns it intact; `pass-cli item view` adds one trailing
  newline, which PEM parsing ignores.

**Format: legacy `.sig` tags, or hosts see no signature.** cosign 3.x writes new-format
Sigstore bundles as OCI referrers by default. containers/image only reads the legacy
`sha256-<digest>.sig` tag through `use-sigstore-attachments`, and its bundle support
(podman-container-tools/container-libs#567) was closed unmerged. So the static signature is
made with `--new-bundle-format=false --use-signing-config=false`. Measured on 2026-11-02
with cosign 3.1.4 against a local `registry:2`, verifying with the host's own
`skopeo 1.24.1` (`skopeo copy --policy <sigstoreSigned keyPath policy> --registries.d
<use-sigstore-attachments>`), by digest and by tag:

| Image's signatures | skopeo with the key's `policy.json` |
|---|---|
| legacy `.sig`, right key | accepted |
| none | refused: "A signature was required, but no signature exists" |
| legacy `.sig`, wrong key | refused: "invalid signature when validating ASN.1 encoded signature" |
| new-format bundle, right key | refused: "no signature exists" (the bundle is invisible to it) |
| new-format bundle (other key) **and** legacy `.sig` (right key) | accepted |

The last row is the production shape: keyless as a bundle, static as a `.sig` tag. They
coexist without interfering.

**Verifying the static signature needs `--new-bundle-format=false` too.** On a digest that
carries a bundle, cosign 3.1.4's default `verify --key` checks the bundle and stops: it fails
with "transparency log certificate does not match" instead of falling back to the `.sig`
tag. With `--new-bundle-format=false` it finds the right signature. The keyless check is
unaffected by the extra `.sig` tag. Same experiment, an image carrying both:

| `cosign verify` | default | `--new-bundle-format=false` |
|---|---|---|
| `--key` of the legacy `.sig` signer | **fails** | OK |
| `--key` of the bundle signer | OK | fails |

`mise run promote` therefore verifies keyless with default flags and the static key with
`--new-bundle-format=false`. A digest with *only* a legacy signature passes the default verify
too, so a test that never adds a bundle misses this.

**The static signature is uploaded to Rekor.** `--use-signing-config=false` keeps the
default `--tlog-upload=true`, so `cosign verify --key` checks the log entry as it does for
keyless. containers/image doesn't look at Rekor unless a policy sets `rekorPublicKeyPath`.

**Rotation is a procedure, not a re-run of the task.** A host trusts only the keys its
current image's policy names. So: create the new pair under another item title; ship an
image whose policy lists both public keys in `keyPaths`, both files present (one missing
file fails the whole requirement, #479); sign with both keys until hosts have taken that
image; then sign with the new key only and drop the old one from the policy. After a
compromise the same steps apply, re-signing whatever `:latest`/`:sealed` should point at.

## Host enforcement (#418)

`config/container-sigpolicy.bst`, in `stacks/bootc.bst`, makes every krytis host refuse a
`ghcr.io/starlit-os/krytis` image that lacks the static-key signature. It ships:

| Path | Content |
|---|---|
| `/usr/share/containers/policy.json` | `default: reject`; docker scope `ghcr.io/starlit-os/krytis` requires `sigstoreSigned` with `keyPath` `/usr/share/pki/containers/krytis.pub` and `matchRepository`; every other docker image and every other transport is `insecureAcceptAnything` |
| `/usr/share/containers/registries.d/krytis.yaml` | `use-sigstore-attachments: true` for that scope, so the legacy `.sig` tag is read at all |
| `/usr/share/pki/containers/krytis.pub` | the repo's `cosign.pub`, the element's second `kind: local` source |

and an integration command that deletes freedesktop-sdk's accept-all
`/etc/containers/policy.json`, which is searched before `/usr/share`.

What changes for a user: anything that pulls `ghcr.io/starlit-os/krytis` (`bootc upgrade`,
`bootc switch`, `podman pull`) needs the static signature. Other images and local transports
are untouched, including the `containers-storage` installs `generate-disk` and fisherman do
and `mise run switch-local`. Images published before the static key existed are refused, so
`bootc switch` to an old version tag fails.

**Enforced with no opt-in, observed.** bootc v1.17.3's composefs pull
(`crates/lib/src/bootc_composefs/repo.rs`, `pull_composefs_direct`) passes a default
`ImageProxyConfig`, so skopeo runs without `--insecure-policy`, and nothing in bootc or
composefs-oci 0.9.4 sets `insecure_policy`. `--enforce-container-sigpolicy` only matters on
the ostree path, where it refuses a policy whose default is `insecureAcceptAnything`. In
`mise run sigpolicy-test` on 2026-11-03, a plain `bootc switch` to the keyless-only
`26.08.202611011748` digest failed, with nothing staged:

```
error: Switching: Composefs Switching: Checking if image ghcr.io/starlit-os/krytis@sha256:b817c759…
is pulled: Getting container info: Opening image docker://ghcr.io/starlit-os/krytis@sha256:b817c759…:
failed to invoke method OpenImage: A signature was required, but no signature exists
```

The same run then switched to and staged static-signed digest
`sha256:d0e79929af74f35cfd32cf5b2d5ee971c72f90fda9ee07445862224325983b01`,
published by [run 41625659851](https://github.com/starlit-os/krytis/actions/runs/41625659851).

The flip side is that a broken policy blocks every host's next upgrade, which is what
`sigpolicy-check` exists for.

**Existing hosts drop the `/etc` copy when they upgrade.** The same run installed the
pre-policy `26.08.202611011748` image (which has fdsdk's `/etc/containers/policy.json`),
`bootc switch`ed to the new image and rebooted: `/etc/containers/policy.json` was gone and
the shipped policy was in force. The `/etc` three-way merge deletes a file the new image
no longer ships, as long as the host never modified it. A host whose copy *was* edited keeps
it, and that copy wins: such a host enforces whatever it says.

**Recovery if a bad policy ships.** `bootc rollback` returns to the previous deployment
without pulling. On the host itself, writing an accept-all `/etc/containers/policy.json`
overrides the shipped one until it is deleted again.

**Lookup order, measured in the image** (skopeo 1.24.1, as root in a container from
`localhost/krytis:latest`, 2026-11-02):

- `policy.json`: `$HOME/.config/containers/` → `/etc/containers/` → `/usr/share/containers/`.
  With none present, skopeo's error lists exactly those three paths.
- `registries.d`: `/usr/share/containers/registries.d/` is read alongside `/etc`'s.
  Removing `krytis.yaml` from it turned an accepted signed image into "no signature exists".
- All eleven transport names in the shipped policy parse: `atomic`, `containers-storage`,
  `dir`, `docker`, `docker-archive`, `docker-daemon`, `oci`, `oci-archive`, `ostree`, `sif`,
  `tarball`.

**Gate: `mise run sigpolicy-check`**, the last step of `mise run build`. It fails when
`/etc/containers/policy.json` exists, the image's own skopeo can't load the policy, the
default isn't `reject`, a transport is missing or a local one isn't open, a listed key file
is absent (#479), no listed key is `cosign.pub`, or no `registries.d` file enables
`use-sigstore-attachments`. To check that the policy loads offline, it runs `skopeo copy
oci:/nonexistent…`: skopeo loads the policy before it opens the source, so a good policy
leaves only the missing-`index.json` error. Each failure class was produced on purpose
with a derived image and caught. It can't watch a refusal, which needs a registry.

**VM test: `mise run sigpolicy-test`.** It installs the image (or, with `--upgrade-from
<ref>`, a pre-policy one, and upgrades it through a local registry at `10.0.2.2`). It then
asserts the policy in force, a refused `bootc switch` to `--refuse` (default: the
`26.08.202611011748` digest) and an accepted one to `--accept` (default `:latest`). Before
allocating the disk it rejects a stale `--image` tag that lacks the `/usr` policy layout,
and checks both published refs with cosign on the host. `generate-disk` fallocates `--size`,
so the host needs that much free, plus about 7 GB per image the test pulls or pushes.
`generate-disk` can't install a digest reference (podman save/load rejects it), so
`--upgrade-from` tags it locally first, as `localhost/krytis-sigpolicy-from:latest`.
`generate-disk` copies that tag into **root's** podman store too, out of reach of the
rootless cleanup. The tag is fixed so reruns replace it rather than stacking one 7 GB copy
per run (the per-run `$$` tag did that); cleanup removes it only if sudo is still cached,
and otherwise prints the `sudo podman rmi`. The complete 2026-11-03 run upgraded from the
pre-policy image, rebooted into the locally built policy image, observed the keyless
refusal, and staged the published static-signed digest.

## Hosts can't check the keyless signature

What *can't* happen is a host checking the keyless signature, which is worth knowing
before someone tries to "just add a `policy.json`" for it.

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

No upstream fix has landed (as of 2026-11-02). [`containers/image#2235`](https://github.com/containers/image/pull/2235)
("Accept URI for Sigstore Signed Images") would have added URI-SAN support to the `fulcio`
block, but after stalling on DCO/review friction from February 2024 it was **closed
unmerged** on 2025-08-26 when `containers/image` folded into the `containers/container-libs`
monorepo (since renamed `podman-container-tools/container-libs`). The demand moved to
[`podman-container-tools/container-libs#34`](https://github.com/podman-container-tools/container-libs/issues/34)
("Extend Fulcio signature acceptance options to support 'workflow identity'"), and
[`podman-container-tools/container-libs#625`](https://github.com/podman-container-tools/container-libs/pull/625)
(opened 2026-02-04) implements it: a `buildSignerURI` match on Fulcio's OID
`1.3.6.1.4.1.57264.1.9` extension, closing container-libs#34. As of 2026-11-02 it is open and blocked: all
checks pass, but no review has been submitted at all. One contributor said LGTM in a
comment, and two pings to the maintainers got no reply. Last activity was 2026-05-25.

container-libs#625 is not the only candidate design. On 2026-09-02 a commenter on container-libs#34 proposed
`subjectBuildConfig`, which can't be combined with `subjectEmail`. It does exact-match only
on the typed extensions `.12` (source repository URI), `.14` (source repository ref) and
`.18` (build config URI), and leaves `.9`, the extension container-libs#625 matches, as a later addition.
A prototype is on a fork branch; no PR and no maintainer reply as of 2026-11-02. So the
`policy.json` field name for workflow identity is unsettled, not just unmerged. Don't
sketch a keyless policy against either shape.

The maintainer's position is on record in
[podman#29973](https://github.com/podman-container-tools/podman/pull/29973), Podman's own
design doc for signing its machine-OS images, which hit the same gap. On 2026-10-21
`mtrmac` confirmed c/image has no `policy.json` option for workflow-identity fields: there
is "demand for supporting this … but I think it rather expands the scope."

So the timeline is: one design merges, *then* it reaches the `containers/image` version
`bootc` vendors. Treat host-side keyless enforcement as unavailable, not imminent.

The workaround is a long-lived static key, signed alongside the keyless signature, which
`policy.json` *can* verify with `keyPath`. It means storing and rotating a key, the exact
thing keyless signing was chosen to avoid. But it isn't only a stopgap. In the same
podman#29973 thread, `mtrmac` argued that a static key can be recovered after a compromise:
generate a new key, re-sign past versions, and ship a policy that trusts only the new one.
Public-instance Fulcio has no equivalent, because you don't control its root and can't
revoke an individual signature. His best fallback there was renaming the workflow and
re-signing everything under the new identity. Keyless enforcement would therefore not be a
strict upgrade even after upstream lands. The owner weighed that under AGENTS.md's Security
Gate and chose the static key on 2026-11-02 (#418); § Static-key signature (#418) is what
shipped. The original design for it is at `docs/design/cosign-keyless-signing.md` §§ 3–4.
Revisiting keyless enforcement once upstream lands is #1504.

## Where a `policy.json` has to live, and why the sketched path is wrong

*Source: zirconium-hawaii `4229691` → `d4e641b` → `f251073` — three commits, one thread.*

zirconium-hawaii ships a container signature policy and learned all three of these the
hard way. `config/container-sigpolicy.bst` (§ Host enforcement (#418)) follows them.

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

**What krytis took.** krytis inherits
`/etc/containers/{policy.json,registries.conf,registries.conf.d/000-shortnames.conf,registries.d/default.yaml}`
from `components/containers-common.bst` (`files/fakecap-manifest.tsv`). Only `policy.json`
shadows anything, so only it is deleted. `registries.d` is merged from `/usr/share` and
`/etc` rather than overridden, and `registries.conf` plays no part in signature checks, so
neither is moved. The old design's sketch, an element writing into `/etc/containers`, would
have landed on paths fdsdk already owns. That is the wrong destination per point 1.

Point 3 is the one thing the design already got right: it uses
`"default": [{"type": "reject"}]`. What is missing is *why* that is mandatory rather than
merely strict — a permissive default is what breaks bootc's ostree backend, so the
per-transport `insecureAcceptAnything` expansion is load-bearing verbosity, not something
to simplify away later.
