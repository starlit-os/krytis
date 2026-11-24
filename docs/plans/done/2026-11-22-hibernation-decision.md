# Decide hibernation with a swapfile

**Issue:** #1751 · **Status (2026-11-23): done. Option A was chosen, verified in the VM, and
shipped in the PR that archives this plan. Option B is #1755.**
Follows #510's decision, which ships a disk swapfile in #1750.

## Why this exists

Until #1750, krytis's only swap was zram, which logind doesn't count as a hibernation
target. On `melog` (zram image, systemd 262.2, 2026-11-22), `CanHibernate`, `CanHybridSleep`
and `CanSuspendThenHibernate` all return `na`. #1750 adds `/var/swap/swapfile` (MemTotal / 2)
on every machine, and nothing in the image has decided whether hibernation is supported.
What that exposes:

| Path into hibernation | State on the image |
|---|---|
| UPower at critical battery | `CriticalPowerAction=Auto` (`/etc/UPower/UPower.conf`). That file's comment gives the order HybridSleep, then Hibernate, then PowerOff, and this plan first took it at its word. It is stale: upower 1.91.5 maps `Auto` to logind's `Sleep()` (`src/linux/up-backend.c`, `up_backend_get_critical_action`), which picks a mode from `SleepOperation=` (default `suspend-then-hibernate suspend`). `GetCriticalAction` returns `Sleep` on the zram image, so today it **suspends** (found 2026-11-23, step 1). |
| `systemctl hibernate`, apps asking logind | Allowed whenever logind reports `yes` |
| Lid, idle, shell buttons | None. Lid is `suspend` (`config/logind-lid.bst`), and noctalia and noctalia-greeter have no hibernate action (`grep -rIi hibernat`, 2026-11-22) |
| Resume | The initrd has `systemd-hibernate-resume` and its generator (`lsinitrd`). No `resume=` karg; systemd would rely on the `HibernateLocation` EFI variable |

None of these has been tested on krytis: resuming through the LUKS + FIDO2/TPM unlock
(`adora`), resuming after `bootc` staged an update, resuming from the sealed UKI, or
hibernating with more memory in use than the swapfile holds.

## Options

- **A. Turn it off explicitly (recommended).** Add a `sleep.conf.d` drop-in with
  `AllowHibernation=no`, `AllowHybridSleep=no` and `AllowSuspendThenHibernate=no`. logind
  then reports `no`, and UPower's `Sleep()` can only suspend, which is what machines do
  today. Size: S.
- **B. Support it.** Every untested path above would need a hardware test. The swapfile
  probably needs to be at least the size of RAM. It is a separate project with its own
  issue, and this plan only outlines it (step 5).

## Steps

- [x] **1. Measure on the #1750 image** (VM first, then `adora` after its upgrade):
  - `busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate`,
    and the same for `CanHybridSleep` and `CanSuspendThenHibernate`.
  - `busctl call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower GetCriticalAction`
    shows the action UPower would take right now.
  - Note `/sys/power/disk` and `/sys/kernel/security/lockdown`. The kernel refuses to
    hibernate under lockdown; both machines showed `[none]` on 2026-11-22.
  - Post the results to #1751. If logind still says `na`, A changes nothing visible. Do
    it anyway, so a later swap change can't turn hibernation on silently.

    Result (VM, #1750 image with the drop-in, 2026-11-23): `CanHibernate="no"
    CanHybridSleep="no" CanSuspendThenHibernate="no"`, and `GetCriticalAction` = `Sleep`.
    The host on the zram image also returns `Sleep`, which is how the stale UPower comment
    was caught. There was no measurement without the drop-in: A had already been chosen,
    so this step went straight to verifying it.
- [x] **2. Decide A or B** on #1751 (Design Gate: power behaviour is user-visible). A, 2026-11-22.
- [x] **3. Implement A** (first committed to #1750's branch), in the same element as the swapfile, since the swapfile is what
  exposes it:
  - `files/swap/50-krytis-no-hibernate.conf`, installed by `config/swap.bst` into
    `%{indep-libdir}/systemd/sleep.conf.d/`, containing `[Sleep]` with the three `Allow*=no`
    lines. The header explains why, links #1751, and says how a user opts back in: a
    later-sorting drop-in under `/etc/systemd/sleep.conf.d/`.
  - `mise run swap-audit`: assert the drop-in sets all three keys, and that no other
    `sleep.conf.d` file under `/usr` overrides them.
  - `mise run boot-test`: assert logind reports `no` for all three methods, and that
    UPower's `GetCriticalAction` is not `Hibernate` or `HybridSleep` (`Sleep` or `PowerOff`
    pass; the check first demanded `PowerOff` and failed on `Sleep`). Only check when the
    image ships the drop-in,
    so `--reuse-disk` of an older disk still passes.
  - `docs/skills/swap-tuning.md`: a section on why the swapfile doesn't mean hibernation,
    and what UPower's `Auto` really does.
  - `files/fakecap-manifest.tsv`: one row for the new file.
- [x] **4. Verify:** `mise run build`, `mise run boot-test`. Then on `adora` after it
  upgrades, run step 1's commands again and expect `no` / `Sleep`.

  `build --pull` passed every gate (`ok: sleep: hibernation off, set only by
  /usr/lib/systemd/sleep.conf.d/50-krytis-no-hibernate.conf`), and `boot-test` PASSED
  (`swap is zswap in front of /var/swap/swapfile, no zram; hibernation off`). The `adora`
  re-check goes with #1750's upgrade check on both machines, posted on #510.
- [x] **5. B as its own issue:** filed anyway, on request, as #1755 (`Consider supporting hibernation`), with at least these
  steps: size the swapfile to fit (≥ RAM, or check that `systemd-sleep`'s free-swap check
  is enough); test resume on `adora` through LUKS + FIDO2; test resume with an update
  staged; test the sealed UKI path; decide how UPower should behave.
- [x] **6. Archive:** `git mv` this plan into `docs/plans/done/` in the PR that closes #1751.

## Timing

#1750 makes hibernation reachable. A was chosen before #1750 merged, and step 3 was meant
to go into #1750 itself. But the #1750/#1753 stack merged (2026-11-23 20:00 UTC) a few
minutes before the drop-in commit was pushed to its branch. So `main` briefly shipped the
swapfile without the drop-in, and this plan's PR carries the drop-in instead.
