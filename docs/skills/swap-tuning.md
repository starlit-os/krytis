# Swap: zswap in front of a swapfile

Krytis swaps through **zswap** in front of a **disk swapfile** at `/var/swap/swapfile`,
half of RAM. There is no zram. `elements/config/swap.bst` ships all of it, and
`mise run swap-audit` (the last gate of `mise run build`) checks it in every built image.

| Piece | Where | What it does |
|---|---|---|
| zswap | `files/swap/50-zswap.toml` → `/usr/lib/bootc/kargs.d/` | `zswap.enabled=1 compressor=zstd max_pool_percent=20 shrinker_enabled=1` |
| sysctls | `files/swap/60-krytis-swap.conf` → `/usr/lib/sysctl.d/` | `vm.swappiness = 100`, `vm.page-cluster = 0` |
| swapfile creation | `krytis-swapfile-init.service` → `/usr/libexec/krytis-swapfile-init` | first boot: own btrfs subvolume `/var/swap`, `btrfs filesystem mkswapfile` at MemTotal / 2 |
| swapfile activation | `var-swap-swapfile.swap`, linked from `swap.target.wants/` | `swapon` at boot |
| live check | `mise run boot-test` | zswap `Y`, swapfile active, no `/dev/zram*` in `/proc/swaps`, sysctls |

## The decision (#510, 2026-11-22)

The data is in #510:
[step-1 checkpoint](https://github.com/starlit-os/krytis/issues/510#issuecomment-7082952294),
[decision](https://github.com/starlit-os/krytis/issues/510#issuecomment-7083038858). The
plan and its fixed decision rules are in `docs/plans/2026-10-13-zram-vs-zswap-evaluation.md`.

- **What shipped before:** zram0 (`ram / 2`, zstd) from zram-generator, with the kernel's
  default-on zswap stacked in front of it, and no disk swap.
- **What broke it:** on 2026-11-21 `melog` (31 GiB RAM) used all 15.6 GiB of swap for about
  5.5 hours under real work: several 8 GiB QEMU VMs (`boot-test`, `bluefin-pilot`), Steam
  and a `zig` build. The kernel OOM killer then fired three times. zram's cap is fixed, and
  nothing sat behind it.
- **Why not zram alone:** it has the same fixed cap (rule 2: zram was ≥ 80 % full in 168
  samples).
- **Why `zswap` over `hybrid`** (zram first, then a swapfile at lower priority): steps 2
  and 3 of the plan were skipped by the maintainer's call, so the plan's simplicity
  tie-break decided (`zram` < `zswap` < `hybrid`). Two reasons beyond that:
  - When a full zram spills, the *newest* evicted pages go to disk, while the cold ones
    stay in zram. zswap's shrinker writes back its oldest pages first.
  - zswap is one mechanism to set and check. `hybrid` needs three: zram, the swapfile,
    and a udev rule turning zswap off.
- **`adora`** (laptop, 31 GiB RAM) peaked at 24 % of RAM with no OOM kills. Nothing in its
  data argued for a different arm.

**Open: disk wear (plan rule 4) was not measured before shipping.** On `melog`'s worst day,
zswap wrote back about 1.77 GiB/h, which went into zram at the time and now goes to the
NVMe. Plan step 7 samples the zswap image for at least 5 working days. If either machine
exceeds 10 GiB/day of swap-out, the fallback is `hybrid`: restore zram-generator and add
the zswap-off rule from CachyOS's `30-zram.rules`, keeping this swapfile at a lower
priority.

## zswap stacked on zram

zswap is a cache in front of whatever swap device exists. With zram as that device, every
evicted page is compressed into zswap's pool. When the pool fills or its shrinker runs, the
page is decompressed and written to zram, which compresses it again. That is double the CPU
for no extra capacity. The ArchWiki zram page tells users to disable zswap when using zram,
and CachyOS's `30-zram.rules` does exactly that when zram0 appears.

Krytis ran this way for months without any commit choosing it:

- zswap was on because the CachyOS kernel has `CONFIG_ZSWAP_DEFAULT_ON=y`.
- zram came from gnome-build-meta's zram-generator element.
- `config/desktop-udev.bst` ported CachyOS-Settings but left out `30-zram.rules`, claiming
  it "conflicts with zram-generator". That was wrong: the rule was the fix.

dakota did the same thing from the other direction. Its #1131 meant to replace zram with
zswap, but the empty `zram-generator.conf` lost a BuildStream staging race to
gnome-build-meta's, and dakota images then ran both (fixed in dakota `53952c7`, #1262).

**So never leave swap to a default.** Set zswap by karg, pin the sysctls the decision
depends on, and keep `swap-audit` failing if a junction bump brings zram-generator back
(`gnome-build-meta.bst:freedesktop-sdk-extra.bst:components/zram-generator.bst` still
exists upstream; krytis just doesn't list it).

## The kernel compiles in the swap sysctls

`vm.swappiness = 100` and `vm.page-cluster = 0` were never set by any file in the image.
The CachyOS kernel compiles them in (checked against the `cachyos-7.2.9-2` source tree):

- `vm_swappiness = 100` sits under `#ifdef CONFIG_CACHY` in `mm/vmscan.c`. Mainline uses 60.
- `page_cluster = 0` is set unconditionally in `swap_setup()` in `mm/swap.c`. Mainline uses 3.
- MGLRU's `min_ttl_ms = 100` also sits under `CONFIG_CACHY`. When the working set of the
  last 100 ms doesn't fit in memory, it invokes the OOM killer.

`core/linux-cachyos.bst` repackages whatever CachyOS builds, so a kernel bump can change any
of these without a krytis commit. `60-krytis-swap.conf` pins the first two, at the values
#510 measured. `min_ttl_ms` is not pinned. `swap-audit` fails if any other sysctl.d file
sets the two pinned keys.

## Swapfile on btrfs: what `krytis-swapfile-init` has to get right

- **It needs its own subvolume.** btrfs refuses to snapshot a subvolume that holds an active
  swapfile, so `/var/swap` is created with `btrfs subvolume create`, not `mkdir`.
- **Use `btrfs filesystem mkswapfile`** (btrfs-progs ≥ 6.1; the image ships 7.1). It sets
  NOCOW on the empty file and allocates real extents. A plain `fallocate`'d file fails
  `swapon`, and NOCOW also keeps the root's `compress=zstd:1` (#1719) off the file. xfs and
  ext4 take the `dd` + `mkswap` fallback; xfs rejects unwritten extents ("swapfile has
  holes").
- **`DefaultDependencies=no`** on the init service. With default dependencies it gets
  `After=sysinit.target`, while `swap.target`, which pulls it in through the `.swap` unit,
  completes *before* `sysinit.target`. systemd breaks that cycle by dropping the swap unit
  (dakota `53952c7`).
- **Enable it with a static `swap.target.wants` symlink, not a preset.** Presets apply only
  on first boot (an empty machine-id), so machines already installed would never get the
  swapfile.
- **Nothing under `/var` in the image.** bootc lints against it, so the subvolume and file
  are created at runtime.
- **Free space comes from `stat -f`, not `df`.** uutils `df` rejects `-P` together with
  `--output`. The script skips (exit 0) with less than size + 4 GiB free, and on
  filesystems that can't hold a swapfile (overlayfs under `podman run`, virtiofs). Without
  the swapfile the machine has no swap device at all, and zswap, which only caches pages
  on their way to one, does nothing.

A machine that ran `mise run swap-eval arm zswap` or `hybrid` already has `/var/swap` and
`/var/swap/swapfile` from the evaluation. The init script sees the file and leaves it alone.
The evaluation created it at the same path and the same default size.

## A swapfile can make hibernation reachable (#1751)

zram doesn't count as a hibernation target. On the zram image, logind returned `na` for
`CanHibernate`, `CanHybridSleep` and `CanSuspendThenHibernate` (`melog`, 2026-11-22). A
disk swapfile can change that. UPower ships `CriticalPowerAction=Auto`, and its own
comment in `/etc/UPower/UPower.conf` gives the order: HybridSleep, then Hibernate, then
PowerOff. So a laptop at critical battery would hibernate instead of powering off as
soon as logind offers it. Nothing on krytis has tested resume: through LUKS + FIDO2,
after `bootc` staged an update, or from the sealed UKI. Whether to turn hibernation off
with a `sleep.conf.d` drop-in is #1751
(`docs/plans/2026-11-22-hibernation-decision.md`).

## Testing it

- `mise run swap-audit` reads the files in the image. It runs `krytis-swapfile-init`
  inside the container, where overlayfs makes it skip, and checks that it exits 0.
- `mise run boot-test` checks the live result. Its swap line prints `init_log=`, the init
  service's last journal line, so a skip says why.
- **The test disk has to hold the swapfile.** The script needs RAM/2 + 4 GiB free on
  `/var`, which is 8 GiB for `boot-test`'s 8 GiB guest. On the old 15G test disk, the
  6.6 GiB payload left about 7.4 GiB, so the script skipped correctly and the check
  failed on the disk, not the image (2026-11-22). `boot-test` now creates a 24G sparse
  disk. A real install on a disk that small gets no swapfile either, and the init
  service's journal line says so.

## Measuring: `mise run swap-eval`

`swap-eval` (`snapshot`, `sample`, `summary`, `arm`, `pressure`) still works. On the zswap
image, its sample rows report the arm as **`zswap`**. `shipped` in older logs means the
pre-#510 stack (zswap on zram). Install the sampler once per machine with
`mise run swap-eval-sampler:install`, and every login samples on its own
([`mise.md`](mise.md) § A task that installs a user unit runs a copy, not the checkout).

**Count OOM kills across boots with `_TRANSPORT=kernel`, not `-k`.** `journalctl -k` implies
`-b` and reads only the current boot. The first step-1 checkpoint reported "0 kernel OOM
kills" from `journalctl -k --since 2026-10-13` while the previous boot held three. Use
`journalctl _TRANSPORT=kernel --since <date> -g 'invoked oom-killer'`. `swap-eval
snapshot`'s counter used `-k` too, until #510's decision PR fixed it.
