#!/usr/bin/env python3
"""Count the elements `mise run build --pull` would have to compile because
neither the local cache nor bow (or a junction's own cache) holds them, and
fail when that exceeds a ceiling. Invoked by `mise run bow-cache-check`.

The count is the build plan BuildStream itself would make, not "how many
elements in the closure are missing". `bst build` (default `--deps run`)
requires the target plus its runtime closure; a required element that is
cached or available remotely is only pulled, and only an element that must be
*built* pulls its build-deps (and their runtime closures) into the plan
(`Element._set_required` / `__schedule_assembly_when_necessary`). So a cached
stack whose own deps were evicted from bow costs nothing, and counting the
whole closure would report a warm tree as cold.

Remote queries are serial, one round trip per element (~3 min for the full
~915-element closure from an empty local cache), so the target's runtime
closure is queried first: when all of it is available — every publish after a
cache-warm of the same commit — the plan is empty and the full query never
runs.

Usage: bow-cache-check.py <target> <max-builds>
"""
import re
import subprocess
import sys
from collections import Counter

BST = ["./mise/tasks/bst", "--pull"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# `bst artifact show` states. "failed" is a cached *failure*: publish builds
# with --retry-failed, so it gets rebuilt.
HAVE = {"cached", "available"}
STATES = HAVE | {"failed", "not cached"}


def bst(*args: str) -> str:
    result = subprocess.run([*BST, *args], stdout=subprocess.PIPE, text=True)
    if result.returncode != 0:
        # bst already printed its own error on stderr.
        sys.exit(f"ERROR: bst {args[0]} {args[1]} failed (exit {result.returncode})")
    return ANSI.sub("", result.stdout)


def parse_list(lines: list[str]) -> list[str]:
    # bst renders these with a YAML dump: `- name` per entry, `[]` when empty.
    return [line[2:].strip() for line in lines if line.startswith("- ")]


def load_graph(target: str) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    build: dict[str, list[str]] = {}
    run: dict[str, list[str]] = {}
    out = bst("show", "--deps", "all", "--format", "@@ %{name}\n%{build-deps}\n##\n%{runtime-deps}", target)
    for record in out.split("@@ ")[1:]:
        lines = record.splitlines()
        name = lines[0].strip()
        split = lines.index("##")
        build[name] = parse_list(lines[1:split])
        run[name] = parse_list(lines[split + 1:])
    return build, run


def query_states(target: str, deps: str) -> dict[str, str]:
    states = {}
    for line in bst("artifact", "show", "--deps", deps, target).splitlines():
        line = line.strip()
        for state in STATES:
            if line.startswith(state + " "):
                states[line[len(state) + 1:].strip()] = state
                break
    return states


def plan(target: str, build: dict, run: dict, states: dict) -> list[str] | None:
    """Elements bst would build, in discovery order; None if a needed state is unknown."""
    required: list[str] = []
    seen: set[str] = set()

    def require(element: str) -> None:
        if element in seen:
            return
        seen.add(element)
        required.append(element)
        for dep in run[element]:
            require(dep)

    require(target)
    to_build = []
    i = 0
    while i < len(required):
        element = required[i]
        i += 1
        if element not in states:
            return None
        if states[element] in HAVE:
            continue
        to_build.append(element)
        for dep in build[element]:
            require(dep)
    return to_build


def project(element: str) -> str:
    return element.split(":", 1)[0] if ":" in element else "krytis"


def main() -> int:
    target, max_builds = sys.argv[1], int(sys.argv[2])
    build, run = load_graph(target)

    states = query_states(target, "run")
    to_build = plan(target, build, run, states)
    if to_build is None:
        print(f"==> {target} is not fully cached — querying the whole closure")
        states = query_states(target, "all")
        to_build = plan(target, build, run, states)
        if to_build is None:
            print("ERROR: bst artifact show omitted an element the build plan needs", file=sys.stderr)
            return 2

    by_project = Counter(project(e) for e in to_build)
    summary = ", ".join(f"{n} {p}" for p, n in by_project.most_common()) or "nothing"
    print(f"==> Would build {len(to_build)} of {len(build)} elements ({summary}); ceiling {max_builds}")
    for element in to_build:
        print(f"    {element}")

    if len(to_build) > max_builds:
        print(
            f"ERROR: bow is cold for this tree — {len(to_build)} elements to compile, ceiling {max_builds}.\n"
            "  Warm it first: dispatch cache-warm.yml on this commit, then re-run.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
