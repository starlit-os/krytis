# Buildbarn TLS material

**Nothing in this directory is committed except this README.** The quadlet
units mount `~/.local/share/buildbarn/certs` (see `bb-storage.container` /
`bb-asset.container`), which must contain, on the runner box only:

| File | Contents | Sensitivity |
|---|---|---|
| `ca.crt` | krytis-owned CA public cert | Public — safe to distribute to pull clients |
| `server.crt` / `server.key` | Server identity for both `bb-storage` and `bb-asset` | `server.key` never leaves the runner box |
| `ci-push.crt` / `ci-push.key` | CI's push-capable client cert, SAN `spiffe://krytis/ci-push` | Secret — delivered to CI via a GitHub Actions secret, never committed |
| `pull.crt` / `pull.key` | Shared read-only client cert, SAN `spiffe://krytis/pull` | Low-sensitivity but still not committed — distribute out-of-band to dev machines that need to pull |

**Local/dev provisioning:** `mise buildbarn:certs-init` generates all of the
above (CA + server + ci-push + pull) into `~/.local/share/buildbarn/certs`
with an idempotent `openssl` self-signed CA flow, including the URI SAN
extensions the mTLS authorizers in `config/common.libsonnet` match against.
Safe to re-run — it skips generation if `ca.crt` already exists.

`ca.key` should be kept offline once the client certs are issued — it's only
needed again to reissue or add certs. For the shared runner box (as opposed
to local testing), the CA/server cert should be generated once and the
resulting `ci-push.crt`/`ci-push.key` delivered to CI out-of-band rather than
regenerated per-machine — regenerating the CA anywhere invalidates every
previously issued cert.
