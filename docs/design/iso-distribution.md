# ISO Distribution

How the live ISO reaches people who are not GitHub-authenticated members of this
project, and why each part of that path is the way it is.

Implemented by `.github/workflows/build-iso.yml`'s `publish_r2` path (#867).
Operational notes for changing that workflow live in
`docs/skills/ci-runner.md` § R2 publish (`publish_r2`, issue #867).

## The problem the GitHub artifact does not solve

`build-iso.yml` has uploaded the ISO as an `actions/upload-artifact` artifact
since #844. That is adequate for internal testing and useless for distribution:

- It expires after **7 days** (`retention-days: 7`).
- Downloading it requires a **GitHub account with access to this repository** —
  artifacts are not public even on a public repo without going through the API.
- The download is a **ZIP wrapper** around the ISO, not the ISO, so it cannot be
  `curl`ed, `dd`ed, or handed to a friend as a URL.

The artifact therefore keeps its original internal-testing purpose on every
path that still needs it — but **a run that successfully publishes to R2 does
not upload one**. Once `iso.ririi.dev` serves those exact bytes, the artifact is
a redundant 4.5 GB copy of a publicly fetchable file, charged against Actions
storage for a week. Unsealed builds and sealed-but-unpublished test dispatches
still upload, because neither has another way out of the runner.

The skip is conditioned on the publish having *succeeded* (`if: ${{ !(inputs.sealed && inputs.publish_r2) || failure() }}`),
which is load-bearing. GitHub steps run on success by default, so a bare
"skip when publishing" condition would also discard the ISO when the upload or
the public-download check failed — throwing away ~40 minutes of build that the
next run's `git clean -ffdx` makes unrecoverable. With the `failure()` clause a
failed publish falls back to the artifact and the retry can skip the rebuild.

## Why Cloudflare R2

The object is ~4.5 GB and the entire point is that it gets downloaded
repeatedly by people who are not us. That makes **egress**, not storage, the
cost that decides the provider:

| | Storage (4.5 GB) | Egress per 100 downloads (~450 GB) |
|---|---|---|
| **Cloudflare R2** | free (under 10 GB-month tier) | **$0 — R2 never charges egress** |
| AWS S3 | ~$0.10/mo | ~$40 |
| Google Cloud Storage | ~$0.09/mo | ~$54 |

R2's zero-egress pricing is not a promotional tier or a fair-use allowance; it
is the product's defining characteristic. For an artifact whose success metric
*is* download volume, every alternative charges more precisely when the project
is doing well. Hosting the ISO as a GitHub Release asset would also be free, but
caps single assets at 2 GB — well under this ISO.

The bucket is fronted by a Cloudflare **Custom Domain** (`iso.ririi.dev`) rather
than the bucket's default `*.r2.dev` URL. That reuses the existing `ririi.dev`
zone (already serving `bst-cache.ririi.dev` for bow), gives a stable
project-controlled hostname that survives a provider change, and puts the object
behind Cloudflare's CDN instead of only R2's origin.

## Sealed only — never the unsealed build

`publish_r2` is a **separate** `workflow_dispatch` input from `sealed`, and
`publish_r2=true` with `sealed=false` fails the job before any build work
happens.

The unsealed ISO exists so that ISO-assembly changes can be tested without
involving the signing keys. It installs an image whose UKI is not signed by the
project's Secure Boot keys. Serving that at a public "download Krytis here" URL
would invert the trust model the sealed build exists to establish: a user cannot
tell the two apart from the filename alone, and the unsigned one is the one that
boots anywhere without complaint.

Keeping the two inputs independent (rather than making `publish_r2` imply
`sealed`) also means a sealed *test* dispatch does not have to overwrite the
object the public URL points at — testing the sealed build path and publishing
are different intentions.

## Latest only — one object, overwritten

The bucket holds exactly two objects, both overwritten in place on every
publish:

```
krytis-live-sealed.iso
krytis-live-sealed.iso.sha256
```

No dated archive, no `builds/<date>/` prefix, no retention of the previous ISO.

**Known limitation, accepted deliberately.** The upload is a plain object
overwrite, not an atomic swap. A client mid-download across a very long-lived
connection — or one re-issuing HTTP Range requests without `If-Range` — during
the brief window of a publish could in principle mix bytes from two builds.
Mitigations available to any downloader today: the `.sha256` companion object,
and the `implantisomd5` checksum embedded in the ISO itself, checkable from the
boot menu before installing. If this ever bites in practice, the fix is to
upload to a content-addressed key (`builds/<sha256>.iso`) and turn
`krytis-live-sealed.iso` into a 302 redirect via a Bulk Redirect rule or a small
Worker — deliberately not built in advance for a download URL with no observed
traffic pattern yet.

## Cost model — and the one way it breaks

R2's free tier is **10 GB-month of storage**, billed as the monthly average of
each day's *peak* storage, plus 1M Class A and 10M Class B operations. Against
that:

| | Usage | Free tier | Headroom |
|---|---|---|---|
| Storage | 4.5 GB steady state | 10 GB-month | ~2.2x |
| Class A (writes) | ~800 `UploadPart` per publish | 1M/month | ~1250 publishes |
| Class B (reads) | 1 `GetObject` per uncached download | 10M/month | effectively unbounded |
| Egress | unbounded | free | n/a |

A publish day peaks near 9 GB — the old object is still live while the new
upload's parts accumulate — but that spike contributes 9/30 = 0.3 GB-month, so
it is not a concern.

**The one thing that does break this: unfinished multipart uploads are billed as
storage and do not appear in the bucket's object listing.** A cancelled workflow
run or a dead VPS runner strands ~4.5 GB of parts indefinitely, and the bucket
still shows exactly two objects while storage climbs per failed run — a cost
with no visible cause. The `krytis-iso` bucket therefore carries an **object
lifecycle rule aborting incomplete multipart uploads after 1 day**
(`AbortMultipartUpload` is a free operation). Anyone recreating this bucket must
recreate that rule.

These numbers are also the answer to a future "let's keep dated archives"
proposal: the third retained ISO leaves the free tier.

## Credential and resource inventory

| Thing | Value | Where |
|---|---|---|
| Bucket | `krytis-iso` | Cloudflare R2, Standard storage class, Automatic location |
| Lifecycle rule | abort incomplete multipart uploads after 1 day | bucket → Settings |
| Public hostname | `iso.ririi.dev` | R2 Custom Domain, proxied, Cloudflare-managed TLS |
| Cache rule | Hostname = `iso.ririi.dev` → Eligible for cache; Edge TTL "use cache-control header if present, use default Cloudflare caching behavior if not" (API `respect_origin`) | `ririi.dev` zone → Caching → Cache Rules |
| S3 endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` | derived from `R2_ACCOUNT_ID` |
| `R2_ACCOUNT_ID` | Cloudflare account ID | GitHub Actions repo secret |
| `R2_ACCESS_KEY_ID` | token's Access Key ID | GitHub Actions repo secret |
| `R2_SECRET_ACCESS_KEY` | token's Secret Access Key | GitHub Actions repo secret |

The token is an **Account** API token (not a User token — a user token dies with
its creator's account membership) with **Object Read & Write** permission scoped
to the `krytis-iso` bucket only. Not `Admin Read & Write`, which can create and
delete buckets. Bucket scoping is a step inside the account-level token flow in
the dashboard (R2 → Overview → Account Details → API Tokens → Manage); there is
no longer a per-bucket token panel.

Storage class matters: the free tier does not apply to Infrequent Access, and IA
carries a 30-day minimum storage duration that a monthly-overwritten object
would pay twice for. Standard is correct here.

### Why GitHub Actions secrets rather than Proton Pass / fnox

This repo splits credential storage by whether a human ever needs the credential
locally. Signing keys, Buildbarn tokens and the VPS SSH host live in Proton Pass
because a developer uses them on their own machine. The R2 credentials have no
local use case at all — nothing outside `build-iso.yml` ever uploads to this
bucket — so they follow the `TRACKING_APP_*` precedent (#699/#793) and live as
plain GitHub Actions repo secrets. The bucket name is not sensitive and is
hardcoded in the workflow rather than stored as a secret.

`rclone` receives them as `RCLONE_CONFIG_R2_*` environment variables scoped to
the single upload step. No `rclone.conf` is ever written, which matters more
than usual here: the VPS runner is an always-on persistent box, so a config file
would outlive the job that needed it.

The upload step also sets `RCLONE_CONFIG_R2_NO_CHECK_BUCKET: "true"`. This
is a direct consequence of the scoping decision above rather than a tuning
choice: rclone verifies a bucket exists (and would create it) before its
first upload, and those are bucket-level operations an **Object**-scoped
token deliberately cannot perform. rclone's S3 documentation calls this out
specifically for R2 tokens with the Object Read & Write permission. The
alternative way to satisfy the check is to widen the token to Admin Read &
Write — trading one line of config for a CI credential that can delete
buckets.

### Rotation

1. Create a replacement Account API token (same Object Read & Write scope on
   `krytis-iso`) in the Cloudflare dashboard.
2. `gh secret set R2_ACCESS_KEY_ID --repo starlit-os/krytis` and likewise
   `R2_SECRET_ACCESS_KEY`. `R2_ACCOUNT_ID` does not change.
3. Revoke the old token.

There is no in-flight upload to drain — `rclone` runs inside a single
short-lived step, so the only way to interrupt one is to rotate during an active
publish run.

## Verifying a publish

`build-iso.yml` verifies its own publish in the same run, before the job goes
green: it compares the published object's `content-length` **and** the published
`.sha256` against the ISO it just built. Both checks are deliberate — a
content-length match with a checksum mismatch means Cloudflare served an
equally-sized *older* object, the exact failure a size-only check misses.

From outside CI:

```bash
curl -sI https://iso.ririi.dev/krytis-live-sealed.iso | head -5
curl -sL https://iso.ririi.dev/krytis-live-sealed.iso.sha256
```

Expect `HTTP/2 200` and `content-type: application/x-iso9660-image`.

> **Reachability is not a readiness signal for this hostname.** The `ririi.dev`
> zone has a wildcard `*.ririi.dev` A record pointing at materia, so
> `iso.ririi.dev` resolved — and returned responses — before the R2 Custom
> Domain existed at all. A 200 alone proves nothing; the `content-type` above,
> or the R2 dashboard's "Active" status, is what distinguishes the bucket from
> the wildcard.
