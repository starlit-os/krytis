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

`mise run push` generates the SBOM (and, unless `--skip-vuln-scan`, the enriched SBOM and Grype report) *before* logging in, tagging, or pushing anything (#392) — a `--fail-on` breach aborts there, before any registry interaction. Once the image is actually pushed, the already-generated `krytis.spdx.json`/`krytis.grype.json` files are attached to the just-pushed image digest as OCI referrers (`application/vnd.spdx+json` / `application/vnd.grype.report+json`) — no regeneration at attach time. Both the version and `:latest` tags share one content-addressed manifest digest (same source image, tagged twice), so each referrer is attached exactly once per push, covering both tags. `oras login` reuses the same GHCR token/user already resolved for `podman login` earlier in the task.

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


### Mitigated: Grype `stock-matcher` cross-ecosystem false positives via `.grype.yaml` ignore rules

`enrich-sbom-purls.py` closes the *wrapper-package* and *hash-version* false-positive
classes above, but a **third** class survives enrichment because it doesn't fit either
filter: a real (non-wrapper, non-hash) `versionInfo`, from a `sourceInfo` kind the
enrichment script deliberately doesn't purl-scope (the package **is** the BST element
itself — e.g. `freedesktop-sdk.bst:components/tar.bst` — not a `cargo2`/`pypi`
*dependency of* one). Confirmed on a real scan (2026-08-05, Grype 0.116.1, 111 matches):
every affected package has `.artifact.purl == null` and `matchDetails[0].matcher ==
"stock-matcher"` with `searchedBy.namespace` set to a GHSA *language* namespace that does
**not** match the artifact's real ecosystem — Grype's fallback for purl-less packages
checks the bare name against every GHSA language namespace, not just a plausible one:

| Package (installed) | Real identity | Matched against |
|---|---|---|
| `tar` 1.35 | GNU tar (C, `tar.bst`) | `github:language:javascript` — npm `tar`/`node-tar` (17 distinct GHSAs, `fixed-in` values like `7.5.21` that GNU tar's own versioning has never reached) |
| `libidn2` 2.3.8 | GNU libidn2 (C) | `github:language:javascript` |
| `zlib` 1.3.1 | zlib (C) | `github:language:ruby` |
| `json` 3.12.0 | nlohmann/json (C++) | `github:language:javascript` |
| `shaderc` 2025.3 | Google shaderc (C++) | `github:language:javascript` |
| `markdown` 3.10.2 | Python-Markdown (`python3-markdown.bst`) | `github:language:javascript` (wrong *language*, despite the artifact genuinely being a Python package) |
| `networkx` 3.6.1 | NetworkX (`python3-networkx.bst`) | `github:language:javascript` |
| `paste` 1.0.14 | vendored copy in `desktop/mesa-all-codecs.bst` | `github:language:python` — PyPI `Paste` WSGI framework |

42 of 111 matches in that scan (~38%) traced to these 8 packages — including 3 of the
scan's "Critical" hits (`libidn2`, `networkx`, `shaderc`, all reported with `EPSS: N/A`,
the same "no real CVE behind this" signal as the already-documented wrapper-package
false positives). `tar` alone was double-counted on top of the ecosystem mismatch:
krytis's SBOM lists GNU tar as **two** separate unscoped packages at the same version
(`bootstrap/base-sdk/tar.bst` and `components/tar.bst`), so every one of its 17 wrong
GHSAs was matched twice (34 raw matches).

**Fix — `.grype.yaml` ignore rules, not enrichment-script changes.** Broader purl/CPE
enrichment for every BST-element-is-the-package case would cover most of the C/C++/
non-cargo/non-pypi graph — too large and too risky (a wrong CPE assignment reintroduces
the same class of mismatch) for the 8 confirmed instances actually found. Instead,
`mise/tasks/vuln-scan` passes `grype --config .grype.yaml`, and the repo-root
`.grype.yaml` lists all 25 confirmed (`vulnerability`, `package.name`,
`package.version`) triples as `ignore:` rules (Grype's own suppression mechanism,
documented in `grype config`). Pinned to the exact installed version, not name alone:
a version bump on the underlying BST element makes the rule stop applying, and Grype
re-flags the match — re-verify `matchDetails[0].searchedBy.namespace` before re-adding
rather than assuming the same package name is always safe to ignore.

**This does not generalize.** Any *new* purl-less BST-element package that happens to
share a name with an unrelated ecosystem's advisory will still false-positive the same
way — `.grype.yaml` only suppresses instances already found and verified. Treat any
`stock-matcher` match with no purl (`jq '.matches[] | select(.matchDetails[0].matcher=="stock-matcher"
and .artifact.purl==null)'` on the Grype JSON report) as needing the same manual
ecosystem cross-check before trusting it or adding it to the ignore list.

### A second `stock-matcher` namespace: `bitnami`, and a "fixed-in is stale" variant

Re-verified 2026-09-01 (Grype 0.118.0) after the freedesktop-sdk 26.08rc merge. Two
*new* purl-less false-positive instances surfaced that don't fit the "wrong ecosystem
entirely" shape above — Grype's `bitnami` namespace (a separate stock-matcher source
from the `github:language:*` ones already documented) matched `sqlite`/`Pillow` against
real CVEs for those *exact* projects, but whose cited fix version is far *below* the
actually-installed version (e.g. `BIT-sqlite-2025-6965` cites a fix at 3.50.2; krytis
ships 3.53.4). Same root cause as the `github:language:*` case — no purl/CPE to bound
the match by version range, so Grype's fallback flags the bare name regardless — just a
different Grype data source. Check `matchDetails[0].searchedBy.namespace == "bitnami"`
the same way as the GHSA-language case; the same manual "is the cited fixed-in version
actually below what's installed" verification applies before ignoring.

### Version-pinned ignore rules silently stop suppressing on every element bump

Confirmed for real, same 2026-09-01 re-scan: two entries already in `.grype.yaml`
(`markdown` pinned to `3.10.2`, `shaderc` pinned to `2025.3`) had gone stale — routine
`chore(deps)` bumps moved the installed versions to `3.10.3`/`2026.3` between when the
rules were written and this scan, so Grype re-flagged both as if unignored (exactly the
documented, intended behavior of pinning by version — this is not a bug in the
ignore-list design, just a reminder that it needs upkeep). There's no automated drift
check for this the way `mise run systemd-base-check`/`rust-bindgen-check` cover the
patch-based overrides — a version-pinned `.grype.yaml` entry silently re-flagging on the
next routine dependency bump is the expected failure mode, not a regression to chase.
Treat every `mise run vuln-scan` finding with a `namespace` matching one already in
`.grype.yaml`'s comments as "stale pin, re-verify and bump the version", not "new bug".

### Mitigated: dependency-graph-proven unreachable crate versions (rust-matcher, not stock-matcher)

A distinct, narrower ignore-rule class from the `stock-matcher` cases above — this one
has a real purl (`rust-matcher`-typed, ecosystem-scoped by construction) and genuinely
matches a vulnerable crate *version* that is really present in an SBOM vendor snapshot.
It's still safe to ignore when the vendor snapshot is workspace-wide (shared across many
optional build targets, e.g. a Cargo `[[workspace]]`) but the specific crate version is
provably reachable only from targets krytis never builds.

First instance: `rustls-webpki` in `freedesktop-sdk.bst:components/gstreamer-plugins-rs.bst`
(issue #500, 2026-09-01). fdsdk's `cargo2` vendor block for `gst-plugins-rs` is generated
once from `cargo generate-lockfile` against the **entire** upstream workspace (~65
GStreamer plugins), not scoped to which plugins krytis's meson flags actually enable
(`rtp`/`gif`/`hlssink3`/`dav1d`/`spotify`) — so disabled plugins' dependencies still show
up as "installed" in the SBOM and trigger real, purl-scoped Grype matches. Three
`rustls-webpki` versions coexist in the vendor snapshot (0.101.7/0.102.8 vulnerable,
0.103.13 fixed — verified against GHSA-965h-392x-2mh5/GHSA-xgp8-3hg3-c2mh's own patched
ranges, `>=0.103.12`). The BST element itself carries no dependency graph (just flat
`{name, version, sha}` triples for vendoring), so resolving reachability required fetching
the real upstream `Cargo.lock` at the pinned git ref directly from
`gitlab.freedesktop.org/gstreamer/gst-plugins-rs`, parsing it (`tomllib`), and doing a
forward BFS from each of the 5 enabled plugins' package nodes through the `dependencies =
[...]` edges to see which reach `rustls-webpki`:

| `rustls-webpki` version | rustls | CVE status | Reachable from |
|---|---|---|---|
| 0.101.7 | 0.21.12 | vulnerable | `aws`, `webrtc` only — **both disabled** |
| 0.102.8 | 0.22.4 | vulnerable | `spotify` only — **enabled** (`librespot-core -> hyper-proxy2/rustls -> hyper-rustls 0.26 -> rustls 0.22.4`) |
| 0.103.13 | 0.23.41 | fixed | `spotify` + 14 other disabled plugins |

`0.101.7` is ignored in `.grype.yaml` (class 2 there) — proven unreachable from every
plugin cdylib krytis actually builds. `0.102.8` is **not** ignored, deliberately: the
`spotify` plugin enables `librespot-core`'s `rustls-tls-native-roots` feature, which
(confirmed from `librespot-core`'s own `Cargo.toml.orig` on crates.io) unconditionally
turns on `hyper-proxy2/rustls` — the vulnerable path is compiled in regardless of runtime
proxy usage. That's a real, reachable dependency of a plugin krytis ships; closing it needs
a product decision (drop `-Dspotify=enabled`, or wait on an upstream bump), not a scan
suppression, so it stays flagged.

**When this class applies vs. when it doesn't:** only use it when the *entire* reachable
build-target graph has been walked from source (not inferred from "this feature sounds
unrelated") and shown to exclude the vulnerable version. A single enabled target reaching
the vulnerable version means the whole version stays un-ignored, even if most other
targets sharing the same vendor snapshot don't reach it — as `0.102.8` above shows. Don't
extend an existing rule's `package.version` to a sibling version without re-walking the
graph for that specific version; different versions of the same crate can easily sit on
different dependency chains (confirmed here: `0.101.7` and `0.102.8` have completely
disjoint reachable-plugin sets).


### A `cargo update -p X` "fix" is only real if it clears the advisory's actual range

Caught by this same 2026-09-01 re-scan: `elements/desktop/greetd.bst`'s
`bump-tokio-bytes-drop-agreety-deps.patch` (#501/#496) bumped `tokio` 1.37.0->1.42.1
believing that closed GHSA-rr8g-9fpq-6wmg — it didn't. The advisory's patched ranges are
`>=1.44.0,<1.44.2`, `>=0.2.5,<1.38.2`, and `>=1.39.0,<1.43.1`; 1.42.1 falls inside the
third range, so the crate was still vulnerable for four weeks of `main` history despite
the commit message and #483's inventory both stating the CVE was fixed. Root cause: the
original fix reasoned from "bumped past the version the CVE was reported against" rather
than checking the advisory's actual patched-version ranges (GitHub Advisory Database
entries list them explicitly — grep the `Patched versions` field, don't eyeball the
version delta). Fixed by `patches/greetd/bump-tokio-1.43.1.patch` (tokio -> 1.43.1,
tokio-macros -> 2.5.0 for tokio's own `~2.5.0` requirement). **Lesson: after any
`cargo update -p <crate>` vuln fix, re-run `mise run vuln-scan` against the result before
trusting it closed — don't infer closure from the version bump alone.**

### `--fail-on` / severity gating

Both `mise run vuln-scan --fail-on <severity>` and `mise run push --fail-on <severity>` pass straight through to Grype's own `-f/--fail-on` flag (`negligible|low|medium|high|critical`) — Grype exits 2 when a match at or above that severity exists; the wrapping task turns that into a normal non-zero exit. **No flag = warn-only** (report generated and attached either way, never blocks). **`mise run push`'s ordering (#392):** SBOM generation and the vuln scan run *before* login/tag/push — a `--fail-on` breach aborts there, before anything reaches the registry. This is possible because `buildstream-sbom` reads static element/source metadata via `bst show`, which does not require the image to be built (verified: `bst show` reports `oci/krytis/image.bst waiting` — not cached — in a checkout that still produces a complete, accurate SBOM). `.github/workflows/publish.yml` additionally runs `mise run vuln-scan --fail-on <severity>` as its own standalone step *before* `mise run build`, so a blocking finding skips the ~20-25 minute BST build entirely, not just the push — `mise run push`'s own scan-before-push is the defense-in-depth guarantee for the case where that earlier gate is skipped or `mise run push` is run standalone. Before #392, the image was already pushed by the time the scan ran, so `--fail-on` only failed the job after the fact (the same non-blocking shape as dakota's `publish-sbom` job, `continue-on-error: true`) — that ordering is no longer how this works.

### Known bug found and fixed while wiring this: `mise/tasks/sbom` leaked `--output` through env inheritance

`mise/tasks/bst` already documents this pattern (`docs/skills/mise.md` § Propagating flags through tasks that call other tasks) but `mise/tasks/sbom` (#40) missed it: when a *calling* task also declares its own `--output`/`--container` `#USAGE` flag with a different default, mise sets `usage_output`/`usage_container` in the **caller's** environment — and a plain `./mise/tasks/sbom --output foo` subprocess call inherits that env var, since mise only parses `#USAGE` headers for `mise run <task>` invocations, not direct script calls. Without an explicit argv-parsing fallback, the inherited (wrong) value silently wins over the literal flag. Hit for real: `mise run vuln-scan` (its own `--output` default is `krytis.grype.json`) called `./mise/tasks/sbom --output krytis.spdx.json`, and the SBOM silently got written to `krytis.grype.json` instead. Fixed by giving `mise/tasks/sbom` the same literal-argv-consuming loop `mise/tasks/bst` already has for `--container`/`--push`/`--pull`. **Any task that calls another task's script directly and both declare an overlapping flag name is at risk of this** — check for it when adding a new `#USAGE` flag to a task with callers.