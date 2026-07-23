# CI Runner Reference

Load when working on GitHub Actions workflows, the self-hosted runner container, or BST cache in CI.

## Self-Hosted Runner in Podman

The runner container (`Containerfile.runner`) runs as root with `--privileged` — required for bubblewrap (BST sandboxing). Managed via `mise runner:*` tasks.

### Required flags / env

| Flag / env | Why |
|---|---|
| `--privileged` | bubblewrap requires unprivileged user namespaces, which need privileged mode in podman |
| `RUNNER_ALLOW_RUNASROOT=1` | GitHub Actions runner refuses to start as root without this |
| `--replace` on `podman run` | prevents "container name already in use" errors from stale stopped containers |

### PAT requirements

Fine-grained PAT with **Administration: Read and Write** on `starlit-os/krytis`. Stored as podman secret `gh-token`. Used only for deregistration (obtaining a remove token).

### Deregistration

**Do not rely on the container's EXIT trap.** The GitHub Actions runner binary intercepts SIGTERM internally and may not exit within podman's stop timeout, preventing the trap from firing. Instead, `runner:stop` deregisters via the GitHub API directly before stopping the container:

```bash
RUNNER_ID=$(gh api repos/starlit-os/krytis/actions/runners \
    --jq ".runners[] | select(.name == \"${RUNNER_NAME}\") | .id")
gh api -X DELETE "repos/starlit-os/krytis/actions/runners/${RUNNER_ID}"
```

### Stale offline runners

After an unclean shutdown the runner stays registered as `offline`. `runner:start` auto-removes any offline registration with the same name before re-registering. To remove one manually:

```bash
gh api repos/starlit-os/krytis/actions/runners --jq '.runners[] | "\(.id) \(.name) \(.status)"'
gh api -X DELETE repos/starlit-os/krytis/actions/runners/<id>
```

### Dependencies (Ubuntu 24.04 base)

`libicu74` must be installed explicitly in the Containerfile. The runner's bundled `installdependencies.sh` doesn't work in a separate Docker layer (no apt lists). Without it the runner binary fails with "Libicu dependencies missing for .NET Core 6.0".

---

## BST Cache in CI

### casd quota

`cache.quota` in `buildstream.conf` controls the local CAS size. **4G is too small** for a full build — casd fills it, can't evict active blobs, and crashes:

```
OutOfSpaceException: disk usage above maximum quota and no inactive blobs are available for deletion
terminate called after throwing an instance of 'std::system_error'
```

Use **50G** for a full `cache-warm` build on a machine with adequate disk.

### `actions/cache` path spec determines the version hash

`actions/cache` computes an internal **version** from the `path:` input (a hash of paths + compression). This version is part of every lookup — including restore-key prefix matching. **Changing the path spec invalidates all prior cache entries, even those with matching key prefixes.**

```yaml
# These two configs produce different version hashes and cannot restore from each other:
path: ~/.cache/buildstream

path: |
  ~/.cache/buildstream
  !~/.cache/buildstream/sources
```

When changing `path:`, expect a cold-start run. Subsequent runs will find the cache.

### What to cache

The BST cache directory layout:

| Path | Content | Cache? |
|---|---|---|
| `cas/objects/` | Built artifact blobs | ✅ yes |
| `artifacts/` | Artifact refs (34 MB) | ✅ yes |
| `cas/tmp/` | casd staging (~18 GB) | ❌ no — transient |
| `logs/` | Build logs | ❌ no |
| `sources/` | Fetched source archives | ❌ no |
| `elementsources/` | Element source metadata | ❌ no |

When using `actions/cache`, pin the paths to exactly `cas/objects` and `artifacts`:

```yaml
path: |
  ~/.cache/buildstream/cas/objects
  ~/.cache/buildstream/artifacts
```

The self-hosted runner with a volume mount already persists the CAS between runs — `actions/cache` is only needed when a GitHub-hosted runner job will consume the cache.

### Clearing the CAS

BST has no native `artifact gc` command. To fully clear the cache:

```bash
bst artifact delete '**'          # remove all artifact refs
rm -rf ~/.cache/buildstream/cas/objects/ ~/.cache/buildstream/cas/tmp/
mkdir -p ~/.cache/buildstream/cas/objects/
```

### Freedesktop SDK remote cache errors

`cache.freedesktop-sdk.io:11001` (their BuildGrid CAS) occasionally returns:

```
OutOfSpaceException: Insufficient storage quota
```

This is a server-side error on their infrastructure — their CAS is full. BST logs it as `WARNING`/`FAILURE` for the cache pull but falls back to fetching sources from upstream and building locally. The build continues; it's just slower. No action needed on our side.

---

## uv sync in CI

Mise's experimental `[deps.uv]` feature (`outputs = [".venv/"]`) skips `uv sync` on re-runs if `.venv/` already exists. On a persistent self-hosted runner this means retried jobs find the venv but without the expected packages if the first run was incomplete.

**Fix:** add an explicit `uv sync` step after `mise bootstrap`:

```yaml
- name: Install Python dependencies
  run: uv sync
```

Don't rely on `[deps.uv]` auto-run for correctness in CI.

### `bst` is not on PATH — use `uv run bst`

`bst` is installed by `uv sync` into the project `.venv`; it is not placed on PATH. CI steps that call the bare `bst` binary fail with `bst: command not found` (exit 127). This bit the `cache-warm` workflow, which invoked `bst build …` / `bst show …` directly while `track-bst-sources.yml` correctly used `uv run bst …`.

**Convention:** every CI step that runs BuildStream must invoke it as `uv run bst …` (or `mise bst …`, which wraps the same thing). Never assume `bst` is on PATH.

---

## GitHub Actions: SHA Pinning and Org Allowlist

### SHA pinning — let the linter handle it

Do not manually look up and pin action SHAs when writing a new workflow. Write the version tag (`uses: actions/checkout@v4`) and commit. The linter (`mise lint`) runs `actionlint` which auto-upgrades floating tags to full commit SHAs with a version comment. The pinned SHA lands in the same PR automatically.

### Org allowlist

The `starlit-os` org has an allowlist of permitted external actions. Any `uses: <owner>/<repo>` not already on the list will be blocked at runtime with a permissions error — the workflow job simply won't start.

When adding a new action to any workflow, check whether `<owner>/<repo>` is already allowlisted. If not, prompt the user to add it before the PR is merged. The allowlist is managed in the org's GitHub Actions settings.

## Buildbarn CAS (Quadlet)

krytis owns a Buildbarn deployment (`bb-storage` + `bb-remote-asset`) on the
self-hosted runner box, providing both a source cache (fixes upstream churn
like #233's CachyOS 404) and an artifact cache for krytis-specific elements.
See #234 and its sub-issues for the design rationale.

### Why Quadlet instead of `podman run` (unlike the runner)

The self-hosted runner (`mise runner:*`) is manually started/stopped around
CI activity — a `podman run` wrapper fits that lifecycle. Buildbarn is a
**persistent** host service that should survive reboots and restart on
failure, so it's modeled as Podman Quadlet units (`quadlet/buildbarn/`)
instead: `systemctl --user start/stop bb-storage bb-asset` after
`mise buildbarn:install` copies the units into
`~/.config/containers/systemd/` and reloads the user systemd manager.
There's no `buildbarn:start`/`buildbarn:stop` mise task — quadlet-generated
`.service` units already give us that via `systemctl`, and duplicating it in
a mise task would just be a less capable wrapper around the thing systemd
already provides.

### Quadlet-generated units cannot be `systemctl enable`d

`systemctl --user enable --now bb-storage.service` fails with:

```
Failed to enable unit: Unit /run/user/1000/systemd/generator/bb-storage.service is transient or generated
```

Quadlet units aren't real unit files on disk — they're generated into
`/run/user/<uid>/systemd/generator/` (or the system equivalent) by
`podman-system-generator` at every `daemon-reload`, and `systemctl enable`
only works on persisted unit files it can symlink. The `[Install]` section's
`WantedBy=` is instead honored **by the generator itself**, which creates
the `default.target.wants/bb-storage.service -> ../bb-storage.service`
symlink directly inside `/run` as part of generation — confirm with
`ls /run/user/<uid>/systemd/generator/default.target.wants/`. So the correct
lifecycle is just `systemctl --user start`/`stop`; there is no `enable`/
`disable` step, and `mise buildbarn:install` no longer attempts one.

### Rootless (`--user`) first, system-level later

The units currently target **rootless, user-level** Quadlet
(`~/.config/containers/systemd/`, `WantedBy=default.target`,
`systemctl --user`) rather than system-level
(`/etc/containers/systemd/`, `WantedBy=multi-user.target`, `sudo systemctl`)
— deliberately, so this can be brought up and torn down on a normal dev
box with `mise buildbarn:install` / `buildbarn:uninstall` while the design
is still being verified, with no `sudo` required. `%h` in a Quadlet unit
resolves to the *running user's* home directory in both modes, so the unit
files themselves don't need to change when this eventually moves to the
shared runner box as a system-level service — only the install
destination, `WantedBy=` target, and the `systemctl`/`journalctl` invocation
(drop `--user`) change. When that migration happens, re-run the
`quadlet -dryrun` check (below) against both modes, since the generator
resolves `%h` differently for a system unit (root's home, not the invoking
user's) if the service isn't given an explicit `User=`.

Rootless user services stop when the login session ends unless
`loginctl enable-linger <user>` has been run — not needed for interactive
local testing, but required before this is useful unattended even in
user-mode.

### mTLS: SAN-based push/pull split, not CN

Buildbarn's `AuthenticationPolicy.tlsClientCertificate` supports a
`validation_jmespath_expression`, but its docs explicitly recommend using it
for **authentication** decisions, not **authorization** — a failed match
returns `UNAUTHENTICATED`, not `PERMISSION_DENIED`, so gating write access
this way muddies the error semantics of a not-yet-registered pull cert vs. a
valid pull cert trying to push. Instead: one CA signs two client certs (SAN
`spiffe://krytis/ci-push` for CI, `spiffe://krytis/pull` for everyone else),
and the actual push/pull split is enforced per-operation via `putAuthorizer`/
`pushAuthorizer` (`jmespathExpression` matching the SAN) vs. `getAuthorizer`/
`fetchAuthorizer` (`allow: {}` for any cert signed by the CA). CN was
considered and rejected — SAN is what Buildbarn's own docs use for this kind
of identity check.

### Volume naming for Quadlet-referenced `.volume` units

A `.container` unit's `Volume=` line referencing a sibling `.volume` unit
must keep the **`.volume` suffix** — `Volume=buildbarn-storage-cas.volume:/data/storage-cas`.
Dropping the suffix (`Volume=buildbarn-storage-cas:/data/storage-cas`) looks
plausible but silently breaks unit-reference detection: `/usr/libexec/podman/quadlet
-dryrun` shows the generated `ExecStart=` falls back to treating the name as
a literal podman volume (`-v buildbarn-storage-cas:...`) instead of the
managed `systemd-<name>` volume the sibling `.volume` unit actually creates
(`-v systemd-buildbarn-storage-cas:...`) — two different volumes, one of
which is never created by the `-volume.service` unit. Always dry-run new
quadlet units with `QUADLET_UNIT_DIRS=<dir> /usr/libexec/podman/quadlet
-dryrun -no-kmsg-log` and grep the `ExecStart=` line for the `systemd-`
prefix on every volume reference before trusting the unit.

### Rootless bridge networking needs nft/iptables — use `Network=host` instead

A custom Quadlet `.network` unit (`podman network create`, netavark backend)
failed on this dev box with:

```
Error: netavark: code: 3, msg: modprobe: ERROR: could not insert 'ip_tables': Operation not permitted
iptables v1.8.13 (legacy): can't initialize iptables table `nat': Table does not exist
```

Rootless bridge networking needs NAT (iptables/nftables) support in the
user namespace, which isn't guaranteed to be available (missing `nft`
binary, restricted kernel module loading, etc.). Buildbarn's own two
services don't need a bridge network's DNS-by-container-name convenience
badly enough to justify that fragility for local/dev use: `bb-storage` and
`bb-asset` both use `Network=host` and reach each other over `localhost`
at their published ports instead of a `bb-storage:8981`-style container DNS
name. This does mean the two services can no longer share port `8981`
internally — each needs a distinct host-facing port baked directly into
its own `grpcServers.listenAddresses` (no publish-time remapping exists
under `Network=host`).

If the shared runner box turns out to support rootless bridge networking
fine, reintroducing a `.network` unit there is a reasonable follow-up —
just re-run the `modprobe ip_tables`/`nft` check first rather than assuming
it'll work because it works elsewhere.

### `Exec=` takes the config path positionally, not as `-config <path>`

`Exec=-config /config/storage.jsonnet` produces `Usage: bb_storage
bb_storage.jsonnet` and exits — both `bb_storage` and `bb_remote_asset`
take the jsonnet config path as a bare positional argument. `-config` looks
like a plausible flag by analogy with other Buildbarn-adjacent tooling but
isn't one here.

### TLS server cert: `serverKeyPair.files`, not `serverCertificate`/`serverPrivateKey`, and `refreshInterval` is mandatory

The `tls.proto` `ServerConfiguration` message **reserves** the old flat
`server_certificate`/`server_private_key` fields (present in some outdated
examples floating around) in favor of a `server_key_pair` oneof:
`inline: {certificate, privateKey}` (raw PEM strings — forces
`importstr`, see below) or `files: {certificatePath, privateKeyPath,
refreshInterval}`. Use `files` — it also means the daemon can hot-reload a
rotated cert without a restart. `refreshInterval` looks optional but isn't:
leaving it unset produces `Failed to parse refresh interval: proto: invalid
nil Duration`. Set it explicitly even for a cert that's never rotated
(e.g. `'3600s'`).

### jsonnet `importstr`/`import` require a string literal path

`importstr certDir + '/ca.crt'` (concatenating a local variable) fails with
`RUNTIME ERROR: Computed imports are not allowed`. The path has to be
written out in full at each call site — no path-prefix variable, no
helper function wrapping it.

### mTLS authorization requires an explicit metadata-extraction expression — it isn't automatic

Setting `tlsClientCertificate.clientCertificateAuthorities` is enough to
*authenticate* a connection (verify the client cert against the CA), but on
its own it does **not** populate `AuthenticationMetadata` for any later
Authorizer to read. `AuthorizerConfiguration`'s `jmespath_expression`
variant runs against `{authenticationMetadata, files, instanceName}` — if
`authenticationMetadata.public`/`.private` were never populated, an
expression like `contains(authenticationMetadata.public.uris, ...)`
simply evaluates against a null/missing field. The
`tlsClientCertificate` policy needs its own
`metadataExtractionJmespathExpression` (e.g. `` `{public: {uris: uris}}` ``
— same `{dnsNames, emailAddresses, uris}` SAN context as the validation
expression) to actually carry the cert's SAN into
`AuthenticationMetadata.public` where the per-operation Authorizer can see
it. Two separate jmespath expressions, two separate jobs: validation
decides *whether* the handshake authenticates; metadata-extraction decides
*what* gets handed to authorization.

### A raw TLS handshake succeeding without a client cert doesn't mean mTLS isn't enforced

`openssl s_client -connect host:port` (no `-cert`/`-key`) completing with
`Verify return code: 0 (ok)` only proves the *server's* cert validated —
it says nothing about whether the connection would be authorized to make an
actual gRPC call. Buildbarn's TLS client-cert policy operates at the gRPC
interceptor layer (per the client-cert config's own docs: a validation
failure returns gRPC `UNAUTHENTICATED`, not a TLS handshake abort) so the
TCP/TLS layer deliberately completes even for an unauthenticated peer.
Confirming the push/pull split actually holds requires a real gRPC call
(e.g. `bst source push`/`bst artifact push` once #339/#340 wire
`project.conf` at this remote) — a bare `openssl s_client` probe is not
sufficient evidence either way.

### Freshly created named volumes need `persistent_state` pre-created

Neither `bb_storage` nor `bb_remote_asset` create their own
`persistent_state` subdirectory inside a brand-new (empty) data volume —
first start fails with `Failed to open persistent state directory ...: no
such file or directory`. `mise buildbarn:install` seeds each of the four
named volumes with an empty `persistent_state/` dir via a throwaway
`busybox` container before starting the services; skip this step and a
fresh volume will not come up.

### Server cert SAN must include the actual connecting hostname

A client connecting to `https://<host>:<port>` fails with `Peer name <host>
is not in peer certificate` if the server cert's SAN list only has the
in-container aliases (`localhost`, `bb-storage`, `bb-asset`, `127.0.0.1`)
and not the hostname clients actually dial. `mise buildbarn:certs-init`
now adds `$(hostname)`/`$(hostname -f)` to the SAN automatically. If the
CA already exists (the common case — `certs-init` is idempotent and skips
everything once `ca.crt` is present), the server cert has to be **manually
reissued** with the corrected SAN using the existing `ca.key`/`server.key`
— reissuing the leaf server cert doesn't invalidate the CA or any already-
issued client cert, only the CA rotation would.

### `project.conf`'s `source-caches:`/`artifacts:` need separate `type: index` / `type: storage` entries

A single unsplit cache entry (the implicit `type: all`) assumes **one**
endpoint serves both the remote-asset index and the CAS storage. Buildbarn
splits these across two services/ports (`bb-asset` = index, `bb-storage` =
storage) — pointing a single `type: all`-implied entry at `bb-asset` alone
fails every push with `UNIMPLEMENTED: unknown service
build.bazel.remote.execution.v2.ContentAddressableStorage` (bb-asset simply
doesn't implement the CAS API). Fix: two entries per cache list, one
`type: index` at the `bb-asset` port, one `type: storage` at the
`bb-storage` port — matches the shape of Buildbarn's own docker-compose
reference example almost exactly.

### bb-remote-asset's HTTP fetcher can't serve `FetchDirectory` — use the `error` fetcher for a pure cache

BuildStream's source cache pushes/fetches multi-file sources as CAS
Directory trees, not single blobs. `fetcher: { http: {} }` (the shape used
in every Buildbarn reference example) can only serve blob fetches over
HTTP, and every push fails with `PERMISSION_DENIED: FetchDirectory: 7: HTTP
Fetching of directories is not supported!` — the asset service tries an
existence-check `FetchDirectory` internally as part of handling `Push`,
hits the unsupported path, and aborts the whole push. This is also simply
the wrong fetcher for krytis's use case: `bb-asset` is meant to be a *pure
cache* (krytis's own `bst` invocations do the real upstream fetch and push
the result here) — it should never reach out on its own. `fetcher.proto`
has a purpose-built `error` variant for exactly this ("can be wrapped by
CachingFetcher for a Push/Fetch service without any server side
downloads"): `fetcher: { 'error': { code: 5, message: '...' } }` (code `5`
= `NOT_FOUND`) makes a cache miss behave like an empty cache instead of
attempting a doomed live fetch. Note the quotes around `'error'` — it's a
jsonnet/Go-reserved-adjacent keyword and parses as a syntax error unquoted.

### First-deploy verification

All of the above was found and fixed by actually running
`mise buildbarn:certs-init` → `mise buildbarn:install` →
`mise buildbarn:status` end-to-end on a rootless dev box, not by reading
docs alone. Full round trip verified against #339's `project.conf` wiring:
with `~/.cache/buildstream` **completely wiped**, `bst source push
core/linux-cachyos.bst` succeeded against the local remote, and a
subsequent `bst source fetch core/linux-cachyos.bst` pulled the source
entirely from `melog:7981`/`melog:7982` — zero requests to the upstream
CachyOS CDN. This is the actual #233 resilience scenario, proven working
end-to-end, not just plausible from reading the design.

Still open: CI-side push wiring (`cache-warm.yml` generating a push-enabled
`buildstream.conf` with CI's `ci-push` cert from a GitHub Actions secret)
is deferred until Buildbarn is actually deployed on the shared runner box
— that's a Security Gate item (secret provisioning) that needs a human
decision, not something to wire silently. Local verification used a
hand-written `~/.config/buildstream.conf` user-config override (not
committed) with `type: index`/`type: storage` split entries mirroring
`project.conf`, pointed at the same `ci-push` cert `certs-init` already
generates locally.

### Artifacts need the same `type: index`/`type: storage` split as sources

Unlike the initial assumption ("artifacts only need CAS + ActionCache,
both served by `bb-storage` alone"), BuildStream's artifact protocol also
resolves artifact refs via the Remote Asset Fetch service, same as
sources. A single unsplit entry against `bb-storage` alone fails
immediately with `Configured remote does not implement the Remote Asset
Fetch service. Please check remote configuration.` — `project.conf`'s
`artifacts:` needs the identical `type: index` (at `bb-asset`) /
`type: storage` (at `bb-storage`) pair as `source-caches:` (#339), not the
single-entry shape shown in BuildStream's own "Global caches" user-config
docs example (that example assumes one combined server, which isn't our
topology).

### Artifact cache verified live: real pushes into the krytis remote during a bootstrap build

With `~/.cache/buildstream` wiped (left over from #339's source-cache
wipe test) and `mise bst build core/linux-cachyos.bst` running, the log
shows real `Pushed artifact <key> -> https://melog:7981` /
`Pushed data from artifact <key> -> https://melog:7982` lines for elements
as they complete (e.g. `freedesktop-sdk.bst:bootstrap/build/python3.bst`,
`freedesktop-sdk.bst:bootstrap/base-sdk/binary-seed.bst`) — confirming the
write path (mTLS push auth, `type: index`/`type: storage` routing) works
under real build load, not just a synthetic single-element push/pull like
#339's test. A one-off `UNAUTHENTICATED: Client provided no X.509 client
certificate` warning appeared on the very first remote-init attempt and
self-resolved on retry — treat a single transient auth warning at startup
as noise if subsequent pushes succeed; only worry if it repeats per-element.

## Deployed remote: bow (materia), JWT bearer token instead of mTLS

The design above (mTLS: CA + per-role client certs) was the **local
dev-test** design, verified against a Buildbarn instance on the dev
workstation. krytis's own `project.conf` now points at a real deployed
instance instead — `bst-cache.ririi.dev:7981`/`:7982`, on `bow`, managed
by a separate repo (`materia`, a GitOps Podman orchestration project —
see `specs/plans/issue-28-bst-cache-krytis.md` and
`specs/plans/issue-28-krytis-handoff.md` there for the full server-side
design, deployment, and handoff). **The auth model changed** during that
deployment — not a preference, a hard constraint discovered live:

### HS256 (mTLS's originally-planned JWT successor) doesn't work — Buildbarn requires an asymmetric algorithm

Buildbarn's JWT signature validator only accepts asymmetric public keys.
go-jose v3's `JSONWebKey.Valid()` has no `case []byte:` (returns `false`
for symmetric/`oct` keys — go-jose issue #314), and
`bb-storage`'s `NewSignatureValidatorFromJSONWebKeySet` type switch only
handles `*ecdsa.PublicKey` / `ed25519.PublicKey` / `*rsa.PublicKey` — no
symmetric case either. An HS256 JWKS (`kty: oct`) crashes `bb-storage`
with `Invalid JSON Web Key at index 0` on startup. This is a fundamental
incompatibility, not a config mistake — confirmed by an actual crash on
live deployment, not caught by local dry-run testing since the local mTLS
design never touched JWT at all.

The materia-side fix: switched to **EdDSA (Ed25519)** — one keypair, no
CA, no per-role client certs (closer in spirit to krytis's original mTLS
design than HS256 would have been, just with one keypair instead of a CA
+ 2 client certs). If krytis ever needs to mint or verify a token
client-side for debugging, it's Ed25519 signatures (`openssl pkeyutl
-sign/-verify -rawin`, not HMAC) — the JWT header is
`{"alg":"EdDSA","typ":"JWT"}`.

### `auth:` config shape — `access-token`, not `client-cert`/`client-key`

BuildStream's project-config `auth:` block still only needs
`server-cert` (unchanged — Buildbarn still terminates its own TLS,
server-only, for confidentiality through the tunnel; there's no client
cert anymore, but the connection is still TLS and still needs a
trusted server cert). What changes is the **user-config** side
(CI/local `buildstream.conf`, never committed to this repo):

```yaml
# OLD (local mTLS dev-test design, PRs #341–#343's original local testing) — remove:
auth:
  server-cert: /path/to/ca.crt
  client-cert: /path/to/ci-push.crt
  client-key:  /path/to/ci-push.key

# NEW (JWT/EdDSA against the deployed bow instance):
auth:
  server-cert: /path/to/bow-server.crt   # quadlet/buildbarn/certs/bow-server.crt in this repo
  access-token: /path/to/token            # file containing the minted push or pull JWT string
```

BuildStream's own docs describe `access-token` as "path to a token for
optional HTTP bearer authentication" — sent as `Authorization: Bearer
<token>`, exactly what Buildbarn's `jwt` `AuthenticationPolicy` expects.
Tokens are minted on the materia side (`mise buildbarn:mint-token
--role push|pull`, run from the materia repo with vault access) — not
something krytis mints or stores; the `push` token goes into krytis's
GitHub Actions secrets (e.g. `BUILDBARN_PUSH_TOKEN`), written to a file
at CI workflow start, path passed as `access-token`.

### Two other live-deploy-only gotchas (materia side, documented here for anyone debugging a connection failure from the krytis side)

- The JWT policy's claim-validation field is `claims_validation_jmespath_expression`
  (`claimsValidationJmespathExpression` in jsonnet) — **not**
  `validationJmespathExpression` like the x509/mTLS policy used above.
  Different Buildbarn config messages, same concept, different field
  name (a `claims_` prefix the x509 one doesn't have). A live crash
  (`unknown field validationJmespathExpression`) caught this on the
  materia side — irrelevant to krytis's own config, but explains why the
  two policies in this doc don't look symmetric if you go compare them.
- `cacheReplacementPolicy` (e.g. `LEAST_RECENTLY_USED`) is a **required**
  field on the JWT policy's token-validation cache, not optional — the
  proto3 zero value is `UNKNOWN`, which `bb-storage` rejects outright.

None of the above requires a krytis-side code change beyond the
`auth:` shape swap — they're Buildbarn/materia-side config details,
included here because a connection failure investigated from krytis's
side (`UNAUTHENTICATED`, `PERMISSION_DENIED`) could plausibly be
misdiagnosed as a krytis-side problem without this context.

### Local push/pull verification against the deployed bow remote (#340)

Done with a hand-written user-config override (not committed, same pattern
as the earlier local mTLS verification) pointed at `bst-cache.ririi.dev`
with `push`/`pull` JWTs pulled from Proton Pass (Krytis vault, "Buildbarn"
item). `bst source push`/`fetch` round-tripped cleanly against
`core/gum.bst` (small `kind: tar` GitHub-release source — reliable to
re-fetch on demand, unlike `core/linux-cachyos.bst`, whose upstream tarball
was returning a 404 at time of testing: the exact #233 resilience scenario
this cache exists to solve, but unhelpful as a push-test fixture since a
cold-cache push needs a successful upstream fetch first).

Two gotchas surfaced that aren't covered above:

- **Combining `artifacts:` and `source-caches:` overrides in one user-config
  file crashes `bst source push`** with `AssertionError: Trying to add task
  group 'Fetch' to {'Fetch': ...}` — BuildStream's scheduler double-registers
  the Fetch queue when both cache types are configured together for a
  source-only operation. Not a Buildbarn-side issue — a BuildStream 2.7.0
  scheduler bug. Workaround: use separate single-purpose config files (one
  with only `source-caches:` for source push/fetch, one with only
  `artifacts:` for artifact push/pull) rather than one combined file, even
  though the deployed-remote urls/auth are otherwise identical between them.
- **`mise run bst --container -- --config <path> <subcommand> ...` fails**
  with `Error: No such command '--config'` — the task's `FLAGS` (always
  prepended) vs. the trailing `"$@"` ordering means a `--config` placed in
  the trailing args after `--container --` doesn't parse as a top-level bst
  option the way it looks like it should. Pass it via `BST_FLAGS="--config
  <path>"` instead (already prepended ahead of the subcommand by the task):
  `BST_FLAGS="--config /src/.buildbarn-test/push.conf" mise run bst
  --container -- source push core/gum.bst`.

Artifact push/pull itself is still unverified end-to-end: any element pull
requires the full freedesktop-sdk bootstrap chain when the local cache is
cold, and `cache.freedesktop-sdk.io:11001` (FDSDK's own recommended remote,
unrelated to krytis's Buildbarn) has every bootstrap **source** cached but
zero bootstrap **artifacts** cached — every artifact pull attempt reports
"does not have artifact cached" while the matching source pulls succeed.
That's suspicious on its own (a cache serving sources but no artifacts is
unusual) and orthogonal to #340 — worth a separate look, but it means a full
artifact-push proof here means an from-scratch SDK build, not attempted in
this session.

## Workflow Runner Choices

| Workflow | Runner | Rationale |
|---|---|---|
| `cache-warm.yml` | `[self-hosted, linux, x64]` | Needs local BST cache volume mount and full disk |
| `track-bst-sources.yml` | `ubuntu-24.04` | Lightweight; must run when local machine is off |

## `max-jobs` should only be set high when remote-execution is on

*Source: zirconium-hawaii `aceeb13` — `fix: set max-jobs to 12 only when remote-execution is on`*

Setting `max-jobs` high (e.g. 12–32) on a local GitHub Actions runner **without** remote CAS causes problems — the runner doesn't have the CPU/RAM to actually parallelize that many local builds, and they contend for resources. Only raise `max-jobs` when remote-execution is enabled (the actual builds happen on the CAS server cluster). Gate the `max-jobs` setting on the remote-execution flag rather than setting it unconditionally.

## Use smaller/less-privileged CAS config for no-push phase

*Source: zirconium-hawaii `4a9b19c` — `chore: Use smaller config for no-push phase`*

When running a build phase that doesn't push to CAS (e.g. a validation-only or no-push CI phase), don't specify the key/auth/mTLS config. Use a smaller, less-privileged CAS client config that authenticates read-only or anonymously. Less privilege = smaller blast radius if the config leaks, and fewer moving parts that can fail on a phase that doesn't need push capability.

## `track-bst-sources.yml` per-job gotchas

Each `track-<element>` job in this workflow is hand-written (no shared template), so two requirements don't propagate automatically when copy-pasting a new job:

- **`gh` needs `GH_TOKEN` on the specific step that calls it.** `gh api`/`gh` CLI calls fail with `gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable` if the `env:` block is missing on that step — the job-level `permissions:` block does not supply it. Check whether the underlying `mise run <x>-update` task shells out to `gh` before assuming it's not needed (e.g. `falcond-profiles-update` uses `gh api` to get the latest commit SHA since the upstream repo has no releases; `falcond-update` doesn't, since it scrapes an HTML page instead).
- **`bst source track` needs bubblewrap.** Only jobs that run `mise bootstrap --yes` (an "Install system dependencies" step) have `bwrap` on the runner. If a `<x>-update` mise task starts invoking `bst source track` (e.g. `scx-loader-update` added this to refresh a `cargo2` crate list), the job needs that step added — otherwise it fails with `Could not find bubblewrap command "bwrap"`.
