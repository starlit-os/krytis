#!/usr/bin/env python3
"""Render a Grype JSON vulnerability report as a GitHub Actions job summary
table (#41 follow-up). Used by `.github/workflows/vuln-scan.yml`'s periodic
report — the single-report counterpart to `vuln-diff.py`'s base/head diff.

Reads the `-o json` report `mise run vuln-scan` writes: Grype's own JSON
schema, already filtered through `enrich-sbom-purls.py`'s preprocessing and
`.grype.yaml`'s ignore rules (see docs/skills/sbom.md).

Usage: vuln-summary.py <report.json>

Writes GitHub-flavored Markdown to stdout — redirect to $GITHUB_STEP_SUMMARY
for an inline, no-download-needed view of the report in the Actions UI.
"""
import json
import sys
from collections import Counter

SEVERITY_ORDER = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]


def severity_rank(severity: str) -> int:
    return SEVERITY_ORDER.index(severity) if severity in SEVERITY_ORDER else len(SEVERITY_ORDER)


def fmt_row(m: dict) -> str:
    severity = m["vulnerability"].get("severity") or "Unknown"
    name = m["artifact"]["name"]
    version = m["artifact"]["version"]
    vuln_id = m["vulnerability"]["id"]
    data_source = m["vulnerability"].get("dataSource", "")
    fix = m["vulnerability"].get("fix") or {}
    fix_versions = ", ".join(fix.get("versions") or []) or "none"
    return f"| {severity} | `{name}@{version}` | [{vuln_id}]({data_source}) | {fix_versions} |"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: vuln-summary.py <report.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1]) as f:
        report = json.load(f)
    matches = report.get("matches", [])
    ignored = len(report.get("ignoredMatches", []))

    print("## Vulnerability report\n")
    print(f"{len(matches)} match(es) ({ignored} suppressed via `.grype.yaml`)\n")

    if matches:
        counts = Counter(m["vulnerability"].get("severity") or "Unknown" for m in matches)
        print("| Severity | Count |")
        print("|---|---|")
        for sev in SEVERITY_ORDER:
            if counts.get(sev):
                print(f"| {sev} | {counts[sev]} |")
        print()

        matches.sort(key=lambda m: severity_rank(m["vulnerability"].get("severity") or "Unknown"))
        print("<details><summary>All matches</summary>\n")
        print("| Severity | Package | Vulnerability | Fixed in |")
        print("|---|---|---|---|")
        for m in matches:
            print(fmt_row(m))
        print("\n</details>\n")
    else:
        print("No unignored vulnerability matches.\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
