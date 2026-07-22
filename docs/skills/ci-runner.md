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

### First-deploy verification

All of the above was found and fixed by actually running
`mise buildbarn:certs-init` → `mise buildbarn:install` →
`mise buildbarn:status` end-to-end on a rootless dev box, not by reading
docs alone — `bb-storage` and `bb-asset` both reach `active (running)`
and bind their expected ports from a clean slate (no existing volumes/certs).
What's still unverified: the mTLS push/pull authorization split under a
real gRPC client (see above), and behavior once this moves to the shared
runner box as a system-level service (see "Rootless first, system-level
later" above).

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
