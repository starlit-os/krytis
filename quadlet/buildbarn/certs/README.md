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

Generate the CA and certs with a standard `openssl` self-signed CA flow
(one-time setup, not a mise task since it's a rare provisioning action rather
than a repeatable maintenance operation):

```bash
openssl genrsa -out ca.key 4096
openssl req -x509 -new -key ca.key -sha256 -days 3650 -out ca.crt \
  -subj "/CN=krytis-buildbarn-ca"

openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=bb-storage.krytis.internal"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 -sha256

# Repeat for ci-push and pull, adding the URI SAN via an openssl config
# extension (subjectAltName = URI:spiffe://krytis/ci-push or .../pull).
```

`ca.key` should be kept offline once the two client certs are issued — it's
only needed again to reissue or add certs.
