#!/usr/bin/env python3
"""Diff two Grype JSON reports to find vulnerability matches a PR introduces
or fixes versus its base commit (#41 follow-up). Used by
`.github/workflows/vuln-diff.yml`'s PR gate.

Both inputs are the `-o json` report `mise run vuln-scan` writes, one
generated at the PR's base commit and one at its head. The diff key is
(vulnerability.id, artifact.name, artifact.version) — the same identity
`.grype.yaml`'s own ignore rules use, so a PR that adds/removes an ignore
rule shows up here as fixed/new exactly like a real dependency change would
(each report already reflects its own commit's `.grype.yaml`).

Usage: vuln-diff.py <base.json> <head.json> [--fail-on <severity>]

Writes GitHub-flavored Markdown to stdout — redirect to $GITHUB_STEP_SUMMARY.
Exits 1 only when --fail-on is set (Grype severity: negligible|low|medium|
high|critical) and a NEW match at or above it exists. Empty/unset --fail-on
means report-only: always exits 0. See vuln-diff.yml's header for why this
defaults to non-blocking.
"""
import argparse
import json
import sys

SEVERITY_ORDER = ["Negligible", "Low", "Medium", "High", "Critical"]

Key = tuple[str, str, str]


def load_matches(path: str) -> dict[Key, dict]:
    with open(path) as f:
        report = json.load(f)
    matches: dict[Key, dict] = {}
    for m in report.get("matches", []):
        key = (m["vulnerability"]["id"], m["artifact"]["name"], m["artifact"]["version"])
        matches[key] = m
    return matches


def fmt_row(key: Key, m: dict) -> str:
    vuln_id, name, version = key
    severity = m["vulnerability"].get("severity") or "Unknown"
    data_source = m["vulnerability"].get("dataSource", "")
    fix = m["vulnerability"].get("fix") or {}
    fix_versions = ", ".join(fix.get("versions") or []) or "none"
    return f"| {severity} | `{name}@{version}` | [{vuln_id}]({data_source}) | {fix_versions} |"


def severity_at_least(severity: str, floor: str) -> bool:
    try:
        return SEVERITY_ORDER.index(severity.capitalize()) >= SEVERITY_ORDER.index(floor.capitalize())
    except ValueError:
        # Unknown severity (not in Grype's own scale) never trips a floor.
        return False


def print_table(keys: list[Key], matches: dict[Key, dict]) -> None:
    print("| Severity | Package | Vulnerability | Fixed in |")
    print("|---|---|---|---|")
    for key in keys:
        print(fmt_row(key, matches[key]))
    print()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", help="Grype JSON report generated at the PR's base commit")
    parser.add_argument("head", help="Grype JSON report generated at the PR's head commit")
    parser.add_argument("--fail-on", default="", help="Grype severity; fail if a NEW match is at/above it")
    args = parser.parse_args()

    base = load_matches(args.base)
    head = load_matches(args.head)

    new_keys = sorted(head.keys() - base.keys())
    fixed_keys = sorted(base.keys() - head.keys())
    unchanged = len(head.keys() & base.keys())

    print("## Vulnerability diff vs base\n")
    print(
        f"Base: {len(base)} match(es) &middot; Head: {len(head)} match(es) "
        f"&middot; New: {len(new_keys)} &middot; Fixed: {len(fixed_keys)} "
        f"&middot; Unchanged: {unchanged}\n"
    )

    if new_keys:
        print("### New (introduced by this PR)\n")
        print_table(new_keys, head)
    else:
        print("No new vulnerability matches.\n")

    if fixed_keys:
        print("### Fixed (no longer matched at head)\n")
        print_table(fixed_keys, base)

    if args.fail_on:
        blocking = [
            key for key in new_keys
            if severity_at_least(head[key]["vulnerability"].get("severity") or "Unknown", args.fail_on)
        ]
        if blocking:
            print(f"**FAIL:** {len(blocking)} new match(es) at or above `{args.fail_on}` severity.\n")
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
