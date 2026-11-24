#!/usr/bin/env python3
"""Reduce one `mise run oomd-test --scenario swap` run to a results row (#1752).

Inputs, in --dir (fetched from the guest by scripts/oomd-test-swap.sh):
  oomd.log    journalctl -u systemd-oomd -o short-unix -g 'Marked |conditions met'
  kernel.log  journalctl _TRANSPORT=kernel -o short-unix -g 'invoked oom-killer|oom-kill:'
  mon.tsv     epoch MemTotal MemAvailable SwapTotal SwapFree app_full_avg10, every 250 ms

Exit status: 0 for a clean run, 2 when #1752's decision rule 1 disqualifies it
(a kill outside app.slice, or the idle app.slice sibling or the session.slice
canary lost), 3 when nothing was killed.
"""

import argparse
import re
import sys

COLUMNS = [
    "epoch", "image", "oomd", "part", "run", "killer", "invoker", "victim",
    "kills", "swap90_to_kill_s", "swap_peak_pct", "canary_worst_ms",
    "app_full_avg10_at_kill", "mem_avail_pct_at_kill", "outside_app", "idle", "canary",
]

# oomd-manager.c: "Marked <path> for killing due to ..."
OOMD_RE = re.compile(r"^(\d+\.\d+) .*systemd-oomd\[\d+\]: Marked (\S+) for killing due to (.*)$")
# oomd-manager.c ruleset_execute_action(): "Rule '<name>' conditions met for cgroup <monitored>, ..."
# It never names the victim; --oom-units (units with Result=oom-kill) does.
RULE_RE = re.compile(r"^(\d+\.\d+) .*systemd-oomd\[\d+\]: Rule '([^']+)' conditions met for cgroup (\S+?),? ")
# mm/oom_kill.c dump_header(): "<comm> invoked oom-killer: gfp_mask=..."
INVOKE_RE = re.compile(r"^(\d+\.\d+) .*kernel: (.+?) invoked oom-killer:")
# mm/oom_kill.c dump_oom_victim(): "oom-kill:constraint=...,task_memcg=<path>,task=<comm>,..."
KILL_RE = re.compile(r"^(\d+\.\d+) .*kernel: oom-kill:constraint=([A-Z_]+),.*task_memcg=([^,]+),task=([^,]+),")


def read_lines(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except OSError:
        return []


def analyse(a):
    kills = []  # (time, killer, invoker, victim)
    for line in read_lines(f"{a.dir}/oomd.log"):
        m = OOMD_RE.match(line)
        if m:
            reason = "pressure" if m.group(3).startswith("memory pressure") else "swap"
            kills.append((float(m.group(1)), f"oomd-{reason}", "-", m.group(2)))
            continue
        m = RULE_RE.match(line)
        if m:
            units = [u for u in a.oom_units.split(",") if u and u != "-"]
            victim = f"{m.group(3)}/{units[0]}" if units else f"{m.group(3)}/?"
            kills.append((float(m.group(1)), f"oomd-rule:{m.group(2)}", "-", victim))
    invoker = "-"
    for line in read_lines(f"{a.dir}/kernel.log"):
        m = INVOKE_RE.match(line)
        if m:
            invoker = m.group(2)
            continue
        m = KILL_RE.match(line)
        if m:
            killer = "kernel-memcg" if m.group(2) == "CONSTRAINT_MEMCG" else "kernel"
            kills.append((float(m.group(1)), killer, invoker, f"{m.group(3)} ({m.group(4)})"))
            invoker = "-"
    kills.sort()

    mon = []
    for line in read_lines(f"{a.dir}/mon.tsv"):
        f = line.split("\t")
        if len(f) == 6:
            t, mt, ma, st, sf = (float(x) for x in f[:5])
            mon.append((t, mt, ma, st, sf, f[5]))

    row = dict.fromkeys(COLUMNS, "-")
    row.update(image=a.image, oomd=a.oomd, part=a.part, run=a.run, canary_worst_ms=a.canary_ms,
               idle=a.idle, canary=a.canary, kills=str(len(kills)))
    row["epoch"] = str(int(mon[0][0])) if mon else "-"
    if mon:
        row["swap_peak_pct"] = f"{max(100 * (st - sf) / st for _, _, _, st, sf, _ in mon if st > 0):.1f}" \
            if any(r[3] > 0 for r in mon) else "-"
    prefix = a.app_slice.rstrip("/") + "/"
    outside = [k for k in kills if not k[3].startswith(prefix)]
    row["outside_app"] = ",".join(k[3] for k in outside) if outside else "no"

    if kills:
        tk, killer, inv, victim = kills[0]
        row.update(killer=killer, invoker=inv, victim=victim.removeprefix(prefix))
        t90 = next((r[0] for r in mon if r[3] > 0 and (r[3] - r[4]) >= 0.9 * r[3]), None)
        if t90 is not None and t90 <= tk:
            row["swap90_to_kill_s"] = f"{tk - t90:.1f}"
        else:
            row["swap90_to_kill_s"] = "never"
        before = [r for r in mon if r[0] <= tk]
        if before:
            r = before[-1]
            row["app_full_avg10_at_kill"] = r[5]
            row["mem_avail_pct_at_kill"] = f"{100 * r[2] / r[1]:.1f}"

    status = 0
    if not kills:
        status = 3
    if outside or a.idle != "active" or a.canary != "active":
        status = 2
    return "\t".join(row[c] for c in COLUMNS), status


def describe(row):
    r = dict(zip(COLUMNS, row.split("\t")))
    return "\n".join([
        f"killer={r['killer']} invoker={r['invoker']} victim={r['victim']} (kills this run: {r['kills']})",
        f"swap>=90% -> kill: {r['swap90_to_kill_s']} s, swap peak {r['swap_peak_pct']} %, "
        f"canary worst wake-up {r['canary_worst_ms']} ms, app.slice full avg10 at kill {r['app_full_avg10_at_kill']}, "
        f"MemAvailable at kill {r['mem_avail_pct_at_kill']} %",
        f"outside app.slice: {r['outside_app']}; idle sibling {r['idle']}; session.slice canary {r['canary']}",
    ])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--header", action="store_true")
    p.add_argument("--describe")
    for opt in ("dir", "app-slice", "image", "oomd", "part", "run", "canary-ms", "oom-units", "idle", "canary"):
        p.add_argument(f"--{opt}", default="-")
    a = p.parse_args()
    if a.header:
        print("\t".join(COLUMNS))
        return 0
    if a.describe:
        print(describe(a.describe))
        return 0
    row, status = analyse(a)
    print(row)
    return status


if __name__ == "__main__":
    sys.exit(main())
