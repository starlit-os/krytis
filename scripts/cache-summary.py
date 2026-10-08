#!/usr/bin/env python3
"""Render a BuildStream cache report as a GitHub Actions job summary (#1077).
Used by `.github/workflows/cache-warm.yml`; the cache counterpart to
`vuln-summary.py`'s vulnerability report.

Inputs:
  states.tsv   `bst show --deps all --format '%{state}|%{full-key}|%{name}'`
               of the warmed target, ANSI stripped: the cache state of every
               element of the build closure after the build.
  build.log    optional: the `bst build` output of this run. Lines of the shape
               `[HH:MM:SS][key][   build:element] SUCCESS <element log path>`
               mark a finished build/pull/push/fetch; `[...] FAILURE ...` a
               failure.

Environment (optional): RUNNER_NAME, CACHE_WARM_QUOTA, CACHE_WARM_CAS_SIZE, and
CACHE_REPORT_TARGETS (the build targets, default `oci/krytis/image.bst`).

Usage: cache-summary.py <states.tsv> [<build.log>]

Writes GitHub-flavored Markdown to stdout: redirect to $GITHUB_STEP_SUMMARY.
"""
import os
import re
import sys
from collections import Counter, defaultdict

# The Toolchain Gate's set (AGENTS.md, mise/tasks/toolchain-cache-check).
TOOLCHAIN = re.compile(r"^freedesktop-sdk\.bst:(bootstrap/|components/(llvm|rust)\.bst$)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
EVENT = re.compile(
    r"^\[(?P<time>\d\d:\d\d:\d\d)\]\[(?P<key>[0-9a-f]{8})\]\[\s*(?P<op>build|pull|push|fetch):(?P<name>[^\]]+)\]"
    r" (?P<status>SUCCESS|FAILURE) (?P<rest>.*)$"
)


def project(name: str) -> str:
    return name.split(".bst:", 1)[0] if ".bst:" in name else "krytis"


def seconds(hms: str) -> int:
    h, m, s = (int(x) for x in hms.split(":"))
    return h * 3600 + m * 60 + s


def read_states(path: str) -> list[tuple[str, str, str]]:
    rows = []
    with open(path) as f:
        for line in f:
            parts = ANSI.sub("", line).rstrip("\n").split("|")
            if len(parts) == 3:
                rows.append((parts[0].strip(), parts[1].strip(), parts[2].strip()))
    return rows


def read_events(path: str, names_by_key: dict[str, str]):
    """Return {op: {name: seconds}} for finished operations, and failures."""
    done: dict[str, dict[str, int]] = defaultdict(dict)
    failed: set[tuple[str, str]] = set()
    with open(path, errors="replace") as f:
        for line in f:
            m = EVENT.match(ANSI.sub("", line).strip())
            if not m:
                continue
            # The element column is truncated on a narrow terminal; the key is not.
            name = names_by_key.get(m["key"], m["name"].strip())
            if m["status"] == "FAILURE":
                failed.add((m["op"], name))
            elif m["rest"].endswith(".log") and f"-{m['op']}." in m["rest"]:
                # Only the element's closing line names its own log file;
                # sub-activity SUCCESS lines ("Running commands", …) do not.
                done[m["op"]][name] = seconds(m["time"])
    # A FAILURE line can be one attempt inside an operation that still succeeds:
    # bench run 37664669187 logged `fetch:…bison.bst FAILURE Fetching from <one
    # mirror>`, then fetched it from another. Count only operations that never
    # reached their closing SUCCESS line.
    return done, {(op, name) for op, name in failed if name not in done[op]}


def fmt_duration(s: int) -> str:
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: cache-summary.py <states.tsv> [<build.log>]", file=sys.stderr)
        return 2

    rows = read_states(sys.argv[1])
    total = len(rows)
    cached = sum(1 for state, _, _ in rows if state == "cached")
    toolchain = [r for r in rows if TOOLCHAIN.match(r[2])]
    toolchain_cached = sum(1 for state, _, _ in toolchain if state == "cached")

    print("## BuildStream cache report\n")
    context = [f"runner `{os.environ['RUNNER_NAME']}`"] if os.environ.get("RUNNER_NAME") else []
    if os.environ.get("CACHE_WARM_QUOTA"):
        context.append(f"casd quota {os.environ['CACHE_WARM_QUOTA']}")
    if os.environ.get("CACHE_WARM_CAS_SIZE"):
        context.append(f"local cache {os.environ['CACHE_WARM_CAS_SIZE']}")
    targets = ", ".join(f"`{t}`" for t in os.environ.get("CACHE_REPORT_TARGETS", "oci/krytis/image.bst").split())
    print(f"Build closure of {targets}" + (f" ({', '.join(context)})" if context else "") + ".\n")

    if total == 0:
        print("**No element states were recorded** — `bst show` failed or never ran.\n")
        return 0

    verdict = "complete" if cached == total else "incomplete"
    print(f"**{cached} of {total} elements cached — {verdict}.** "
          f"Toolchain (`bootstrap/*`, `llvm`, `rust`): {toolchain_cached} of {len(toolchain)} cached.\n")

    by_project: dict[str, Counter] = defaultdict(Counter)
    for state, _, name in rows:
        by_project[project(name)]["total"] += 1
        by_project[project(name)]["cached"] += state == "cached"
    print("| Project | Cached | Total |")
    print("|---|---|---|")
    for proj in sorted(by_project, key=lambda p: (p != "krytis", p)):
        c = by_project[proj]
        print(f"| {proj} | {c['cached']} | {c['total']} |")
    print()

    names_by_key = {key[:8]: name for _, key, name in rows if key}
    if len(sys.argv) == 3 and os.path.exists(sys.argv[2]):
        done, failed = read_events(sys.argv[2], names_by_key)
        print("### This run\n")
        print("| Built | Pulled from a remote | Pushed to a remote | Failed |")
        print("|---|---|---|---|")
        print(f"| {len(done['build'])} | {len(done['pull'])} | {len(done['push'])} | {len(failed)} |\n")
        for op, name in sorted(failed):
            print(f"- **{op} failed:** `{name}`")
        if failed:
            print()
        unpushed = sorted(set(done["build"]) - set(done["push"]))
        if unpushed:
            print(f"**{len(unpushed)} element(s) built but not pushed** — lost when this runner's cache evicts them:\n")
            for name in unpushed:
                print(f"- `{name}`")
            print()
        if done["build"]:
            built = sorted(done["build"].items(), key=lambda kv: -kv[1])
            print(f"<details><summary>Built in this run ({len(built)}, slowest first)</summary>\n")
            print("| Element | Build time |")
            print("|---|---|")
            for name, secs in built:
                print(f"| `{name}` | {fmt_duration(secs)} |")
            print("\n</details>\n")
    else:
        print("_No build log; this run's build/pull/push activity is not shown._\n")

    missing = [r for r in rows if r[0] != "cached"]
    if missing:
        missing.sort(key=lambda r: (not TOOLCHAIN.match(r[2]), r[2]))
        states = Counter(state for state, _, _ in missing)
        summary = ", ".join(f"{n} {s}" for s, n in states.most_common())
        print(f"<details><summary>Not cached ({len(missing)}: {summary}; toolchain first)</summary>\n")
        print("| State | Key | Element |")
        print("|---|---|---|")
        for state, key, name in missing:
            print(f"| {state} | `{key[:8]}` | `{name}` |")
        print("\n</details>\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
