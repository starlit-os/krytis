# SBOM Generation

Load when working on `mise run sbom`, `mise run push`'s SBOM attach step, or the `buildstream-sbom` pin in `pyproject.toml`.

## What It Is

Krytis generates an SPDX 2.3 Software Bill of Materials for `oci/krytis/image.bst` using [`buildstream-sbom`](https://gitlab.com/BuildStream/buildstream-sbom), reads BST element metadata directly (`bst show` under the hood), and attaches the result to the published image as an OCI referrer via `oras attach`. Implements #40.

**Format choice — SPDX over CycloneDX:** `buildstream-sbom` only emits SPDX 2.3; no BST-native CycloneDX generator exists. The alternative (Syft against the built rootfs) was rejected — Syft only fingerprints binaries in the filesystem and misses source-built junction packages (GNOME/systemd/etc. pulled in via `freedesktop-sdk.bst`/`gnome-build-meta.bst`), producing a near-empty SBOM on a BST image. `buildstream-sbom` captures the full ~7,300-element krytis graph including junction dependencies.

**Precedent:** dakota (`../dakota`, sibling fork building on the same BST2 + freedesktop-sdk foundation) runs this exact tool in its `publish-sbom` CI job (`just sbom` in dakota's `Justfile`). Krytis mirrors dakota's SPDX/tool/pin choice but generates **natively** via the project's `uv` venv rather than always shelling into the bst2 podman container — `buildstream>=2.5.0` and now `buildstream-sbom` are both project Python dependencies (`pyproject.toml`), and `buildstream-sbom` just needs a `bst` binary on `PATH`, which `uv run` already provides from `.venv/bin/bst`. `--container` mode (mirroring dakota's always-container approach) is available as a fallback via `mise run sbom --container`.

## `buildstream-sbom` Pin

Not published to PyPI — installed from a pinned git commit:

```
buildstream-sbom @ git+https://gitlab.com/BuildStream/buildstream-sbom.git@0706fec3bedf6f73bd9d2fed32c2aed585feef8d
```

This is the same commit dakota pins (verified working there, includes element names in SPDX output — dakota's own note references a fix for their issue #9). Bump deliberately by editing `pyproject.toml`, `uv lock`, and the two `0706fec3...` references in `mise/tasks/sbom` (native pin is implicit via `uv.lock`; container-mode pin is a literal string in the script) — then re-run `mise run sbom` and `mise run sbom --container` and confirm `.packages` count and `spdxVersion` are sane before committing.

## `mise run sbom`

```bash
mise run sbom                       # native, uv run buildstream-sbom → krytis.spdx.json
mise run sbom --container           # bst2 podman container instead
mise run sbom --output foo.json     # custom output path
```

Verified locally (container mode, 2026-07-29): 7,301 packages, `spdxVersion: SPDX-2.3`, correct `documentNamespace` (`https://github.com/starlit-os/krytis/sbom/<git-sha>`). One informational warning is expected and harmless:

```
Can't extract a package name from source info {'kind': 'docker', ...}
```

This is `buildstream-sbom` not knowing how to name an `oci-image`-medium source (freedesktop-sdk's binary-seed bootstrap image) — cosmetic, doesn't affect the rest of the manifest.

### Known limitation: junction elements without source provenance

Elements from the `freedesktop-sdk` junction that predate BST 2's source provenance API emit, during element resolution:

```
Dependency "<element>.bst" from project "freedesktop-sdk" doesn't use the source provenance API
```

These elements appear in the SBOM as packages with no recorded upstream URL/commit/checksum (`sourceInfo` gap) — not missing entirely, just provenance-incomplete. This is outside krytis's control; it resolves as freedesktop-sdk adopts the API across its elements over time. See `docs/skills/bst.md` § BST Source Provenance API Warning for the build-time warning itself.

## `mise run push` Integration

`mise run push` generates the SBOM and attaches it to the just-pushed image digest as an OCI referrer (`application/vnd.spdx+json`), after both the version and `:latest` tags are pushed. Both tags share one content-addressed manifest digest (same source image, tagged twice), so the SBOM is generated and attached exactly once per push, covering both tags. `oras login` reuses the same GHCR token/user already resolved for `podman login` earlier in the task.

Skip with `mise run push --skip-sbom` for fast local iteration.

**Signing is explicitly out of scope here** — tracked separately in #60 (cosign keyless signing), not implemented yet. The SBOM (and the image) are attached/pushed unsigned. Do not add cosign steps to this SBOM flow without checking #60 first; wire signing into whatever `mise run push`/CI mechanism #60 lands, not by extending `mise/tasks/sbom`.

## Why Not Krytis's Own CI Build Pipeline (Yet)

Unlike dakota, krytis has no automated build→publish GitHub Actions workflow — `mise run push` is a manual, human-run step (`.github/workflows/` currently only has `cache-warm.yml`, which discards its build output, and `track-bst-sources.yml`). Wiring SBOM generation into `mise run push` *is* "integrating into the CI build pipeline" for krytis's current pipeline shape: it's the actual publish surface, whether invoked by a human or eventually by a real GH Actions publish workflow. If krytis ever stands up an automated publish workflow (dakota's `publish.yml` `publish-sbom` job is the reference), the crun/runc gotcha below becomes directly relevant.

### crun 1.21+ breaks `buildstream-sbom`'s internal `bst show` on some runners

*Source: dakota `docs/skills/ci-reference.md` — hit on GHA Ubuntu 26.04 (resolute) runners with `crun` 1.21.*

`buildstream-sbom` shells out to `bst show ...` as a subprocess (`frontend.py::run_bst_show`). Inside a podman container, crun 1.21 has two failure modes that break this call:

1. **seccomp BPF linkat EPERM** — crun caches compiled seccomp BPF programs via `linkat()`; some kernels/namespaces block the hard-link, producing `crun: linkat ...: Permission denied`.
2. **systemd probe EACCES** — crun probes systemd presence and caches the result under `$XDG_RUNTIME_DIR`; an uninitialized or wrong-owner runtime dir causes `crun: opendir ...: Permission denied`.

**Fix:** pass `--runtime runc` to the `podman run` invocation. `mise/tasks/sbom --container` already does this **conditionally** — only when a `runc` binary is present on the host (`command -v runc`). Don't hardcode `--runtime runc` unconditionally: not every podman host ships runc alongside crun (confirmed: this fails outright with `Error: default OCI runtime "runc" not found` on a host with no runc at all), and plain crun works fine outside the specific GHA image dakota hit this on. If krytis ever runs `mise run sbom --container` in GH Actions, verify the runner image ships `runc` (Ubuntu 24.04 GHA runners do, per dakota) or install it explicitly.

**Do not** reach for `--security-opt seccomp=unconfined` instead — it only fixes failure mode 1, not 2.
