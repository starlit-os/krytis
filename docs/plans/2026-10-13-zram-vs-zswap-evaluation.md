# Evaluate zram vs zswap

**Issue:** #510 · **Status (2026-10-13): step 1 running.** Step 0 is done on both machines,
which both run image `26.08.202610131212`, and the snapshots are in #510. Natural-demand
sampling started on both the same day.

#510 asks whether krytis should keep zram or move to zswap, decided from measurements on the
desktop and the laptop. This plan sets out how to measure, adds the tool that measures
(`mise run swap-eval`), and fixes the decision rules **before** any data is collected.

## Non-goals

These come from #510 and still apply:

- **swappiness / `vfs_cache_pressure` tuning.** It is a smaller knob and follows once the
  mechanism is chosen. The arms below keep the kernel's values as they are.
- **`config/oomd.bst`.** Finding 3 shows the element does nothing today. That is #1216
  (see [Out of scope, found here](#out-of-scope-found-here)) and is not fixed here.

## What the image ships today

Measured on `adora` on 2026-10-13. Hardware: ThinkPad T14 Gen 4, 31 GiB RAM, Samsung PM981a
512 GB NVMe. Image `26.08.202610102045`, kernel `7.2.9-2-cachyos`. Every figure comes from
`mise run swap-eval snapshot` unless another source is named.

### 1. The image runs zswap *and* zram together

#510 calls the status quo "zram". That is incomplete:

| Layer | Setting | Source |
|---|---|---|
| zswap | `enabled=Y compressor=zstd max_pool_percent=20 shrinker_enabled=Y` | `CONFIG_ZSWAP_DEFAULT_ON=y`, `CONFIG_ZSWAP_SHRINKER_DEFAULT_ON=y`, built into the CachyOS kernel that `core/linux-cachyos.bst` repackages. No karg sets it. |
| zram0 | `zram-size = ram / 2`, `zstd`, swap priority 100 | `/usr/lib/systemd/zram-generator.conf` from `gnome-build-meta.bst:gnomeos-deps/zram-generator.bst` |
| disk swap | none | `/proc/swaps` lists only `/dev/zram0` |

zswap is a cache in front of whatever swap device exists, and here that device is zram.
Every evicted page goes to zswap first. When the zswap pool reaches its limit, or the zswap
shrinker runs, zswap decompresses the page and writes it to zram, which compresses it
again. Three minutes after boot zswap had stored 54 pages while zram held 4 KiB. A
synthetic smoke test of the tool's `pressure` action (1 GiB held under
`MemoryHigh=256M`) showed the same thing at scale: 815 MiB entered zswap and 791 MiB of it
was then written back into zram (`zswpwb`). That run tested the tool, not a workload, so it
is not evidence for any arm.

The [ArchWiki zram page](https://wiki.archlinux.org/title/Zram) tells readers to disable
zswap when using zram, for exactly this reason. CachyOS does it with
[`30-zram.rules`](https://github.com/CachyOS/CachyOS-Settings/blob/master/usr/lib/udev/rules.d/30-zram.rules):
when zram0 initialises, the rule sets `vm.swappiness=150` and writes `N` to
`/sys/module/zswap/parameters/enabled`.

`elements/config/desktop-udev.bst` ports CachyOS-Settings but **left that rule out**. Its
header says the rule "conflicts with zram-generator", and `docs/skills/bst.md` § Desktop
performance config element pattern repeats the claim. The claim is wrong: the rule works
alongside zram-generator and fixes the zswap stacking. Dropping it is why the image runs both.

dakota shipped the same accident: its `d962c8a` (#1131) meant to replace zram with zswap.
The empty `zram-generator.conf` that was meant to disable zram lost the BuildStream
staging-order race to `gnomeos-deps/zram-generator.bst`, so dakota images ran zram and zswap
together with no disk swap behind them. dakota fixed this in `53952c7` (#1262,
2026-08-01). That commit overwrites the config from an integration command, adds
`bluefin/swapfile.bst`, and adds a `just swap-audit` image assertion.

**So the decision has four options, not two, and the current one is the stacking that both
the ArchWiki and CachyOS tell users to avoid.**

### 2. `vm.swappiness=100` and `vm.page-cluster=0` come from the kernel

No file in `/usr/lib/sysctl.d`, `/etc/sysctl.d`, udev or tmpfiles sets either value. Stock
Linux defaults are 60 and 3. Both values are compiled into the CachyOS kernel (confirmed in
step 0 against the `cachyos-7.2.9-2` source tree):

- `vm_swappiness = 100` sits under `#ifdef CONFIG_CACHY` in `mm/vmscan.c`.
- `page_cluster = 0` is set **unconditionally** in `swap_setup()` in `mm/swap.c`.
- MGLRU `min_ttl_ms = 100` (mainline: 0) also sits under `CONFIG_CACHY`. When the working
  set of the last 100 ms can't be kept in memory, it invokes the OOM killer.

A future kernel bump could change any of these without a krytis commit, so the decision PR
must pin whatever the chosen arm relies on.

### 3. systemd-oomd does nothing

`config/oomd.bst` writes its tuning under `[OOMPolicy]`, but systemd-oomd only reads
`[OOM]`. The journal reports
`/usr/lib/systemd/oomd.conf.d/krytis.conf:1: Unknown section 'OOMPolicy'. Ignoring.`, and
`oomctl` shows the default 30 s duration where krytis meant to set 20 s.

The bigger problem is that `oomctl` lists **no** monitored cgroups. Nothing in the image sets
`ManagedOOMSwap=` or `ManagedOOMMemoryPressure=`, so oomd has nothing to act on. #510 and
`elements/stacks/base-system.bst` both describe zram as working together with oomd's
protection, but that protection does not exist. For this evaluation, the "OOM interaction"
column of the article's comparison table can only mean the kernel OOM killer. The laptop
recorded 0 kernel OOM kills and 0 oomd kills in the last 60 days.

### 4. There is no disk swap to put behind zswap

`/var` is a btrfs subvolume (`/dev/mapper/root[/state/os/default/var]`) on LUKS. zswap
without a backing swap device stores nothing, so the zswap and hybrid arms need a swapfile.
On btrfs a swapfile needs NOCOW and a fully written file, and an active swapfile blocks
snapshots of the subvolume it lives in. `swap-eval arm` therefore puts the file in its own
subvolume at `/var/swap`, which is the same path as dakota's `bluefin/swapfile.bst`.

### 5. Laptop history

| Measure (last 60 days, journal) | Value |
|---|---|
| suspend attempts / returned / failed | 136 / 112 / 24 |
| failed, by day | 23 on 2026-09-16 (one 30-minute retry burst, `Failed to freeze unit 'user.slice': Connection timed out`), 1 on 2026-09-08 |
| suspends that never returned | 0 |
| kernel OOM kills / oomd kills | 0 / 0 |
| swap in use at snapshot (0.2 h uptime) | 840 KiB, all of it `ananicy-cpp` |

The journal has no record of how much swap was in use when those suspends failed. Step 1
records swap use from now on, and `summary` reports it for every sleep event that falls
inside the sampled window.

## The four arms

`mise run swap-eval arm <name>` switches between them while the machine is running. It
first drains all swap back into RAM (and refuses unless MemAvailable exceeds swap used plus
1 GiB), so no arm starts with pages the previous arm compressed. **Nothing persists: a
reboot always comes back as `shipped`.** Each sample row records the arm read from the
kernel, so rows logged after a reboot where nobody re-applied the arm are counted under the
arm that was actually running.

| Arm | zswap | zram0 | swapfile | How a shipped default would do it |
|---|---|---|---|---|
| `shipped` | on | on (prio 100) | — | (today) |
| `zram` | off | on (prio 100) | — | port the zswap half of CachyOS `30-zram.rules` into `config/desktop-udev.bst` |
| `zswap` | on | off | on | remove `gnomeos-deps/zram-generator.bst` from `stacks/base-system.bst` (krytis lists it explicitly, so it needs no override and avoids dakota's staging race), then add a swapfile element on dakota's `swapfile.bst` pattern |
| `hybrid` | off | on (prio 100) | on (prio 10) | the `zram` change plus the swapfile element |

Whichever arm wins, the decision PR has to set zswap explicitly, with a karg or a udev rule.
Leaving it to the kernel default is how the image got into its current state.

The swapfile is half of RAM by default (`--size <MiB>` overrides this), the same capacity as
zram0. (This no longer matters for oomd: #1216 armed only a memory-pressure kill on users'
`app.slice` and no swap kill, so oomd never reads swap capacity.)

## Tool: `mise run swap-eval`

`mise/tasks/swap-eval` runs on a booted krytis host and reads the live kernel, not the image.
It needs nothing that is missing from the image. `smem` is not shipped, so the tool reads
`VmSwap` from `/proc/<pid>/status`, the same data smem would use, and adds a per-cgroup view
from `memory.swap.current` and `memory.zswap.current`.

| Action | What it does |
|---|---|
| `snapshot [--days N]` | Prints hardware, the kernel's zswap/zram/MGLRU config, the active arm, `/proc/swaps`, `zramctl`, zswap parameters, the vm sysctls, counters since boot, the top swap users by process and by cgroup, oomd state and config warnings, OOM kills, and suspend history (attempts, returns, failures, sleeps that never returned). |
| `sample [--interval 30] [--detach]` | Appends one TSV row per interval to `$XDG_STATE_HOME/krytis/swap-eval/<host>-<date>-<boot>.tsv`, one file per boot. `--detach` runs it as the transient user unit `swap-eval-sample` (stop it with `systemctl --user stop swap-eval-sample`). |
| `summary [files…]` | Prints one markdown row per arm: hours sampled, peak and p95 swap as % of RAM, samples with zram ≥ 80 % full, peak zswap pool, compression ratios, swap-out to the backing device, zswap writeback, PSI full stall per hour, max PSI `full avg10`, and suspend gaps. A second table shows swap use at each sleep attempt and failure. |
| `arm <shipped\|zram\|zswap\|hybrid> [--size MiB] [--remove-swapfile] [--dry-run]` | Switches the arm at runtime, as described above. |
| `pressure [--high 4G] -- <command>` | Runs a real command in a user scope with `MemoryHigh=`, so the kernel reclaims and swaps that cgroup only while the rest of the desktop is untouched. It reports wall time, the scope's peak memory, swap and zswap, stall time (`some`/`full`), `memory.high` events, and system-wide swap traffic during the run. Each run is appended to `<host>-pressure.tsv`. |

How to read the counters:

- `pswpout` counts pages written to the **backing device**. In `shipped`, `zram` and `hybrid`
  that is mostly zram, which costs CPU but no disk I/O. In `zswap` it is NVMe writes.
- `zswpwb` counts pages zswap pushed down to the backing device. In `shipped` each of them
  was compressed twice. In `zswap` each is a disk write.
- PSI `full` is the share of time in which every non-idle task was stalled on memory. It is
  the closest single number to "the desktop froze".

## Decision rules (fixed before any data)

These rules are applied **separately to each machine**:

1. **`shipped` must beat both `zram` and `zswap` to stay.** Its zswap→zram stacking is
   documented as a defect (finding 1), so it has to prove itself. It stays only if, in
   step 3, it is at least 10 % better than both alternatives on median wall time and median
   `full` stall.
2. **Natural demand decides whether the backend matters at all.** Use p95 and peak swap as a
   share of RAM, from at least 5 working days of `shipped` sampling (step 1):
   - **Peak < 10 % of RAM:** the backend makes no measurable difference on this machine.
     Pick `zram`. It is the smallest change, it writes nothing to disk, and it adds no new
     state under `/var`.
   - **zram ≥ 80 % full in any sample, or peak > 40 % of RAM:** zram's fixed cap can be
     reached. Choose between `zswap` and `hybrid` using rule 3.
   - **In between:** rule 3 decides.
3. **Controlled comparison.** Run the same real command with the same `--high`, at least 3
   times per arm. An arm wins if its median wall time and median `full` stall are both more
   than 10 % better than the next arm, **and** that gap is larger than the arm's own
   run-to-run spread. If no arm clears that bar, the simpler arm wins, in this order:
   `zram` < `zswap` < `hybrid`.
4. **Disk wear.** In the `zswap` and `hybrid` arms, `swap-out to backing device` × 24 h must
   stay under 10 GiB/day under natural load, which is about 18 TiB over five years. Step 0
   records each drive's rated TBW. An arm that would use more than 10 % of that rating in
   five years is disqualified on that machine, even if it stays under 10 GiB/day.
5. **Suspend.** If any sleep failure or sleep that never returned happens while swap is
   above 25 % of RAM, in any arm, investigate it before deciding. Otherwise suspend counts
   neither for nor against an arm.

**Fleet default.** If both machines pick the same arm, that arm ships. If they disagree, the
default is the arm chosen by the machine whose rejected option failed worse: an OOM kill or
hang counts as worse than a latency regression. The other machine's arm is then documented
as a per-host override in `/etc`. For `zram`, that override is
`/etc/systemd/zram-generator.conf`.

## Steps

- [x] **0. Pre-flight** (on both machines). Done 2026-10-13, with both machines on
  `26.08.202610131212`.
  - Put both machines on the same image. Capture
    `mise run swap-eval snapshot > /tmp/<host>-snapshot.txt` and attach the output to #510.
    Result: identical swap configuration on both machines; only the hardware and
    `mem_sleep` differ.
  - Confirm the source of `swappiness=100` / `page-cluster=0` (finding 2) in the CachyOS
    kernel patch set, and note what you find in #510. Result: see finding 2.
  - Record each machine's swap-candidate drive (model and rated TBW) for rule 4. Result:
    `melog` has a 970 EVO 1 TB rated 600 TB. `adora` has a PM981a 512 GB with no published
    rating, so the 970 EVO Plus 500 GB (300 TB) stands in for it. On both machines the
    10 GiB/day cap is the limit that applies.
- [ ] **1. Natural demand, `shipped`**: at least 5 working days per machine.
  - After every boot, run `mise run swap-eval sample --detach`.
  - The workload is whatever you normally do, but include the heaviest regular tasks: the
    browser with its usual tabs, a local `bst` build, and a game if that is normal use.
- [ ] **2. Natural demand, other arms**: at least 3 working days each for `zram`, `zswap`
  and `hybrid`.
  - After every boot, run `mise run swap-eval arm <arm>`, then `sample --detach`.
  - Keep workloads comparable across arms. This step is mainly about demand and disk writes
    (rules 2 and 4). Performance is compared in step 3, because natural workloads differ from
    day to day.
- [ ] **3. Controlled runs.** On each machine, pick two real workloads it actually runs. For
  example, a clean `cargo build --release` of a Rust checkout that is already on disk, or a
  `mise run bst build` of an element whose artifact you have deleted first. Do not pick
  anything that compiles the toolchain (AGENTS.md Toolchain Gate).
  - Calibrate once per workload in `shipped` with `--high infinity` and note `mem_peak`.
  - Set `--high` to about 60 % of that peak, and use the same value for every arm.
  - For each arm (`arm <name>`, then 3× `mise run swap-eval pressure --high <N> -- <cmd>`),
    alternate the order between machines.
- [ ] **4. Report.** For each machine, paste `mise run swap-eval summary` and the
  `<host>-pressure.tsv` rows into a single #510 comment.
- [ ] **5. Decide** per machine and for the fleet using the rules above. Record the decision
  and which rule decided it in #510.
- [ ] **6. Decision PR** (a separate PR that closes #510):
  - Create a new skill doc, `swap-tuning.md`, in the skills directory. It records the
    decision, the data, the zswap-in-front-of-zram trap, and the reason zswap has to be set
    explicitly.
  - Correct the claim that `30-zram.rules` "conflicts with zram-generator" in two places:
    the `elements/config/desktop-udev.bst` header and `docs/skills/bst.md` § Desktop
    performance config element pattern.
  - Implement the chosen arm (see the table above) and update the zram-generator comment in
    `elements/stacks/base-system.bst`. Its oomd comment was already corrected by #1216.
  - Add an image assertion for the shipped arm, following dakota's `just swap-audit`
    precedent, so a later kernel or junction bump cannot silently change the arm again.
  - Verify with `mise run build` and `mise boot-test`. Then reboot both machines into the
    built image and check that `swap-eval snapshot` reports the intended arm.
  - Tick #479's `zswap over zram` item and correct its "deliberately" sentence. Find other
    issue bodies that describe the old setup with
    `gh issue list --state open --search 'zram in:body'` (and the same for `zswap`), and
    correct them.
  - Clean up both machines: `mise run swap-eval arm shipped --remove-swapfile`, then delete
    `~/.local/state/krytis/swap-eval` once the data is in #510.
  - Run `git mv` to move this plan into `docs/plans/done/`.

## Risks

- **Draining swap.** `arm` turns off every swap device before it switches. If RAM is short,
  that could OOM the session. The task refuses unless MemAvailable exceeds swap used plus
  1 GiB.
- **The arm resets on reboot.** This is deliberate: a bad arm cannot outlive one boot. The
  cost is that the arm has to be re-applied after every reboot. If someone forgets, those
  rows are counted under `shipped`, not lost.
- **Workloads differ between arm windows** in steps 1–2. That is why rule 3 compares
  performance only on the controlled runs.
- **One machine's data.** The plan needs both machines. If the desktop data never arrives,
  this issue cannot reach a fleet decision, and the laptop alone is not enough to decide it.

## Out of scope, found here

- **systemd-oomd is inert** (finding 3): the drop-in has the wrong section name and no unit
  opts into `ManagedOOM*`. #510 lists `config/oomd.bst` as a non-goal, so this is tracked
  in #1216. Turning oomd on changes what gets killed under pressure, which is a
  user-visible change and a Design Gate.
