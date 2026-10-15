# Dakota Reference

Load when referencing the sibling project at `../dakota/` — to compare patterns, borrow elements, or understand lessons learned there that apply to krytis.

## What It Is

Dakota is a BuildStream 2 project producing a bootc OCI desktop image built on Freedesktop SDK + GNOME Build Meta (same foundation as krytis, with GNOME Build Meta as an extra junction). Published as `ghcr.io/projectbluefin/dakota:{testing,stable,next,btw}`.

## Lessons Mined

### `overlap-whitelist` required for base system file replacement

*Source: dakota `2063be5` — `docs(skills): document bst overlap-whitelist requirement`*

When an element provides files that are also provided by an upstream junction component (for example, `/etc/subuid` and `/etc/subgid` provided by `freedesktop-sdk.bst:components/shadow.bst`), BuildStream will throw an overlap error during composition (e.g. in a runtime compose element).

To explicitly overwrite these files, declare an overlap whitelist in the `public` block of the authoring element:

```yaml
public:
  bst:
    overlap-whitelist:
    - '%{sysconfdir}/subuid'
    - '%{sysconfdir}/subgid'
```

*Note: Replacing base system files destroys the base mappings. Whenever possible, prefer injecting changes dynamically via a hook rather than completely replacing junction files.* Krytis already uses this pattern — see `config/plymouth-theme.bst` (three `overlap-whitelist` entries for `plymouthd.conf`, `watermark.png`, `spinner.plymouth`) documented in `desktop.md` § Plymouth Boot Splash.

### bootc `install to-disk` requires explicit xfs root filesystem

*Source: dakota `1a865c6` — `fix(bootc): require xfs root filesystem in install config`*

bootc no longer defaults the root filesystem type when installing to disk. Without `[install.filesystem.root] type = "xfs"` in the bootc install config, bootc exits 1 with "No root filesystem specified," leaving the disk unpartitioned. Any boot-check or `generate-disk` task that calls `bootc install to-disk` will fail at the partition step.

Krytis uses composefs over btrfs (see `bootc-vm.md`), so this may not apply directly to the default boot path — but any loopback/test install that uses a plain xfs root needs this config.

### bootc loop-device boot-check: PARTSCAN + host-side losetup + GPT pre-seed

*Sources: dakota `b8f1286`, `86e3778`, `56a4cf3`, `57dd31b`, `4ca43a6`, `6569694` — the full boot-check fix chain*

A multi-step root cause that took dakota many iterations to resolve. If krytis adds a `bootc install to-disk` loopback boot-check in CI, this is the sequence that works:

1. **`--via-loopback` is a trap.** It creates the loop device inside the container, but partition nodes aren't visible in time → mkfs ENOENT ("Creating rootfs: No such file or directory").
2. **Create the loop device on the host** before the container starts: `fallocate` + `losetup` on the host, pass the real block device path (`$LOOP`) to bootc instead of `--via-loopback`. The host kernel owns the partition nodes, which appear inside the container via `-v /dev:/dev`.
3. **`losetup -P` (PARTSCAN)** so `LO_FLAGS_PARTSCAN` is set — the kernel auto-creates partition nodes via uevents when sfdisk writes the table. Without `-P`, `ioctl(BLKRRPART)` returns `EINVAL` and no `/dev/loop0p3` node appears.
4. **Pre-seed the GPT** partition table (same layout bootc will use) before running the container, then `udevadm settle`. bootc's internal sfdisk then does a synchronous UPDATE of existing nodes rather than an async CREATE from scratch — the node exists when mkfs runs.
5. **`--wipe`** to let bootc overwrite the pre-seeded partition table (otherwise bootc refuses: "Detected existing partitions").
6. **Attach without `-P`, re-attach with `-P` after install.** Re-attaching `-P` on a device with an existing partition table triggers a synchronous kernel scan, reliably materialising `loop0p1/p2/p3` before the next step mounts them.
7. **`--bootloader none` means no BLS entries** — systemd-boot never writes to the ESP, so grepping `loader/entries/*.conf` always fails. Instead scan the ostree `boot.1` tree on the root filesystem: `/ostree/boot.1/default/TREEHASH/N`. Fresh install always has exactly one deployment so `sort | head -1` is deterministic.
8. **`--ipc=host` required** for the loopback install.

### xfsprogs must be a runtime dep of bootc if default fs is xfs

*Source: dakota `ceb1eb1` — `fix(ci): use ext4 for boot-check; add xfsprogs to bootc runtime deps`*

If `bootc install to-disk` defaults to xfs but the image lacks `xfsprogs`, `mkfs.xfs` fails inside the container. The fix is to add `freedesktop-sdk.bst:components/xfsprogs.bst` as a runtime dep of the bootc element. Alternatively, pass `--filesystem ext4` to `bootc install to-disk` in boot-check if the image has ext4 tools but not xfsprogs (filesystem type is irrelevant for a boot-check that only verifies deploy + boot).

### Patch queues on junctions destroy upstream cache reuse

*Source: dakota `dbb9f6d`, `ac100d7`, `1b48630` — `fix(bluefin): remove gnome-build-meta patch queue for 100% cache reuse` + the paired skill docs*

A local `patch_queue` source applied to a junction (`gnome-build-meta.bst`, `freedesktop-sdk.bst`) changes that junction's cryptographic source hash and cache key. BST derives every downstream element's strong cache key from its build-dependencies' keys recursively — so a patch on the junction invalidates the cache key of *everything* the junction provides, not just the patched piece. Dakota carried one small patch (`disable-lorry-mirrors.patch`) on `gnome-build-meta.bst` and it silently forced local compiles of WebKit and other large components instead of pulling from the public `gbm.gnome.org` cache. Removing the patch queue (2026-07-10) immediately restored 1053/1090 cached elements (96% hit rate).

**Dakota no longer follows this (as of 2026-10-14, dakota `45f097b`).** The removal was not
its end state:

- `787bf4d` (2026-09-20) put a `patch_queue` back on `gnome-build-meta.bst`, and it now
  holds three patches, including `0002-dnsmasq-install-under-prefix.patch` (`1a1a7f4`) and
  `0003-initramfs-boot-modules.patch` (`bd5d913`).
- `freedesktop-sdk.bst` carries **two** queues: the `freedesktop-sdk` one that
  `just patch-sync` rewrites from gnome-build-meta, and a dakota-owned `freedesktop-sdk-dakota`
  queue (ghostscript, ffmpeg, libcupsfilters — `adab815`, `2d69f9e`, `02e801c`), kept apart
  so the sync cannot overwrite it.
- dakota's `AGENTS.md:73` now reads "Patch junctions through `patch_queue`; do not edit
  staged junction contents."

Two days *before* the removal, dakota's `724b63a` had restored both queues with the opposite
cache argument: gnome-build-meta 50.2 builds freedesktop-sdk with its own patch set, and
without the same patches "every cache key below platform.bst diverges from gbm.gnome.org"
(commit body). So dakota has recorded both directions: a patch the cache publisher didn't
apply cost reuse, and dropping one the publisher *did* apply cost it too. Neither commit
measures how far a single-element patch reaches. Before relying on "invalidates
everything", compare `bst show --format '%{full-key}'` before and after the patch.

Krytis has no `patch_queue` source on a junction today: each of `elements/freedesktop-sdk.bst` and `elements/gnome-build-meta.bst` has a single `kind: git_repo` source. It does junction both, though, and consumes the gbm one heavily (`elements/stacks/base-system.bst` alone pulls seven `gnome-build-meta.bst:gnomeos-deps/*` elements), so cache reuse is at stake here too. If a junction-level patch is ever needed, the cheap options are still to submit it upstream first or bump the junction ref. If neither works, measure the key change as above rather than citing either dakota position. Element-level overrides (the junction's own `config.overrides:` map in `elements/freedesktop-sdk.bst`, redirecting a `components/*.bst` at a krytis element — `overrides/frei0r.bst`, `core/sudo-rs.bst`) don't change the junction's own source at all.

### Verify nested-junction ref consistency before merging a bump

*Source: dakota `docs/skills/patch-junctions.md` — "found in the wild: testing pinned fdsk 25.08.12 while gbm 50.2-2 expects 25.08.13"*

When a project junctions both `gnome-build-meta.bst` and `freedesktop-sdk.bst` directly, `gnome-build-meta` also pins its own expected `freedesktop-sdk` ref internally. If the project's own `freedesktop-sdk.bst` ref drifts out of sync with what the pinned `gnome-build-meta` commit expects, downstream cache keys diverge from the upstream `gbm.gnome.org` cache and builds silently fall back to local compiles — no error, just cold-cache CI. Before merging any junction ref bump, check the two refs agree:

```bash
curl -fsSL "https://gitlab.gnome.org/GNOME/gnome-build-meta/-/raw/<gbm-sha>/elements/freedesktop-sdk.bst" | grep -m1 ref:
grep -m1 ref: elements/freedesktop-sdk.bst   # must match
```

Krytis DOES junction `gnome-build-meta` today (`elements/gnome-build-meta.bst`, tracking branch `gnome-51`). This check applies now. It was first run on 2026-07-21 against the then-current `gnome-50`/fdsdk-25.08.14 pair and found no drift; the 26.08 bump it flagged as the next thing to re-check landed in #305 (closed). **Re-run on 2026-10-14, it finds drift:** krytis pins `freedesktop-sdk-26.08.2-0-g32c5fea…` while its gbm ref `51.0-10-g1808f094…` expects `freedesktop-sdk-26.08.1-0-gb02b59ff…` (the curl above at that sha). dakota sits on the same gbm ref with 26.08.1, because it derives the pin. Re-run the two-line comparison before merging any future junction bump — `track-core-junctions` (§ Automating the nested-junction ref-consistency check, below) makes the two refs land together but does not make them agree, and this drift is exactly that gap.

### Drop stale `gtk-doc` override — RESOLVED, dropped (2026-08-12, #305)

*Source: zirconium-hawaii `b96b398` / [gnome-build-meta `1d96e6f`](https://gitlab.gnome.org/GNOME/gnome-build-meta/-/commit/1d96e6f43e8f6c0db4441ec2d51c1250c22275e7)*

Krytis's `freedesktop-sdk.bst` used to override `components/gtk-doc.bst` → `gnome-build-meta.bst:sdk/gtk-doc.bst`, mirroring gnome-build-meta's own overrides list. Verdict held on `gnome-50` (2026-07-21: still carried the override) but flipped once krytis moved to gnome-build-meta's `master` for the fdsdk 26.08beta.3 bump — **and the override turned out to be actively harmful, not just redundant**. Keeping it produced a genuine circular dependency: `freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst` → `...` → `components/gtk-doc.bst` (redirected) → `gnome-build-meta.bst:sdk/gtk-doc.bst` → `buildsystems/meson.bst` → `buildsystems/recc-wrapper.bst` → `freedesktop-sdk.bst:components/buildbox.bst` → back to `public-stacks/buildsystem-cmake.bst`. fdsdk's own native `components/gtk-doc.bst` uses fdsdk's own meson buildsystem stack and doesn't route through gnome-build-meta's recc wrapper, so it doesn't cycle. **Lesson: an override that's merely "redundant" upstream can become load-bearing-broken once the override target's own internal wiring changes** — don't just check "does the override still do something", check "does routing through it still resolve cleanly", especially across a junction's own major-version jump.

### GHCR manifest visibility lag + authenticated visibility probes (2026-07-26 .. 2026-07-28)

*Sources: dakota `3bb0825` (verify public GHCR tags before signing), `8f8c7eb` (remove `--creds` from all skopeo inspect visibility checks), `3fd2573` (widen visibility check from 120s to 360s)*

Dakota's publish pipeline pushes an image to GHCR and then immediately probes/signs it. Two distinct GHCR quirks surfaced across three fix commits:

1. **Public GHCR visibility checks must not use runner credentials.** `skopeo inspect --creds "$GH_ACTOR:$GH_TOKEN" docker://ghcr.io/...` can fail for a *public* package even while the same tag is readable unauthenticated. Authenticated probes against a public GHCR package are not equivalent to the public read path — use the unauthenticated probe for visibility checks; keep `--creds` only on `skopeo copy` operations that actually write.
2. **Newly-pushed manifests can take a long time to become visible.** A 12×10s (2 min) polling loop was originally deemed generous; it still failed in production on 2026-07-28 because GHCR propagation exceeded 120s on a large push. Dakota widened the loop to 36×10s (6 min) to absorb the observed lag.

**Krytis exposure:** `.github/workflows/publish.yml` pushes (`mise run push`) and then immediately runs `mise run sign` (cosign sign) followed by a blocking `cosign verify ghcr.io/starlit-os/krytis@${digest}` step, with **no visibility-wait loop** in between. This is the same push-then-immediately-probe shape that bit dakota. Krytis hasn't hit the race yet (image size/timing may differ), but if `cosign verify` starts intermittently failing with a not-found/unknown-manifest error right after a push that otherwise succeeded, this is the known cause — add a `skopeo inspect --no-tags` polling loop (unauthenticated) between push and sign, sized to at least 6 minutes, rather than adding retries to cosign itself.

### `convert-to-qcow2`, ported for interactive VM testing (2026-08-05)

*Source: dakota `Justfile` recipe `convert-to-qcow2`. Ported on request rather than from a mining pass, so no commit range applies.*

krytis had no raw→qcow2 task. It needs one because `elements/dev/qemu.bst` builds qemu with every display backend disabled, so `mise run boot-vm` cannot give an interactive console on a krytis host (see `docs/skills/bootc-vm.md` § `boot-vm` is headless on a krytis host). A qcow2 hands the disk to GNOME Boxes or virt-manager, which are flatpaks carrying their own qemu/SPICE stack and therefore unaffected.

Ported as `mise/tasks/convert-to-qcow2`, keeping dakota's native-`qemu-img`-with-containerised-fallback shape. Four deliberate divergences:

1. **`--disk` / `--output` flags** instead of dakota's hardcoded `${base_dir}/bootable.raw` → `bootable.qcow2`. krytis's disks live wherever the caller puts them (`boot-test` uses `/var/tmp/krytis-boot-test.*/test.raw`), so a fixed pair of paths would be unusable.
2. **Refuses to overwrite without `--force`.** This is the interesting one: dakota's `boot-vm` *prefers* `bootable.qcow2` over `bootable.raw` when both exist, so a stale qcow2 silently shadows a freshly generated raw — dakota has to defend against it with an `rm -f "${base_dir}/bootable.qcow2"` in its generate step. krytis does **not** copy that preference into its `boot-vm`, and the explicit `--output` plus overwrite refusal means the trap cannot form here. Do not add qcow2-preference to krytis's `boot-vm`.
3. **`-p` only on a TTY.** Unconditional `-p` emits one progress line per percent, which is noise in any captured log.
4. **`qemu-img info` filtered with a line-anchored match.** qemu 10 reports a child node with its own indented `disk size:`, so an unanchored `grep`/`sed` prints it twice.

### `/dev/stdin` inline-file-write fails under remote execution

*Source: dakota `5e30bde` — `fix(elements): stop using /dev/stdin for inline file writes`*

Under BuildBarn/BuildBox remote execution the build sandbox chroots into the input root,
which has no `/dev/stdin` — every `install -Dm644 /dev/stdin "target" <<'EOF'` element
fails outright. Full writeup and the fix (`/dev/null` + `cat >`) is in
`docs/skills/bst.md` § Config-only Elements — krytis's own `bst.md` taught the broken
form as canonical until this pass. The 26+ element sites that still used the fragile
single-step form were backported in `4b09c87` ("backport /dev/null+cat fix for inline
file writes"); `grep -rl /dev/stdin elements/` now returns nothing.

### GHA `concurrency:` drops queued runs without `queue: max`

*Source: dakota `0aa3804` — `ci(build): queue runs FIFO with stale-run gate, detach source tracker`*

`cancel-in-progress: false` only protects a run once started — the undocumented default
`queue: single` still silently cancels a *pending* run when a new one enters the same
group. Full writeup and the `queue: max` + stale-check fix is in
`docs/skills/ci-runner.md` § `concurrency:` without `queue: max`. Krytis's
`publish.yml`/`cache-warm.yml`/`verify-sealed.yml` all have the same exposure today.

### YAML plain-scalar backslash continuation doesn't shell-continue

*Source: dakota `b32e6fe` — `fix(audio): unfold pcsp install command; YAML folding emptied artifact`*

A multi-line `install-commands` entry written as a bare scalar with a trailing `\` does
not concatenate like a shell line continuation — the literal backslash survives, silently
breaking the command with no build error. Full writeup in `docs/skills/bst.md` §
Multi-line YAML Plain Scalars Do Not Shell-Continue. Always use `- |` block literals for
multi-line commands.

### PC-speaker can silently become the default WirePlumber sink after resume

*Source: dakota `a5e9152` — `fix(audio): disable PC-speaker WirePlumber sink`*

Real hardware behavior, not bluefin-specific — krytis ships the same wireplumber+pipewire
stack. Full writeup and the fix config in `docs/skills/desktop.md` § WirePlumber:
PC-speaker can silently become the default audio sink after resume. Not yet ported as a
krytis element (documented, not applied) — port if the glitch is actually observed.

### Verify udev `GROUP=` references exist before shipping a rule

*Source: dakota `02bb985` — `fix(image): create plugdev and nintendo_switch groups for udev rules`*

A udev rule's `GROUP="foo"` for a nonexistent group silently falls back to `root:root`
ownership — no error anywhere. Full writeup in `docs/skills/desktop.md` (appended to the
Kernel Tuning / `config/desktop-udev.bst` section). Krytis's current udev rules only
reference groups fdsdk already creates, so this is a checklist item for future additions,
not a live break.

### Automating the nested-junction ref-consistency check (follow-up to the entry above)

*Sources: dakota `57a70d3` — `ci(next): derive fdsdk pin and patches from tracked gnome-build-meta`; `5005f85` — `feat: GNOME 51 and freedesktop-sdk 26.08 on testing (#1579)` (the `track-bst-sources.yml` hunk)*

The "Verify nested-junction ref consistency before merging a bump" entry above records a
*manual* check (hand-run `curl` comparing krytis's `freedesktop-sdk.bst` ref against what
the pinned `gnome-build-meta` commit expects). Dakota automated the equivalent check into
CI: track `gnome-build-meta` via its own `track:` branch, extract the pinned commit's sha,
fetch that commit's own `elements/freedesktop-sdk.bst` from the GitLab API, and rewrite the
local `freedesktop-sdk.bst` ref to match — failing loudly if the pin can't be resolved,
rather than silently drifting. Krytis went half-way (`8533568`): `track-bst-sources.yml`
now has a `track-core-junctions` job that runs `bst source track` on
`gnome-build-meta.bst` and `freedesktop-sdk.bst` in the same step and commits both refs
in one `auto/track-core-junctions` PR, so the two can no longer land separately — but
it tracks fdsdk independently rather than deriving it
(`.github/workflows/track-bst-sources.yml:1177-1178` is two back-to-back
`bst source track` calls, one per junction, and `elements/freedesktop-sdk.bst` still carries
`track: freedesktop-sdk-26.08*`), so fdsdk can still race ahead of what gbm expects
*within* one atomic bump — which is the drift the entry above found on 2026-10-14.

`5005f85` is the mechanism that closes that. Dakota's `track-core-junctions` tracks
`gnome-build-meta.bst` **only** and derives the fdsdk pin from whatever that track
resolved. Since `196e0ab`/`71b9fb7` (2026-10) the logic lives in dakota's
`update_sources.py` `update_core()`, called as `just update-sources --group core-junctions`
from both its `track-bst-sources.yml` and `track-next-junctions.yml`. It replaced the
workflow-inline `awk`/`BASH_REMATCH`/`sed -i` with Python regexes; the steps are unchanged
(as of 2026-10-14, dakota `45f097b`):

1. Read back the tracked git-describe `ref:` from `elements/gnome-build-meta.bst`; its
   `-g<40-hex>` suffix is the resolved GBM commit.
2. Fetch *that commit's own* `elements/freedesktop-sdk.bst` from the GitLab files API —
   `https://gitlab.gnome.org/api/v4/projects/GNOME%2Fgnome-build-meta/repository/files/elements%2Ffreedesktop-sdk.bst/raw?ref=<sha>`
   — and take the `ref:` of the `url: gitlab:freedesktop-sdk/…` source. Pinning the API
   read to the sha, not to a branch, is the whole point: a branch read reintroduces the
   race.
3. Rewrite the first `ref:` in the local `elements/freedesktop-sdk.bst` to match, then run
   `just patch-sync` and `just patch-drift-check`.

Any extraction that comes back empty raises (`ValueError`), never a skip — a silent no-op
here leaves exactly the drift the job exists to prevent, and looks like a clean run. One
detail worth copying on its own: the commit step `git add`s first and then tests
`git diff --cached --quiet` (dakota `track-bst-sources.yml:218-220`), because a derived
sync can *remove* files (dakota also syncs its `freedesktop-sdk` patch directory) and a
worktree-only `git diff --quiet` reports "no changes" for a pure deletion. Krytis's gate is
the worktree-only form (`.github/workflows/track-bst-sources.yml:1184`); harmless while the
job only rewrites two `ref:` lines, wrong the moment it starts syncing a directory.

### Documentation discipline: "Docs Are the Model" and "Scoped Documentation"

*Source: dakota `691a377` — `docs(agents): add Docs-Are-the-Model and Scoped-Documentation invariants`*

Two documentation discipline invariants added to dakota's AGENTS.md that complement krytis's skill-improvement mandate (which focuses on writing lessons but is silent on these failure modes):

**Docs Are the Model:** Never append dated session logs, issue numbers, or resolved checklists to skill files. Codify findings as timeless invariants. A skill file entry that records "we tried X on 2026-08-17 and it didn't work" belongs in the commit message or the linked issue — the skill file entry is what a future agent should carry into the next session, not a historical log.

**Scoped Documentation:** When work reveals a guidance error, correct it — but don't manufacture doc changes for every session, and don't expand a read-only task into writes. The discipline is "update the skill file when you discover something worth capturing", not "touch the skill file on every session regardless."

Dakota also added a PR checklist item from this commit: *"Existing guidance affected by the change is corrected; no unrelated documentation writeback is required."* Krytis's own checklist (§ Self-diagnosis) focuses on the write-back case; this is the symmetric guard against spurious writeback.

### Staging order, not the whitelist, picks the overlap winner

*Source: dakota `42af692` — `fix(image): vendor libvirt and make shadowed packages actually ship (#1651)`*

An `overlap-whitelist` only *permits* an overlap — it does not decide who wins. The file
that survives a compose is the one written by whichever element stages **last**, and
staging follows dependency order. So an element that deliberately shadows a junction file
wins only incidentally unless it takes a runtime `depends:` on the element that owns the
stock copy. Dakota's uutils-coreutils had a complete, correct whitelist and still stopped
shipping its `/usr/bin/*` symlinks when fdsdk 26.08 moved GNU coreutils out of
`public-stacks/runtime-minimal.bst`: coreutils began staging *after* uutils and the
whitelist obligingly let it overwrite. No error at any point — the whitelist is what
guarantees silence.

The fix is one `depends:` line per shadowing element, with the reasoning in-comment:
`uutils-coreutils.bst` → `bootstrap/coreutils.bst`, `sudo-rs.bst` → `vm/config/sudo.bst`,
`common.bst` → `components/containers-common.bst`, each annotated *"a compose keeps
whichever element stages last, so depend on it to stage first and let X win"*. The
`depends:` is what makes the order explicit instead of an accident of how the junction
arranges its stacks — which is precisely what changed under dakota.

`docs/skills/bst.md` § `overlap-whitelist` permits an overlap; staging order picks the
winner carries the rule itself and krytis's live exposure (`elements/config/u2f-config.bst`
whitelists the two PAM files but nothing in the runtime graph orders it after the element
installing the stock ones). Don't restate it here.

### Pinning an element *ahead* of its newest release tag needs `track:` on the branch

*Source: dakota `e835b88` — `feat: NVIDIA 615.71.09 and freedesktop-sdk 26.08.1 on testing (#1588)` (the `dash-to-dock.bst` hunk)*

When the fix you need has landed on upstream master but is unreleased, bumping `ref:`
alone does not hold. A `track: <glob>` still matches only tags, so the next nightly
`bst source track` resolves the newest *tag* and rolls the ref **backwards** — undoing the
pin inside an ordinary-looking automated tracking commit, with the element reverting to
the bug you just fixed. `exclude:` does not help: the tag is not bad, it is merely older
than the commit you need, and excluding it just promotes the tag before it.

The fix is to move `track:` onto the branch for the duration, with the exit condition
written into the element so it is not a permanent float:

```yaml
  # ... but unreleased; restore `track: extensions.gnome.org-v*` once a tag
  # lists "51" in metadata.json, so the tracker stops rolling back to v106.
  track: master
```

Without that written condition the element silently stays on a moving branch forever,
which is the opposite failure. The adjacent case — a *bad* tag rather than an old one,
fixed with `ref:` downgrade plus `exclude:` — is `docs/skills/bst.md` § `git_repo`
tracking: excluding a bad tag, and patching ahead of a vendored ref; neither that entry
nor the glob-breadth one covers pinning forward of the tag stream. Krytis drives a nightly
track matrix over ~32 `git_repo` elements with a globbed `track:`, so this is reachable
the first time any of them needs an unreleased upstream fix.

### Take artifact identity from a receipt the producer wrote, never re-derive it

*Source: dakota `fa13c5b` — `fix(ci): smoke-test the image Publish built, not the default-branch tip (#1605)`*

`github.event.workflow_run.head_sha` is not the commit that was built once the chain is
more than one hop deep. For a `workflow_run`-triggered producer, *its own* head is the
default-branch tip at trigger time rather than the commit it built — so a consumer hanging
off that producer inherits the tip. The two coincide whenever nothing landed in between,
which is why this passes every quiet-repo test and only misfires under load.

The rule that outlives the `head_sha` specifics: **a downstream workflow must take
artifact identity from a receipt the producer wrote, never re-derive it from event context
and never re-resolve a mutable tag.** Dakota's consumer — its `publish-smoke.yml` — downloaded
the producer's `digest-default` artifact, validated its `.sha` against `^[0-9a-f]{40}$`,
failed loudly when it was absent instead of falling back to the event sha, and emitted a
`::notice::` when receipt and event sha disagreed — so the divergence was visible rather
than assumed away. dakota deleted that workflow in `474fd09` (2026-09-26, a libvirt PR
whose body gives no reason), so as of 2026-10-14 the lesson has no live example upstream;
the rule stands on its own.

**Krytis exposure.** `.github/workflows/verify-sealed.yml:22-24` triggers on
`workflow_run` off `"Publish krytis image"`, and then at `:71`/`:74` runs
`podman pull ghcr.io/starlit-os/krytis:sealed` and hands the same **mutable tag** to
`mise run enroll-test` — re-resolved at pull time, with nothing tying it to the run that
triggered it. The producer already computes the receipt: `publish.yml:351-353` pushes the
sealed image via `mise run push --sealed --digest-file krytis-sealed-digests.env`, and
`publish.yml:362` feeds that same file to `mise run sign`, with the verify step resolving
`ghcr.io/starlit-os/krytis@${image_digest}` from it. It is just never uploaded (`publish.yml`
has no `upload-artifact` step at all), so the consumer cannot read it. Two publishes in
quick succession and `verify-sealed` gates on an image the triggering run did not produce
— and reports green against that run. The narrower multi-hop `head_sha` trap does not bite
today, because `publish.yml` is triggered by its own weekday `schedule:` cron plus
`workflow_dispatch` (`publish.yml:4-27`), never by `workflow_run`, so `verify-sealed` is a
first hop; the mutable-tag half is live now.

### `ln -s` into an existing directory nests the link; a `make-args` override drops `PREFIX`

*Source: dakota `1a1a7f4` — `fix(image): make /usr/local a real link to /var/usrlocal (#1661)`*

dakota's `oci/layers/bluefin-stack.bst` ran `ln -s ../../var/usrlocal usr/local` while
`/usr/local` already existed as a directory. `ln` then puts the link *inside* the
destination, so `/usr/local` shipped read-only, with a stray `usrlocal` link in it
(projectbluefin/dakota#1591). The directory existed because gnome-build-meta's
`core-deps/dnsmasq.bst` sets `make-args: BINDIR=%{sbindir}`, which replaces the make
plugin's default `PREFIX="%{prefix}"`; dnsmasq's Makefile then fell back to `/usr/local`
for its man page. dakota's fix removes every link path in the same `rm` as `/var` and
creates the links with `ln -sT`, so a leftover directory fails the build instead of
nesting. It also carries a gnome-build-meta patch that passes `PREFIX` to dnsmasq.

krytis's `elements/oci/krytis/stack.bst` had the same shape until #1246. It removed only
`/root /home /opt /mnt /var` and then linked `/ostree`, `/srv` and `/usr/local` with plain
`ln -s`. It now removes every link path first and uses `ln -sT`. Full writeup in
`docs/skills/bst.md` § Rootfs symlinks: remove the path first, then `ln -sT`.

### `%{max-jobs}` written into a command is part of the cache key

*Sources: dakota `b0c2874` — `feat(bluefin): add user-configured IBus Rime with Lua support (#1662)`
(added `boost.bst`); fixed in the boost hunk of `1a1a7f4` (projectbluefin/dakota#1661)*

`boost.bst` built with `./b2 -j%{max-jobs}`. BuildStream expands the variable into the
command text, and command text is keyed. dakota builds with `max-jobs: 8` and exports with
`max-jobs: 1`, so boost and every element above it, up to the final images, got two
different keys. The publish then looked for artifacts that were never built
(`No artifacts to stage`; projectbluefin/dakota#1661 body). The fix routes the value
through `environment: MAXJOBS: "%{max-jobs}"` plus `environment-nocache: [MAXJOBS]` and
runs `-j"${MAXJOBS}"`. The same PR reports identical final-image keys at `max-jobs` 1 and
8 afterwards.

No krytis element inlines it today: `grep -rn max-jobs elements/` hits only
`overrides/libdecor.bst`'s nocache `LTOJOBS` and a comment in `dev/qemu.bst`. Full writeups
in `docs/skills/bst.md` § Job Parallelism in `kind: manual` (how to pass a job count) and
`docs/skills/ci-runner.md` § `max-jobs` does NOT affect cache keys (the inline-expansion
exception to that rule).

### Content an element installs under `/var` never ships

*Source: dakota `45f097b` — `fix(libvirt): create secrets directory at boot (#1777)`*

dakota's stack wipes `/var`, so the `/var/lib/libvirt/secrets` (0700) that libvirt's meson
install creates was never in the image. `virt-secret-init-encryption.service` writes its
key there before `virtsecretd` would create the directory, so it failed. The fix is a
tmpfiles.d line, `d %{localstatedir}/lib/libvirt/secrets 0700 root root -`. krytis's
`elements/oci/krytis/stack.bst:23` runs the same `rm … /var`. Full writeup in
`docs/skills/bst.md` § Content installed under `/var` never ships.

### A green track job does not prove the element's patches still apply

*Sources: dakota `196e0ab` (projectbluefin/dakota#1734), reverted the same day by `3cb22d8`
(projectbluefin/dakota#1739); re-landed as `71b9fb7` —
`feat(deps): restore source updates with patch checks (#1740)`*

`bst source track` re-resolves the `git_repo` ref only; the `kind: patch` /
`patch_queue` sources after it are not applied. projectbluefin/dakota#1734 landed a source
updater together with the bumps it produced. The OGC kernel bump among them tracked
cleanly, but its downstream patches no longer applied, so the whole PR was reverted
(projectbluefin/dakota#1740 body: "failed to apply outdated downstream patches"). The
re-land runs `bst source fetch --deps none <element>` inside a rollback guard right after
tracking, so a patch failure restores the element and the bump is never recorded. As of
2026-10-14 (dakota `45f097b`) its `update_sources.py` does that fetch only for its kernel
elements. Full writeup and krytis's exposure in `docs/skills/bst.md` § A green track job does not prove patches apply.

### One bundled tracking PR, re-pushed only when its tracked paths change

*Source: dakota `a3a32d8` —
`ci(track): bundle source bumps into one PR to cut build queue (#1722)`*

dakota moved every non-junction bump into a single `auto/track-bundle` PR because its
image builds serialize globally: each per-element PR cost a full PR build plus the build
its merge triggers (projectbluefin/dakota#1722 body). Its `track_bundle.py` `bundle_changed()` skips the push
when the paths the bundle touches are unchanged, so a branch that only sits on an older
base is not rebuilt; the PR body is still refreshed. krytis does not bundle: its PR builds
are changed-element only, and a bundle would have to cool as one unit, so every member's
newer release would wait for the whole bundle to merge. The skip-the-no-op-push half was
adopted on 2026-10-15, together with hourly tracking runs. krytis compares the cooldown
trailers as well as the files, and also skips PR edits that would change only the run
link. Full writeup in
`docs/skills/bst.md` § Tracking cooldown: 24h per update.

## Referencing This Project

Copy patterns from `../dakota/` and adapt — don't symlink or junction into dakota from krytis. Independent BST artifact caches and element trees, same as the `zirconium-hawaii.md` convention.
