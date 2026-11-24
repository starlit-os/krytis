# Make oomd catch swap exhaustion

**Issue:** #1752 · **Status (2026-11-24): steps 0–2 done; step 3 running.** Follows #510 and #1216.

## What happened

On 2026-11-21 `melog` (31 GiB RAM, zram-only swap at the time) used all 15.6 GiB of swap
from about 12:27 to 18:01. The kernel OOM killer fired three times. **systemd-oomd
did nothing**: `journalctl _COMM=systemd-oomd` is empty for that afternoon.

| time | victim | `task_memcg` | free swap |
|---|---|---|---|
| 16:10:10 | `steamwebhelper` | `app.slice/app-flatpak-com.valvesoftware.Steam-….scope` | 112 kB |
| 16:15:18 | `qemu-system-x86` (4.8 GiB RSS) | `app.slice/rex.service/terminal-01a1fa58-…` | 200 kB |
| 16:27:39 | `zig` (11.3 GiB RSS) | `app.slice/rex.service/terminal-01a1fe92-…` | 32 kB |

Source: `journalctl _TRANSPORT=kernel --since '2026-11-21 16:00' -g 'oom-kill:|Free swap'`.
Use `_TRANSPORT=kernel`, not `-k`, which reads only the current boot
(`docs/skills/swap-tuning.md`).

## What is known

- **What oomd is armed with** (`config/oomd.bst`, #1216): `ManagedOOMMemoryPressure=kill`
  on every user's `app.slice`, at 50 % for 20 s. No swap kill. The reason given was that a
  `-.slice` swap kill killed browsers on a responsive desktop (Ubuntu LP: #1972159), and
  that a swap kill would depend on #510's choice of backend. That choice is now made.
- **oomd's pressure test is PSI `full avg10`** (`oomd.conf(5)`, systemd 262.2). The
  highest *system-wide* `full avg10` that `swap-eval` sampled that day was 30.36, well
  under 50 %. `app.slice`'s own PSI was not recorded.
- **Only leaf cgroups are candidates**, plus any with `memory.oom.group=1`
  (`systemd-oomd.service(8)`). A kill under `rex.service` takes one terminal's cgroup, not
  every terminal.
- **`ManagedOOMSwap=kill`** acts on the system-wide swap figures. Once swap use passes
  `SwapUsedLimit=` (default 90 %), it kills the eligible descendant with the most swap,
  starting with those using more than 5 % of total swap.
- **systemd 261 added `oomd.conf` rulesets** with `Action=kill-all|kill-by-pgscan|kill-by-swap`.
  #1216 predates them. Read the whole `oomd.conf(5)` section before choosing.
- **All three kills say `kswapd0 invoked oom-killer`.** An allocation that fails names the
  allocating task. kswapd invoking the killer matches MGLRU's `min_ttl_ms` protection, which
  the CachyOS kernel sets to 100 ms (`#ifdef CONFIG_CACHY`, #510 step 0, mainline 0). When
  every generation is younger than `min_ttl_ms`, kswapd calls `out_of_memory()` to keep the
  working set. **Confirm this in `mm/vmscan.c` (`lru_gen_age_node`) of the shipped kernel
  before relying on it.** If it holds, the kernel's MGLRU path is the backstop that actually
  fired, and it picks single processes by `oom_score_adj` (`steamwebhelper` had 300).

## Steps

- [x] **0. Confirm the MGLRU reading.** Check `lru_gen_age_node()` in the `cachyos-<ver>`
  tree that `core/linux-cachyos.bst` repackages, and record the line on #1752. If kswapd
  doesn't call `out_of_memory()` there, find out what did.
  Result (2026-11-24, #1752 comment): it holds. `CachyOS/linux` tag `cachyos-7.3.5-2`
  `mm/vmscan.c` L4213–4217 sets `lru_gen_min_ttl = 100` under `CONFIG_CACHY` (jiffies;
  `CONFIG_HZ=1000`), and `lru_gen_age_node()` (L4219, kswapd only) calls `out_of_memory()`
  when no memcg's oldest generation is older. `cachyos-7.3.4-1` is identical.
- [x] **1. Record `app.slice` pressure in `swap-eval sample`.** Append columns at the end
  of the row, so older logs still parse:
  - `app_psi_full_avg10` and `app_psi_full_total_us` from
    `/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/app.slice/memory.pressure`
  - `app_swap_k` from that cgroup's `memory.swap.current`

  `summary` gains `max app full avg10` and `samples ≥ 50 % app full`. Both machines already
  sample on every login (#1748), so this data arrives without anyone starting anything.
  Skill entry: `docs/skills/swap-tuning.md` § Measuring.
- [x] **2. Add a swap-exhaustion scenario to `mise run oomd-test`.** The task already boots
  the image, starts a lingering user's manager and runs a python3 hog in `app.slice`
  (`docs/skills/desktop.md` § systemd-oomd, "Proof run"). Its existing hog uses
  `MemoryHigh=128M` and proves the pressure kill. Add `--scenario swap`, which runs the hog
  with no `MemoryHigh=` and fills RAM and then swap (the VM gets its #1750 swapfile).
  Keep the four lessons that section records (`setpriv` instead of `runuser`, no
  `tail /dev/zero`, `MemoryHigh=` rather than `MemoryMax=`, root's `app.slice` is listed
  too). The new scenario has three parts:
  - **fast:** one process allocating and touching anonymous memory at about 1 GiB/s.
  - **slow:** four processes, each growing about 50 MiB/s, which is closer to 2026-11-21.
  - **canary:** the existing `session.slice` canary also logs how late it wakes every
    100 ms. That is the responsiveness proxy, since the VM has no desktop.

  For each run, record: which mechanism killed (oomd's `Marked … for killing` line,
  `invoked oom-killer` and whether it was kswapd or a task), which cgroup, time from swap
  ≥ 90 % to the kill, the canary's worst wake-up delay, and `app.slice` `full avg10` at the
  kill. Skill entry: `docs/skills/desktop.md` § systemd-oomd, "Proof run".
  Result (2026-11-24): `--oomd <config>`, `--parts`, `--runs` and `--results` added;
  `--reuse-disk` of one `generate-disk --size 24G` disk runs the matrix without root. Trial
  on image `26.08.202611232111`, `--oomd current`: both parts were killed by the kernel
  (`kswapd0 invoked oom-killer`) 1.6 s and 4.2 s after swap reached 90 %, oomd logged
  nothing, and the canary's worst wake-up was 28 ms (fast) and 409 ms (slow). That is the
  2026-11-21 pattern.
- [ ] **3. Run the matrix on the #1750 image** (zswap + swapfile), 3 runs per cell, each
  scenario under each config, applied as runtime drop-ins in the VM:
  - **current:** pressure kill on `app.slice` at 50 %/20 s
  - **+swap:** also `ManagedOOMSwap=kill` on `app.slice` (system `SwapUsedLimit=90%`)
  - **ruleset:** an `oomd.conf` ruleset with `Action=kill-by-swap` scoped to `app.slice`,
    if `oomd.conf(5)` allows that scoping
  - **lower pressure:** pressure kill at 30 %/10 s
- [ ] **4. Decide**, using rules fixed now, before any data:
  1. A config is disqualified if it ever kills anything outside `app.slice`, or kills
     `rex.service` or a `session.slice` unit as a whole.
  2. Among the rest, prefer the one whose kill comes first (lowest median time from swap
     ≥ 90 %) **and** that keeps the canary's worst wake-up delay under 1 s. It must win
     both by more than its run-to-run spread.
  3. If nothing beats **current** that way, keep **current**. Document MGLRU and the kernel
     as the swap-exhaustion backstop in `docs/skills/desktop.md` § systemd-oomd and
     `swap-tuning.md`, and close #1752 there.
  4. Record the decision and the matrix on #1752 (Design Gate: what gets killed is
     user-visible).
- [ ] **5. Implement** the chosen config in `config/oomd.bst`, and rewrite its header's
  "Deliberately NOT armed" paragraph if the swap-kill reasoning changes. Extend
  `swap-audit`, or add an oomd assertion to `boot-test`, so the unit properties are checked
  in the image (`systemctl --user show app.slice -p ManagedOOMSwap`). Verify with
  `mise run build`, `mise run boot-test` and `mise run oomd-test --scenario swap`.
- [ ] **6. Field check:** after both machines upgrade, keep sampling for 5 working days. Any
  kill goes on #1752 with its oomd or kernel journal line and the `app.slice` columns from
  step 1.
- [ ] **7. Archive:** `git mv` this plan into `docs/plans/done/` in the PR that closes #1752.

## Non-goals

- `session.slice` and `user@.service` stay out of the candidate set (#1216's reasons).
- Tuning MGLRU `min_ttl_ms` is a kernel default, like `swappiness`. If step 0 shows it
  matters, file it separately.
