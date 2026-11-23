# Decide hibernation with a swapfile

**Issue:** #1751 · **Status (2026-11-22): planned; the step 2 decision is needed.**
Follows #510's decision, which ships a disk swapfile in #1750.

## Why this exists

Until #1750, krytis's only swap was zram, which logind doesn't count as a hibernation
target. On `melog` (zram image, systemd 262.2, 2026-11-22), `CanHibernate`, `CanHybridSleep`
and `CanSuspendThenHibernate` all return `na`. #1750 adds `/var/swap/swapfile` (MemTotal / 2)
on every machine, and nothing in the image has decided whether hibernation is supported.
What that exposes:

| Path into hibernation | State on the image |
|---|---|
| UPower at critical battery | `CriticalPowerAction=Auto` (`/etc/UPower/UPower.conf`). Its own comment gives the order: HybridSleep if available, then Hibernate, then PowerOff. Today it powers off. |
| `systemctl hibernate`, apps asking logind | Allowed whenever logind reports `yes` |
| Lid, idle, shell buttons | None. Lid is `suspend` (`config/logind-lid.bst`), and noctalia and noctalia-greeter have no hibernate action (`grep -rIi hibernat`, 2026-11-22) |
| Resume | The initrd has `systemd-hibernate-resume` and its generator (`lsinitrd`). No `resume=` karg; systemd would rely on the `HibernateLocation` EFI variable |

None of these has been tested on krytis: resuming through the LUKS + FIDO2/TPM unlock
(`adora`), resuming after `bootc` staged an update, resuming from the sealed UKI, or
hibernating with more memory in use than the swapfile holds.

## Options

- **A. Turn it off explicitly (recommended).** Add a `sleep.conf.d` drop-in with
  `AllowHibernation=no`, `AllowHybridSleep=no` and `AllowSuspendThenHibernate=no`. logind
  then reports `no`, and UPower's `Auto` falls back to PowerOff, which is what machines
  do today. Size: S.
- **B. Support it.** Every untested path above would need a hardware test. The swapfile
  probably needs to be at least the size of RAM. It is a separate project with its own
  issue, and this plan only outlines it (step 5).

## Steps

- [ ] **1. Measure on the #1750 image** (VM first, then `adora` after its upgrade):
  - `busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate`,
    and the same for `CanHybridSleep` and `CanSuspendThenHibernate`.
  - `busctl call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower GetCriticalAction`
    shows the action UPower would take right now.
  - Note `/sys/power/disk` and `/sys/kernel/security/lockdown`. The kernel refuses to
    hibernate under lockdown; both machines showed `[none]` on 2026-11-22.
  - Post the results to #1751. If logind still says `na`, A changes nothing visible. Do
    it anyway, so a later swap change can't turn hibernation on silently.
- [ ] **2. Decide A or B** on #1751 (Design Gate: power behaviour is user-visible).
- [ ] **3. Implement A**, in the same element as the swapfile, since the swapfile is what
  exposes it:
  - `files/swap/50-krytis-no-hibernate.conf`, installed by `config/swap.bst` into
    `%{indep-libdir}/systemd/sleep.conf.d/`, containing `[Sleep]` with the three `Allow*=no`
    lines. The header explains why, links #1751, and says how a user opts back in: a
    later-sorting drop-in under `/etc/systemd/sleep.conf.d/`.
  - `mise run swap-audit`: assert the drop-in sets all three keys, and that no other
    `sleep.conf.d` file under `/usr` overrides them.
  - `mise run boot-test`: assert logind reports `no` for all three methods, and that
    UPower's `GetCriticalAction` is `PowerOff`. Only check when the image ships the drop-in,
    so `--reuse-disk` of an older disk still passes.
  - `docs/skills/swap-tuning.md`: a section on why the swapfile doesn't mean hibernation,
    and the UPower fallback order.
  - `files/fakecap-manifest.tsv`: one row for the new file.
- [ ] **4. Verify:** `mise run build`, `mise run boot-test`. Then on `adora` after it
  upgrades, run step 1's commands again and expect `no` / `PowerOff`.
- [ ] **5. If B instead:** file `Support hibernation` (effort L), with at least these
  steps: size the swapfile to fit (≥ RAM, or check that `systemd-sleep`'s free-swap check
  is enough); test resume on `adora` through LUKS + FIDO2; test resume with an update
  staged; test the sealed UKI path; decide how UPower should behave. Close #1751 when that
  issue is filed.
- [ ] **6. Archive:** `git mv` this plan into `docs/plans/done/` in the PR that closes #1751.

## Timing

#1750 makes hibernation reachable. If A is chosen before #1750 merges, step 3 can go into
#1750 itself. Otherwise land it right after, before both machines upgrade. Until then,
`adora` at critical battery may hibernate instead of powering off.
