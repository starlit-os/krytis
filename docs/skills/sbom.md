# SBOM Generation & Vulnerability Scanning

Load when working on `mise run sbom`, `mise run vuln-scan`, `mise run push`'s SBOM/vuln-scan attach steps, `scripts/enrich-sbom-purls.py`, or the `buildstream-sbom`/grype pins.

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

**Signing is handled separately** — `mise run sign` (#60, see `docs/skills/signing.md`) signs the pushed image and both OCI referrers by digest after `mise run push` completes. Deliberately not built into `mise/tasks/sbom`/`mise/tasks/push` directly: signing needs the three manifest digests `push` already writes to `krytis-push-digests.env`, and keeping it a separate task lets it be best-effort (`.github/workflows/publish.yml` runs it with `continue-on-error: true`) without coupling its failure mode to the SBOM/scan pipeline's.

## CI Build Pipeline (#380)

`.github/workflows/publish.yml` (#380, `workflow_dispatch`-only) now wraps `mise run build` → `mise run push` → `mise run sign` as krytis's automated build→publish pipeline — SBOM generation and the vulnerability scan run there exactly as they do for a human running `mise run push` locally, since `publish.yml` is a thin orchestration layer around the same `mise` tasks, not a reimplementation. `publish.yml` runs `mise/tasks/sbom` in **native** mode (no `--container`, `BST_CONTAINER` unset in that workflow), so the crun/runc gotcha below does not currently apply to it — it only matters if a `--container`-mode SBOM run is ever added to a GitHub Actions job.

### crun 1.21+ breaks `buildstream-sbom`'s internal `bst show` on some runners

*Source: dakota `docs/skills/ci-reference.md` — hit on GHA Ubuntu 26.04 (resolute) runners with `crun` 1.21.*

`buildstream-sbom` shells out to `bst show ...` as a subprocess (`frontend.py::run_bst_show`). Inside a podman container, crun 1.21 has two failure modes that break this call:

1. **seccomp BPF linkat EPERM** — crun caches compiled seccomp BPF programs via `linkat()`; some kernels/namespaces block the hard-link, producing `crun: linkat ...: Permission denied`.
2. **systemd probe EACCES** — crun probes systemd presence and caches the result under `$XDG_RUNTIME_DIR`; an uninitialized or wrong-owner runtime dir causes `crun: opendir ...: Permission denied`.

**Fix:** pass `--runtime runc` to the `podman run` invocation. `mise/tasks/sbom --container` already does this **conditionally** — only when a `runc` binary is present on the host (`command -v runc`). Don't hardcode `--runtime runc` unconditionally: not every podman host ships runc alongside crun (confirmed: this fails outright with `Error: default OCI runtime "runc" not found` on a host with no runc at all), and plain crun works fine outside the specific GHA image dakota hit this on. If krytis ever runs `mise run sbom --container` in GH Actions, verify the runner image ships `runc` (Ubuntu 24.04 GHA runners do, per dakota) or install it explicitly.

**Do not** reach for `--security-opt seccomp=unconfined` instead — it only fixes failure mode 1, not 2.


## Vulnerability Scanning (#41)

`mise run vuln-scan` (and `mise run push`, unless `--skip-vuln-scan`) scans the SBOM above with [Grype](https://github.com/anchore/grype) and attaches the JSON report as a second OCI referrer (`application/vnd.grype.report+json`).

**Scanner choice — Grype over Trivy:** tested both against a real, unmodified krytis SBOM. Trivy found **zero** vulnerabilities and printed `Supported files for scanner(s) not found` — its own docs say why: *"Passing SBOMs generated by tools other than Trivy may result in inaccurate detection because Trivy relies on custom properties in SBOM for accurate scanning."* Grype found 285 matches on the same file with no flags needed — its architecture (Anchore docs) includes a CPE-generation fallback for packages lacking purls, which is exactly what `buildstream-sbom` output needs (see "What It Is" above: no `externalRefs` of type `purl`/`cpe23Type` at all). Image-mode scanning (`grype <image>`) was never viable for either tool — BST builds from source, so there's no rpm/dpkg/apk database for an OS-package scanner to read (same reason Syft was rejected for SBOM generation).

### `scripts/enrich-sbom-purls.py`

The raw SBOM needs preprocessing before scanning — verified empirically, not by inspection alone. Grype's *unscoped* CPE fallback (used for every package without a purl) turned out to be the source of two distinct false-positive classes:

1. **Element-wrapper packages (no version) — the dominant noise source.** `buildstream-sbom` emits one package per BST *element* (`SPDXID` with no `-N` suffix: no `versionInfo`, `downloadLocation: NOASSERTION`) in addition to one numbered sub-package per actual *source*. With no version to bound a match, Grype flags the bare element name against **any** loosely-matching advisory — including from an unrelated ecosystem. Confirmed case: `freedesktop-sdk.bst:components/openssl.bst` (the **C** OpenSSL library) matched a **Rust** `openssl` *crate* GHSA advisory purely by name collision, reported "Critical" with a blank installed version. Every single blank-version "N/A confidence" Critical/High hit in a raw scan traced back to a wrapper package this way (`libidn2`, `libproxy`, `ncurses`, `nlohmann-json`, `shaderc`, `protobuf`, `warp`, ...). **Fix:** drop any package missing `versionInfo`. Verified safe — in a real krytis SBOM, 0 packages have real component data (`sourceInfo`) without also having `versionInfo`; the fields are 1:1. 847 of 7,301 packages are wrapper packages.
2. **Hash-shaped `versionInfo`.** Some `local`/`tar`-sourced elements (krytis's own config, and vendored blobs like `desktop-ghostty.bst`'s deps) pin by content hash instead of semver — e.g. `6b4cfc216043fac5212e301085d1baf7e09ae6e7871d3fa8a8288b6fe43d39cd/101`. Grype's CPE fallback treats the hash string as if it were a real version and produces the same kind of spurious match (confirmed case: `openldap` "matched" against real openldap CVE ranges using a 40-char hex hash as the installed version — a hash can never satisfy a semver constraint, so this can never be a true positive). **Fix:** drop packages whose `versionInfo` matches `^[0-9a-fA-F]{32,64}(/\d+)?$`. 309 of the remaining 6,454 packages hit this — mostly krytis's own `local`-sourced config (expected: it has no upstream CVE surface at all) plus the ghostty-vendored blobs (a genuine, disclosed coverage gap — check ghostty's own upstream advisories manually for those).
3. **Purl enrichment for precision, not noise reduction.** Adds `pkg:cargo/<name>@<version>` / `pkg:pypi/<name>@<version>` externalRefs for `cargo2`/`pypi`-sourced sub-packages (~74%/0.1% of the graph respectively) — the only `sourceInfo` kinds with an unambiguous 1:1 purl mapping. This makes Grype match them ecosystem-scoped (`rust-crate`/`python` typed, real fixed-in versions, EPSS scores) instead of via the same unscoped CPE fallback. In practice this changed *match quality*, not the *match count* on the specific SBOM snapshot tested — none of the enriched crate/version pairs happened to have an outstanding advisory at scan time. Verified the purl path itself works via an isolated minimal-SPDX repro (a deliberately vulnerable `time@0.1.42` crate) before trusting a zero-diff result on the real SBOM.

Deliberately **not** enriched: `git_repo`, `remote`, `patch`, `patch_queue`, `git_module`, `cpan` sourceInfo — no reliable 1:1 purl mapping (a GitHub repo could be any ecosystem or none; CPAN distribution names don't always match module names). These keep relying on Grype's CPE fallback same as before — this is a known, disclosed scope limit, not silently swept under the enrichment step.

**Also drops any `relationships` entries** referencing a removed package's SPDXID, so the enriched output stays internally consistent (it's a scan-only intermediate — the canonical `krytis.spdx.json` artifact from `mise run sbom` is never mutated).

### Verified before/after (same underlying SBOM, Grype 0.116.0)

| | Raw SBOM | Enriched |
|---|---|---|
| Total matches | 285 | 125 |
| Blank-version (wrapper false positives) | dozens, incl. 5+ "Critical/N/A confidence" | **0** |
| Purl-scoped (`rust-crate`/`python` typed) matches | 0 | present (`gix`, `rand`, `tokio`, `rustls-webpki`, `pyo3`, ...) |

### `--fail-on` / severity gating

Both `mise run vuln-scan --fail-on <severity>` and `mise run push --fail-on <severity>` pass straight through to Grype's own `-f/--fail-on` flag (`negligible|low|medium|high|critical`) — Grype exits 2 when a match at or above that severity exists; the wrapping task turns that into a normal non-zero exit. **No flag = warn-only** (report generated and attached either way, never blocks). Note the ordering in `push`: the image is already pushed to the registry by the time the scan runs, so `--fail-on` cannot prevent the push itself — it fails the overall `mise run push` invocation after the fact, the same way dakota's `publish-sbom` job (`continue-on-error: true`) reports failures without blocking an already-completed image push. Default to warn-only until the residual noise (mainly the ghostty hash-version gap above) has been triaged in practice.

### Known bug found and fixed while wiring this: `mise/tasks/sbom` leaked `--output` through env inheritance

`mise/tasks/bst` already documents this pattern (`docs/skills/mise.md` § Propagating flags through tasks that call other tasks) but `mise/tasks/sbom` (#40) missed it: when a *calling* task also declares its own `--output`/`--container` `#USAGE` flag with a different default, mise sets `usage_output`/`usage_container` in the **caller's** environment — and a plain `./mise/tasks/sbom --output foo` subprocess call inherits that env var, since mise only parses `#USAGE` headers for `mise run <task>` invocations, not direct script calls. Without an explicit argv-parsing fallback, the inherited (wrong) value silently wins over the literal flag. Hit for real: `mise run vuln-scan` (its own `--output` default is `krytis.grype.json`) called `./mise/tasks/sbom --output krytis.spdx.json`, and the SBOM silently got written to `krytis.grype.json` instead. Fixed by giving `mise/tasks/sbom` the same literal-argv-consuming loop `mise/tasks/bst` already has for `--container`/`--push`/`--pull`. **Any task that calls another task's script directly and both declare an overlapping flag name is at risk of this** — check for it when adding a new `#USAGE` flag to a task with callers.