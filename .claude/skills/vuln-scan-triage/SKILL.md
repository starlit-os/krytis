---
name: vuln-scan-triage
description: Re-verify Grype vuln-scan false positives and update .grype.yaml's ignore rules. Use whenever the user asks to check/re-check grype false positives, re-verify or refresh the vuln-scan ignore list, audit .grype.yaml, triage new vuln-scan findings, or run a "vuln scan quality" check. Also the right tool after any mise run vuln-scan whose match count looks suspicious (wrong version numbering, blank EPSS on a "Critical", packages with no purl).
---

# Vuln-Scan False-Positive Triage

Grype's `stock-matcher` fallback (used whenever an SBOM package has no purl/CPE — every
BST-element-is-the-package case: `tar.bst`, `libidn2.bst`, `python3-markdown.bst`, etc.)
checks the bare package **name** against *every* GHSA language namespace, not just a
plausible one. That produces confirmed false positives — GNU tar matched against npm
`tar`/`node-tar`, zlib against a Ruby gem — documented with full evidence in
`docs/skills/sbom.md` § Mitigated: Grype `stock-matcher` cross-ecosystem false positives.

`.grype.yaml` suppresses the *known* instances via pinned `(vulnerability, package.name,
package.version)` ignore rules. It does **not** generalize: a new purl-less package, or an
existing one that bumps to a new version, needs re-triage. This skill is that re-triage
procedure — run it whenever `mise run vuln-scan`'s match count or severity mix looks off,
or periodically as part of vuln-scan hygiene.

**Never auto-write to `.grype.yaml` without presenting candidates first** — silently
suppressing a vulnerability match is a judgment call with real security consequence, not a
mechanical cleanup. Same posture as `upstream-lessons`' "present, don't just apply."

## Workflow

### 1. Fresh scan

```bash
mise run vuln-scan
```

Writes `krytis.grype.json` (post-ignore-rule report) and, as an intermediate,
`krytis.enriched.spdx.json` (the SBOM Grype actually scanned — has the BST element
provenance for every package, in `externalRefs[].referenceLocator`).

### 2. Find new purl-less `stock-matcher` candidates

These are the only matches capable of this false-positive class — anything with a purl
(`rust-matcher`, `python-matcher`, etc.) or CPE is ecosystem-scoped and trustworthy by
construction.

```bash
jq -c '.matches[]
  | select(.matchDetails[0].matcher == "stock-matcher"
           and (.artifact.purl == null or .artifact.purl == ""))
  | {name: .artifact.name, version: .artifact.version,
     vuln: .vulnerability.id, ns: .matchDetails[0].searchedBy.namespace,
     sev: .vulnerability.severity}' krytis.grype.json > /tmp/candidates.jsonl
```

Cross off anything already covered by an existing `.grype.yaml` rule (same
`vulnerability`+`package.name`+`package.version`) — those are already suppressed and won't
appear in `krytis.grype.json`'s `matches` at all (Grype moves them to the ignored count).
So everything in `/tmp/candidates.jsonl` is genuinely new or has a version that no longer
matches a pinned rule.

### 3. Classify by ecosystem mismatch

For each candidate, look up its real provenance in the enriched SBOM:

```bash
jq -r --arg name "$NAME" '.packages[]
  | select(.name == $name)
  | [.versionInfo, (.externalRefs // [] | map(.referenceLocator) | join(";"))]
  | @tsv' krytis.enriched.spdx.json | sort -u
```

This returns the BST element path(s) that produced the package, e.g.
`freedesktop-sdk.bst:components/tar.bst` or `freedesktop-sdk.bst:components/python3-pil.bst`.

Apply the validated heuristic (confirmed against the 2026-08-05 scan: it correctly separates
real matches on `Pillow`/`cryptography`/`setuptools` — all `python3-*.bst` elements matched
under `github:language:python` — from false positives on `markdown`/`networkx` — also
`python3-*.bst` elements, but matched under `github:language:javascript`):

- `ns == "bitnami"` → **trust by default**, not a candidate. Bitnami's DB is product-scoped,
  not a bare-name language search.
- `ns` starts with `github:language:<X>` → infer the artifact's real ecosystem from its BST
  element path: `python3-*`/`python-*` component name segment → real ecosystem `python`;
  anything else (a plain C/C++/meson/cmake component name) → real ecosystem `native`
  (i.e. not any scripting-language package registry).
  - `X == real ecosystem` → **likely a genuine match** (e.g. `python == python`). Don't add
    to `.grype.yaml` on ecosystem grounds alone — if it still looks wrong (implausible
    `fixed-in` version given the project's real version history), that's a different kind of
    false positive (see `docs/skills/sbom.md` § the *first* two mitigated classes:
    wrapper-package and hash-version) — investigate separately, don't force it into this
    skill's bucket.
  - `X != real ecosystem` → **confirmed false positive**. A `native` (C/C++) package can
    never legitimately be `github:language:javascript`/`ruby`/`php`/etc, and a `python`
    package matched under a *different* language namespace than `python` is the same class
    of bug already confirmed for `markdown`/`networkx`.
- Any other `ns` shape (not seen yet, e.g. a new GHSA namespace kind) → don't guess;
  present it to the user as "unclassified, needs manual read" rather than silently bucketing
  it either way.

### 4. Check for stale `.grype.yaml` rules

An ignore rule's `package.version` is pinned deliberately — when the underlying BST element
bumps, the old rule goes inert (harmless, but it's dead weight and the *new* version is
unprotected, which is exactly what step 2 already catches as a "new candidate"). Find rules
with no matching installed package left in the current SBOM:

```bash
jq -r '.packages[] | "\(.name)\t\(.versionInfo)"' krytis.enriched.spdx.json | sort -u > /tmp/installed.tsv
# Then diff .grype.yaml's (package.name, package.version) pairs against /tmp/installed.tsv.
```

Anything in `.grype.yaml` with no corresponding row in `/tmp/installed.tsv` is stale —
propose removing it in the same change as adding the new pinned rule for the bumped version
(after re-classifying the new version per step 3 — don't assume the same package name is
still a false positive without checking `searchedBy.namespace` again).

### 5. Present candidates

For every confirmed-false-positive candidate and every stale rule found, list: package name,
old/new version, vulnerability ID, the real BST element path, and the mismatched namespace.
Ask the user to confirm before writing anything — mirror `upstream-lessons` step 4. Anything
classified "likely a genuine match" or "unclassified" in step 3 is reported too, but as
*not* recommended for the ignore list.

### 6. Update `.grype.yaml` and `docs/skills/sbom.md`

On approval:

- Add new `ignore:` entries to `.grype.yaml`, matching the existing shape — one `# <name>:
  <real identity>` comment per package group, then `vulnerability`/`package.name`/
  `package.version` per entry. Remove confirmed-stale entries.
- Update the evidence table in `docs/skills/sbom.md` § Mitigated: Grype `stock-matcher`
  cross-ecosystem false positives with any newly confirmed packages, keeping it the
  authoritative record (this is the self-improvement-loop mandate — the doc and the rule
  land together, not as a follow-up).

### 7. Re-verify

```bash
mise run vuln-scan
```

Confirm: the match count drops by exactly the number of newly-ignored matches, Grype's own
`ignored` count in the terminal summary increases by the same amount, and — critically —
no severity bucket you *didn't* touch changed. A `critical`/`high` count dropping by more
than the confirmed false positives means a real vulnerability just got silently suppressed
by an overly broad rule; stop and re-check the rule's `package.version` pin before trusting
the new total.

### 8. Commit and PR

Follow `AGENTS.md`'s worktree/branch policy (this is "no issue" maintenance work unless the
user ties a run to a specific issue). Commit `.grype.yaml` + `docs/skills/sbom.md` together.
PR, don't merge — Merge Gate is always human, same as every other change in this repo.

## Reference

`docs/skills/sbom.md` has the full original investigation (2026-08-05 scan, Grype 0.116.1,
111→69 matches) that established this pattern and seeded the current `.grype.yaml`. Grype's
own ignore-rule schema: `grype config` (look at the `ignore:` block's comment header).
