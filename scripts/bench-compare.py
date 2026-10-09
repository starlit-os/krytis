#!/usr/bin/env python3
"""Read and compare cold-build benchmark runs (#1126).

Each run of `.github/workflows/bench-cold-build.yml` uploads one directory:

  bench.env      KEY=VALUE: runner, phase, targets, commit, CPU, RAM, sizing
  timing.txt     KEY=VALUE: START/END epoch seconds of the build step, EXIT
  host.txt       raw lscpu, meminfo, swap, df, os-release, uname
  vmstat.log     `vmstat -n -t 30` over the build step
  oom.txt        kernel OOM lines logged since START
  states.tsv     `bst show --deps all` state|full-key|name after the build
  bst-build.log  the teed `bst build` output

Usage:
  bench-compare.py check  <dir>             exit 1 if the run pulled anything
  bench-compare.py report <group>...        Markdown comparison to stdout

A group is one directory, or several joined with `+` for a run that was resumed
after a failure (`resume=true`): their wall times, element times and samples add
up into one column. `mise run bench-compare` downloads the artifacts by run ID
and calls `report`; the workflow calls `check` and a one-group `report`.
"""
import importlib.util
import re
import sys
from pathlib import Path

# The parsers cache-warm.yml's report already uses, so the two cannot drift.
_spec = importlib.util.spec_from_file_location(
    "cache_summary", Path(__file__).with_name("cache-summary.py"))
cache_summary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cache_summary)

OTHERS_SHOWN = 20


def read_kv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


def read_vmstat(path: Path) -> list[dict[str, int]]:
    """Samples as {column: value}. The first sample is the since-boot average, dropped."""
    if not path.exists():
        return []
    names: list[str] = []
    rows: list[dict[str, int]] = []
    for line in path.read_text(errors="replace").splitlines():
        cols = line.split()
        if not cols:
            continue
        if cols[:3] == ["r", "b", "swpd"]:
            names = cols
            continue
        if not names or not cols[0].isdigit():
            continue
        rows.append({n: int(v) for n, v in zip(names, cols) if v.isdigit()})
    return rows[1:]


def p95(values: list[int]) -> int:
    s = sorted(values)
    return s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]


def load_group(spec: str) -> dict:
    dirs = [Path(d) for d in spec.split("+")]
    for d in dirs:
        if not d.is_dir():
            sys.exit(f"bench-compare: {d} is not a directory")
    env = read_kv(dirs[0] / "bench.env")
    wall = 0
    exits: list[str] = []
    run_ids: list[str] = []
    samples: list[dict[str, int]] = []
    ooms = 0
    times: dict[str, dict[str, int]] = {"build": {}, "fetch": {}, "pull": {}}
    failed: set[tuple[str, str]] = set()
    for d in dirs:
        t = read_kv(d / "timing.txt")
        run_ids.append(read_kv(d / "bench.env").get("RUN_ID", d.name))
        if t.get("START", "").isdigit() and t.get("END", "").isdigit():
            wall += int(t["END"]) - int(t["START"])
        exits.append(t.get("EXIT", "?"))
        samples += read_vmstat(d / "vmstat.log")
        oom = d / "oom.txt"
        if oom.exists():
            ooms += sum(1 for line in oom.read_text(errors="replace").splitlines()
                        if re.search(r"killed process", line, re.I))
        names_by_key = {}
        if (d / "states.tsv").exists():
            rows = cache_summary.read_states(str(d / "states.tsv"))
            names_by_key = {key[:8]: name for _, key, name in rows if key}
        if (d / "bst-build.log").exists():
            done, fails = cache_summary.read_events(str(d / "bst-build.log"), names_by_key)
            for op in times:
                for name, secs in done[op].items():
                    times[op][name] = times[op].get(name, 0) + secs
            failed |= fails
    # Across a resumed group, a failure that a later attempt got past is not a
    # failure of the group: the same operation succeeded, or the element built
    # (it cannot build without its sources). L's phase 2 (37737682742+
    # 37739757304): libdvdcss's fetch crashed attempt 1, and attempt 2 fetched
    # it in the pre-fetch step, so its fetch never appears in either build log.
    failed = {(op, n) for op, n in failed if n not in times.get(op, {}) and n not in times["build"]}
    return {
        "label": f"{env.get('RUNNER', '?')} / {env.get('PHASE', '?')}",
        "dirs": dirs, "env": env, "run_ids": run_ids, "wall": wall, "exits": exits,
        "samples": samples, "ooms": ooms, "times": times, "failed": failed,
    }


def fmt(secs: int) -> str:
    return cache_summary.fmt_duration(secs)


def stat(samples: list[dict[str, int]], col: str) -> str:
    vals = [s[col] for s in samples if col in s]
    if not vals:
        return "n/a"
    return f"{sum(vals) / len(vals):.1f}% / {p95(vals)}%"


def report(groups: list[dict]) -> None:
    head = "| | " + " | ".join(g["label"] for g in groups) + " |"
    sep = "|---|" + "---|" * len(groups)

    def row(name: str, fn) -> None:
        print(f"| {name} | " + " | ".join(str(fn(g)) for g in groups) + " |")

    print("### Runs\n")
    print(head)
    print(sep)
    row("Run IDs", lambda g: "+".join(g["run_ids"]))
    row("Commit", lambda g: f"`{g['env'].get('SHA', '?')[:12]}`")
    row("Targets", lambda g: g["env"].get("TARGETS", "?").replace(" ", "<br>"))
    row("CPU", lambda g: g["env"].get("CPU_MODEL", "?"))
    row("vCPU", lambda g: g["env"].get("NPROC", "?"))
    row("MemTotal", lambda g: f"{int(g['env'].get('MEM_TOTAL_KB', '0')) / 1048576:.1f} GiB")
    row("builders × max-jobs", lambda g: f"{g['env'].get('BUILDERS', '?')} × {g['env'].get('MAX_JOBS', '?')}")
    row("**Wall time (build step)**", lambda g: f"**{fmt(g['wall'])}**" if g["wall"] else "n/a")
    row("Exit status", lambda g: ", ".join(g["exits"]))
    row("Elements built", lambda g: len(g["times"]["build"]))
    row("Build time, sum over elements", lambda g: fmt(sum(g["times"]["build"].values())))
    row("Fetch time, sum over elements", lambda g: fmt(sum(g["times"]["fetch"].values())))
    row("Pulled from a remote (must be 0)", lambda g: len(g["times"]["pull"]))
    row("Failed operations", lambda g: len(g["failed"]))
    row("CPU steal, mean / p95", lambda g: stat(g["samples"], "st"))
    row("iowait, mean / p95", lambda g: stat(g["samples"], "wa"))
    row("Peak swap used", lambda g: f"{max((s.get('swpd', 0) for s in g['samples']), default=0) / 1024:.0f} MiB")
    row("OOM kills", lambda g: g["ooms"])
    print()

    built = {name for g in groups for name in g["times"]["build"]}
    longest = {name: max(g["times"]["build"].get(name, 0) for g in groups) for name in built}
    toolchain = sorted((n for n in built if cache_summary.TOOLCHAIN.match(n)), key=lambda n: -longest[n])
    others = sorted((n for n in built if not cache_summary.TOOLCHAIN.match(n)), key=lambda n: -longest[n])
    if not built:
        return
    print("### Element build times\n")
    print(f"Toolchain elements ({len(toolchain)}), then the {min(OTHERS_SHOWN, len(others))} slowest others; "
          "slowest first by the longest time in any column.\n")
    print("| Element | " + " | ".join(g["label"] for g in groups) + " |")
    print("|---|" + "---|" * len(groups))
    for name in toolchain + others[:OTHERS_SHOWN]:
        cells = [fmt(g["times"]["build"][name]) if name in g["times"]["build"] else "" for g in groups]
        print(f"| `{name}` | " + " | ".join(cells) + " |")
    print()


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "check" and len(sys.argv) == 3:
        g = load_group(sys.argv[2])
        pulled = sorted(g["times"]["pull"])
        if pulled:
            print(f"::error::Not a cold build: {len(pulled)} element(s) were pulled from a remote")
            for name in pulled:
                print(f"  {name}")
            return 1
        print(f"==> Cold check passed: nothing pulled; {len(g['times']['build'])} element(s) built.")
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == "report":
        report([load_group(spec) for spec in sys.argv[2:]])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
