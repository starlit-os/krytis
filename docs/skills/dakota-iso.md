# dakota-iso Reference

Load when referencing the sibling live-media project at `../dakota-iso/` — to compare the
ISO/installer pipeline krytis forked out of it, or to understand a lesson mined from it.
Krytis's own pipeline is documented in [`mise.md`](mise.md) § ISO build task and
[`krytis-live-config.md`](krytis-live-config.md); this file is only about upstream.

## What It Is

`projectbluefin/dakota-iso` builds the live installer media for the Bluefin family —
`dakota`, `bluefin`, `bluefin-lts-hwe`, `lts`, `stable`. A `just` project: `just container
<target>` builds the live-environment image, `just iso-sd-boot <target>` assembles the
squashfs + systemd-boot ESP + hybrid ISO, and a `plain-boot-qemu-live` /
`plain-install-qemu` / `plain-boot-qemu-installed` chain drives a QEMU install gate.

Multi-target by a **file-per-value** convention: `<target>/{payload_ref,live_target,tag,
registry,live_title,live_label}`, one line each, read by the justfile. dakota-iso's
`live/Containerfile` then builds `FROM ghcr.io/${REGISTRY}/${TARGET}:${TAG}` and runs its
`live/src/configure-live.sh`. Krytis's own equivalents — `live/Containerfile` and
`live/src/configure-live-krytis.sh` — share the filenames, so always check which tree a
path in this file belongs to before acting on it.

Krytis's installer ISO was built by this project until #838/#839 ported the whole call
graph in-tree ([#519](https://github.com/starlit-os/krytis/issues/519) has the file-by-file
BOM and the exclusion list). Krytis is single-target, always composefs + systemd-boot, so
every one of those indirections collapsed to a constant on the krytis side.

## Fork State — there is no fork any more

Krytis tracks `projectbluefin/dakota-iso` **directly**, the way `zirconium-hawaii` is
tracked: the local checkout's `origin` is the upstream repo, and no fork sits in the loop
(`upstream-sync.md` § An `origin` pointing at a fork makes the sync lie explains why that
matters). The `kitten-lily/dakota-iso` fork was reset to upstream and then **deleted** in
#841. Do not re-fork it to make a change here; see § Third-party repositories in
`AGENTS.md`.

That fork carried four krytis-specific commits on `main` (`a5780cf`, `ab94dcf5`,
`8ee95564`, `3d32f848`): the krytis variant, the installer rebrand, sealed-payload support
(`PAYLOAD_SEALED`/`PAYLOAD_REF`, `sealed-test-qemu`, `scripts/e2e-lib.sh`) and the
root-free LUKS install chain — **none of which exist upstream**. All of that logic now
lives in krytis's `mise/tasks/iso-*`, `scripts/` and `live/`, so nothing was lost by the
deletion. The pre-demotion git history is archived twice on the dev host, since GitHub no
longer holds it:

| Where | Contents |
|---|---|
| `../dakota-iso` branch `archive/krytis-fork-main` | `3d32f848` — fork `main` before the reset, all four commits |
| `../dakota-iso` branch `archive/krytis-sealed-payload-support` | `89bb5aa6` — pre-merge branch of the sealed-payload work |
| `../dakota-iso` branch `archive/krytis-luks-passphrase-knob` | `a03f98db` — pre-merge branch of the LUKS work |
| `~/Projects/StarlitOS/dakota-iso-krytis-fork-archive.bundle` | all three of the above, `git bundle verify`-clean ("records a complete history") |

The two feature branches are *not* ancestors of `3d32f848` — they were rewritten on merge,
so they are independent history rather than redundant copies. That is why the archive
carries all three refs and not just `main`. Restore with
`git clone dakota-iso-krytis-fork-archive.bundle` or
`git fetch ../dakota-iso-krytis-fork-archive.bundle 'refs/heads/*:refs/heads/*'`.

## Lessons Mined

### The payload mutation exists three times; only one copy is on any given path

*Source: dakota-iso's `scripts/iso-sd-boot.sh:91`, `scripts/build-live-squashfs.sh` and
`live/iso-tools/payload-prep.sh` — all three inject
`/usr/lib/bootc/install/00-defaults.toml`. Every path in this entry is dakota-iso's unless
it says krytis.*

dakota-iso's `scripts/iso-sd-boot.sh` has its own inline `buildah run … 00-defaults.toml`
injection, its `scripts/build-live-squashfs.sh` is a *separate* entry point with a
duplicate of the same logic, and its `live/iso-tools/payload-prep.sh` is a third copy for
hosts with no host-side buildah. A fix
applied to one is invisible to the other two. Before porting or trusting any payload-prep
behaviour from that repo, `grep -rln 00-defaults.toml` there and work out which copy your
entry point actually reaches. Krytis deliberately ported only `payload-prep.sh`, so it has
exactly one *payload* mutator: `live/iso-tools/payload-prep.sh`. There is no
`scripts/build-live-squashfs.sh` in krytis, and krytis's own `scripts/iso-sd-boot.sh` does
not touch `00-defaults.toml`. (`live/src/configure-live-krytis.sh` also writes that path,
but into the *live environment* image, not the payload — different image, not a fourth
copy of this logic.) See [`secure-boot.md`](secure-boot.md) § A sealed ISO payload must be
embedded byte-identically.

### `dakota/src/` was a second copy of `live/src/` — deleted 2026-09, and what actually held it

*Source: dakota-iso `50169c33` — "[architect] refactor: make live/src the single source of
the live ISO tree (#177)". **Historical.** That tree is gone upstream as of 2026-09, so a
commit "in `build-iso.sh`" can now only be `live/src/build-iso.sh`; the old "check the path,
not the filename" caveat is spent. Neither `src/` tree ever existed in krytis, which has
`live/src/build-iso.sh` and `scripts/show-screenshot.sh`.*

The audit that justified the deletion is the part worth keeping. Of the 19 files, **16 had
zero references outside documentation**; of the 8 shared with `live/src/`, **7 had silently
drifted**; and the one that had *not* drifted (`luks-unlock.py`) was the one file with a
machine-enforced byte-identity assertion in the test suite. The two trees were nominally
kept in sync by prose in `docs/build.md`. The prose kept nothing in sync. The assertion kept
exactly what it covered and nothing else.

So a duplicate you cannot delete today is held by a check that fails the build, never by a
paragraph asking contributors to remember. And the five assertions that existed only to
police the duplicate were deleted along with it — a parity check is rent you pay until the
duplicate dies, not a permanent fixture.

### The `95dakota-isofile` dracut module is orphaned upstream — 32 tests did not change that

*Source: dakota-iso's `live/src/dracut/95dakota-isofile/` vs its `live/Containerfile:47,92`;
`53f31cfc` added the tests, and the second copy under `dakota/src/` went with `50169c33`.
Krytis has no dracut module directory at all; its own `live/Containerfile` is a different
file.*

The module defines a complete Ventoy/file-backed boot path with an `inst_hook initqueue`
line, and nothing adds it: both `dracut --add` invocations in that Containerfile pass
`dmsquash-live` only, and no `dracut.conf`/`modules.d` entry references it for any target.
`53f31cfc` then gave it 32 executed test cases **without wiring it in**, and its commit body
says why nothing had ever exercised it: "The QEMU gates boot the ISO as a block device, so
the CDLABEL check on the hook's first line short-circuits it before any of its logic runs."
Tested dead code is still dead code — the suite proves the hook's internals, not that
anything reaches them. It is dead upstream, not a krytis omission, which is why #519
excluded it from the port. Don't read it as the mechanism by which live media finds its ISO.

### `PAYLOAD_SEALED`, `e2e-lib.sh` and the sealed test chain are not upstream concepts

*Source: dakota-iso's `justfile` and `scripts/` — no `sealed-test-qemu` recipe, no
`PAYLOAD_SEALED` handling, no `scripts/e2e-lib.sh` there. Krytis's own
`scripts/e2e-lib.sh` is the fork's copy, kept.*

Upstream's install gate greps the installed system's serial console for
`Reached target Graphical Interface`, which a sealed (signed-UKI) system can never produce —
its cmdline is frozen, so `console=ttyS0` cannot be injected. Anything about sealed payloads,
byte-identical embedding, or the single-owner `EXIT` trap registry came from the krytis fork
and now lives in krytis. Do not expect a fix for those areas to appear upstream, and do not
file one there.

### The `--store` flag in `build-iso.sh` was dead code, ported verbatim and now removed

*Source: dakota-iso `7c9d6c6f` — "fix(live): remove dead superiso-store script and --store
flag from build-iso.sh (#171)".*

`--store`, `STORE_SFS` and the `LiveOS/store.squashfs.img` copy block were uncallable
upstream: the offline OCI store has lived *inside* the live squashfs as a VFS
containers-storage ever since the superiso-store design was abandoned. The header of the
deleted `scripts/build-offline-store.sh` records why — a separate overlay-driver store
squashfs, loop-mounted at `/var/lib/superiso-store` and registered as
`additionalimagestores`, "has an inherent VFS/overlay driver incompatibility with the
primary store" and was never fully wired into CI. So passing `--store` does not add an
offline store; it **double-embeds** the payload and produces an oversized ISO.

**krytis carried the whole thing verbatim** in `live/src/build-iso.sh` until #935: usage
strings at lines 2-3 and 80-82, option documentation at 20-22 and 38 — which named a
`superiso-store.mount` unit that never existed in krytis either, this file being the only
hit for `superiso` outside an archived plan — `STORE_SFS=""` at 48, the `--store)` case arm
at 53, and the copy block at 326-329. Nothing ever passed it: no `mise/tasks/iso-*` call
site and no `scripts/iso-sd-boot.sh` one. Krytis embeds its payload the same VFS way —
`scripts/iso-sd-boot.sh:170-174` writes a `driver = "vfs"` store into
`${CS_STAGING}/var/lib/containers/storage` and copies it to
`${SQUASHFS_ROOT}/var/lib/containers/storage` at 224-226, the branch krytis always takes
because `live/src/krytis/composefs` is `true`, and the live image's own
`/etc/containers/storage.conf` names exactly that path as its `additionalimagestores`
(`live/src/configure-live-krytis.sh:222-230`). Dead here for the same reason it was dead
upstream.

**How it survived the fork:** `docs/plans/done/2026-08-06-hard-fork-dakota-iso.md:358`
explicitly told the port to *keep* `--store`. A port instruction written against a
then-current upstream carries that upstream's dead code forward silently — the plan was
right on the day it was written and wrong three weeks later, and nothing in the port
re-asked whether each flag was reachable. That plan is archived and frozen, so it is not
edited; the instruction is simply superseded.

**The method half of the commit:** upstream found its own docs quoting a "~17 GB with both
offline stores" size estimate *derived* from the phantom line item, plus a component-table
row for it and an ISO layout that was no longer producible. Deleting a feature means
grepping the docs for every claim **derived** from it, not only for its name.

### Digest-pin the third-party images your build and test tasks run

*Source: dakota-iso `6cfe4f28` — "fix(justfile): pin third-party images chunkah and qemu
with sha256 digests (#170)".*

These images run with more privilege than anything else in the pipeline — `--device
/dev/kvm`, `--privileged` or `--security-opt label=disable`, bind-mounted disk images — so a
mutable `:latest` is a supply-chain hole exactly the size of an unpinned GitHub Action.
Upstream pinned `ghcr.io/tuna-os/chunkah` and `ghcr.io/qemus/qemu` to `:<tag>@sha256:…` and
added a test assertion so the pin cannot silently regress.

**krytis is exposed twice**, both `ghcr.io/qemus/qemu:latest`, no tag and no digest:
`mise/tasks/boot-vm:150` (the no-native-qemu fallback — `--rm --privileged --device /dev/kvm
--pull=always`, disk bind-mounted at `/boot.img`) and `mise/tasks/convert-to-qcow2:82`
(`--entrypoint qemu-img` over the built disk). `--pull=always` makes it strictly worse:
every run fetches whatever the tag points at now.

This is an omission, not a policy difference — krytis already does it right for its other
third-party image. `mise/tasks/chunkify:10` pins
`quay.io/coreos/chunkah:v0.6.0@sha256:ff8b8b46…`, `mise/tasks/chunkah-update` bumps it, and
the `track-chunkah` job in `.github/workflows/track-bst-sources.yml` drives that on a
schedule.

**What makes a pin durable:** Renovate cannot see either `qemus/qemu` ref. They live in bash
task scripts rather than a manifest, and `.github/renovate.json5`'s custom regex managers
cover only `mise.toml` + `Containerfile.runner` (`actions/runner`), `mise.toml`
(`protonpass/pass-cli`) and `.github/workflows/*.yml` (`jdx/mise`). A digest with no update
path trades a supply-chain hole for a rot hole: pin *and* add the manager, or the
`<name>-update` task + tracking job that `chunkah` already demonstrates.

### An emulator probe that fails to exec costs you the serial log, not just the binary

*Source: dakota-iso `8ff32cc0`, sub-fix "fix(qemu): select executable emulator for E2E".
krytis's ported copy is `mise/tasks/iso-boot-live:47-50` and
`mise/tasks/iso-boot-installed:47-50`.*

Upstream's probe selected a candidate path that existed but was not executable, so QEMU
exited **126 before creating any serial log**. The harness then greps an empty file and
reports a boot failure — a missing-tool error wearing a boot-hang costume. Upstream replaced
the probe at five sites with an explicit
`for candidate in …; do [[ -x "$candidate" ]] && { QEMU="$candidate"; break; }; done`.

krytis carries the **pre-fix text** verbatim — `QEMU=$(command -v /usr/libexec/qemu-kvm
/usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64
/home/linuxbrew/.linuxbrew/bin/qemu-system-x86_64 2>/dev/null | head -1 || true)`, the
identical four-candidate list, which is what identifies it as the ported copy.

**The defect does not reproduce here, though — check before "fixing" it.** `command -v` on
an *absolute path* already requires the file to exist **and** be executable. Verified
against a mode-644 file, a mode-000 file and a dangling symlink: bash 5.2, `bash --posix`,
bash-as-`sh` and busybox `ash` all print nothing and return 1, the same verdict `[[ -x ]]`
gives. Both krytis tasks are `#!/usr/bin/env bash`, so a non-executable candidate cannot be
selected. POSIX does not *require* that check for a pathname operand, which is the likely
route to upstream's 126, but no shell reachable from this tree behaves that way. The `-x`
loop is even marginally weaker in one corner: `[[ -x /some/dir ]]` is true for a directory
while `command -v` on a directory is false, so the "fixed" form would select it and exec
would fail 126 anyway.

What transfers is the diagnostic shape: **a tool-resolution failure that happens after the
harness has committed to reading a log file is indistinguishable from a boot hang.** krytis's
other QEMU entry points sidestep it by probing a bare name — `boot-test:101`,
`enroll-test:39`, `upgrade-test:48`, `selfenroll-test:43`, `luks-boot-test:48`, `boot-vm:20`,
and the `iso-install-test:77` / `luks-install-test:69` guards — where PATH lookup filters on
the exec bit in every shell.

### `cat f | tr -d … || echo default` loses its default without pipefail

*Source: dakota-iso `ca790870` — "[architect] refactor: single source of truth for host-side
variant config (#146)"; the lesson is one paragraph of the commit body, not the refactor.*

```bash
value=$(cat "$f" 2>/dev/null | tr -d '[:space:]' || echo "$default")
```

reaches `$default` **only when `set -o pipefail` is in scope**. Otherwise the pipeline's exit
status is `tr`'s, which is 0 even when `cat` failed, the `||` never fires, and the caller
gets `""` where it expected `true` / `systemd` / a label — a boot-critical default failing
open as the empty string.

**krytis has five**, all in scope and therefore correct today: `scripts/iso-sd-boot.sh:81`
(`live_target`), `:83` (`composefs`), `:267` (`live_label`), and
`scripts/iso-install-fisherman.sh:48` (`live_target`), `:50` (`bootloader`). Both scripts set
`set -euo pipefail` at the top (`iso-sd-boot.sh:31`, `iso-install-fisherman.sh:18`).

The hazard is that the correctness of those defaults is carried by a `set` line hundreds of
lines away, and this repo **already** crosses shell boundaries where that line does not
survive: `iso-sd-boot.sh` `export -f`s `_ns_build_squashfs` and re-enters it via `podman
unshare bash -c '_ns_build_squashfs'` (259), which is why the function re-asserts `set -euo
pipefail` on its own first line (144); `iso-install-fisherman.sh` builds a `sudo bash -c "…"`
string that re-asserts it too (96). Move any of the five reads into a helper, into that
`podman unshare` sub-invocation or into an `sh -c`, and it fails mute — an empty
`COMPOSEFS_BACKEND` fails the `== "true"` tests at `iso-sd-boot.sh:170,223`, so the payload
is staged as an overlay store at `usr/lib/containers/storage`, which is neither the path nor
the driver the live image's `storage.conf` looks for
(`live/src/configure-live-krytis.sh:222-230`: `driver = "vfs"`,
`additionalimagestores = ["/var/lib/containers/storage"]`).

Note the asymmetry one line up: `LIVE_TITLE=$(cat … || echo 'Krytis Live')`
(`iso-sd-boot.sh:266`) has no pipe and is pipefail-independent — only the whitespace-stripped
reads are fragile. Upstream's fix made the *reader* pipefail-independent rather than trusting
every caller to have set it.

---

Copy patterns from `../dakota-iso/` and adapt — same convention as
[`dakota.md`](dakota.md) and [`zirconium-hawaii.md`](zirconium-hawaii.md): no symlinking, no
junctioning, no `DAKOTA_ISO_DIR`-style runtime dependency. krytis's ISO pipeline is
self-contained by design since #840.
