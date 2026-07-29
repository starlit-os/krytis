#!/usr/bin/env python3
"""Prepare a buildstream-sbom SPDX document for vulnerability scanning (#41).

buildstream-sbom (#40) emits one SPDX package per BST *element* ("wrapper"
packages: no `versionInfo`, `downloadLocation: NOASSERTION`, only a
`bst-element` externalRef) plus one sub-package per *source* pulled in by
that element (numbered `-N` SPDXIDs, real `name`/`versionInfo`/`sourceInfo`).
Neither carries a `purl` or `cpe23Type` externalRef.

Two independent problems follow, both verified empirically against a real
krytis SBOM + Grype 0.116.0:

1. **Wrapper packages are pure noise for vuln scanning.** With no version,
   Grype cannot bound a match, so it flags them against *any* advisory that
   loosely matches the bare element name — including advisories from an
   unrelated ecosystem. Confirmed case: `freedesktop-sdk.bst:components/
   openssl.bst` (the C OpenSSL library) matched against a Rust `openssl`
   *crate* GHSA advisory purely by name collision, reported as "Critical"
   with no version shown. Every "N/A confidence" Critical/High hit in a
   manual scan traced back to a wrapper package this way (libidn2, libproxy,
   ncurses, nlohmann-json, shaderc, protobuf, warp — all wrapper matches).
   Fix: drop packages with no `versionInfo` before scanning. Verified safe —
   in a real krytis SBOM, 0 packages have `sourceInfo` (real component data)
   without also having `versionInfo`; the two fields are 1:1.

2. **Sub-packages lack purls**, so scanners either find nothing (Trivy,
   verified: 0 matches against an unenriched krytis SBOM — it declines to
   fall back to name+version matching for third-party SBOMs) or fall back to
   the same unscoped name+version CPE guessing Grype uses for wrapper
   packages (works, but not ecosystem-scoped). Fix: add purls for
   `sourceInfo` values with an unambiguous 1:1 purl mapping:

     cargo2  -> pkg:cargo/<name>@<version>   (~74% of the krytis SBOM graph)
     pypi    -> pkg:pypi/<name>@<version>

   Deliberately NOT enriched: git_repo, tar, remote, local, patch, cpan, and
   other sourceInfo kinds with no reliable 1:1 purl mapping (a GitHub repo
   could be any ecosystem or none; CPAN distribution names don't always
   match module names). These keep relying on Grype's name+version CPE
   fallback, same as today.

3. **A handful of packages use a content hash as `versionInfo` instead of a
   real version** — some `local`/`tar`-sourced elements pin by hash rather
   than semver (verified case: `desktop-ghostty.bst`'s vendored deps carry
   git-tree/sha256 hashes as `versionInfo`). Grype's CPE fallback treats the
   hash string as if it were a version and produces nonsense matches (e.g.
   `openldap` "matched" against real openldap CVE ranges using a 40-char hex
   hash as the installed version). Confirmed narrow in practice — 5 packages
   in a real krytis SBOM — but each one is a clean false positive with no
   possible true-positive interpretation (a hash can never satisfy a semver
   range). Fix: drop packages whose `versionInfo` is a bare hex hash
   (32-64 hex chars, optionally with a `/<int>` suffix) before scanning.
   These have no reliable automated CVE-matching path at all today; treat
   them as a known coverage gap (see docs/skills/sbom.md), not silently
   dropped without a trace — their names are printed so a human can check
   upstream advisories for those specific vendored blobs manually.

Also drops any `relationships` entries that reference a removed package's
SPDXID, so the output stays internally consistent.

Usage: enrich-sbom-purls.py <input.spdx.json> <output.spdx.json>
"""
import json
import re
import sys

PURL_TYPE_BY_SOURCE_INFO = {
    "cargo2": "cargo",
    "pypi": "pypi",
}

# Matches versionInfo values that are a content hash rather than a real
# version, e.g. "6b4cfc216043fac5212e301085d1baf7e09ae6e7871d3fa8a8288b6fe4"
# "3d39cd/101" (git-tree hash + offset) or a bare 40/64-char hex sha.
HASH_VERSION_RE = re.compile(r"^[0-9a-fA-F]{32,64}(/\d+)?$")


def add_purl(package: dict) -> bool:
    """Add a PACKAGE-MANAGER/purl externalRef to `package` in place.

    Returns True if a purl was added, False if the package was skipped
    (unsupported sourceInfo, or missing name/version).
    """
    purl_type = PURL_TYPE_BY_SOURCE_INFO.get(package.get("sourceInfo"))
    if purl_type is None:
        return False

    name = package.get("name")
    version = package.get("versionInfo")
    if not name or not version:
        return False

    purl = f"pkg:{purl_type}/{name}@{version}"
    package.setdefault("externalRefs", []).append(
        {
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": purl,
        }
    )
    return True


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input.spdx.json> <output.spdx.json>")

    input_path, output_path = sys.argv[1], sys.argv[2]

    with open(input_path, encoding="utf-8") as f:
        doc = json.load(f)

    packages = doc.get("packages", [])
    kept, dropped_ids = [], set()
    hash_versioned = []
    for p in packages:
        if "versionInfo" not in p:
            dropped_ids.add(p.get("SPDXID"))
        elif HASH_VERSION_RE.match(p["versionInfo"]):
            dropped_ids.add(p.get("SPDXID"))
            hash_versioned.append(f"{p.get('name')}@{p['versionInfo'][:12]}...")
        else:
            kept.append(p)
    doc["packages"] = kept

    relationships = doc.get("relationships", [])
    doc["relationships"] = [
        r
        for r in relationships
        if r.get("spdxElementId") not in dropped_ids
        and r.get("relatedSpdxElement") not in dropped_ids
    ]

    enriched = sum(add_purl(p) for p in kept)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)

    print(
        f"==> Dropped {len(dropped_ids) - len(hash_versioned)} unversioned "
        f"wrapper packages; {len(relationships) - len(doc['relationships'])} "
        f"relationships"
    )
    if hash_versioned:
        print(
            f"==> Dropped {len(hash_versioned)} hash-versioned packages "
            f"(no reliable CVE-matchable version — check upstream manually): "
            f"{', '.join(hash_versioned)}"
        )
    print(
        f"==> Enriched {enriched}/{len(kept)} remaining packages with purls "
        f"({', '.join(PURL_TYPE_BY_SOURCE_INFO)})"
    )


if __name__ == "__main__":
    main()
