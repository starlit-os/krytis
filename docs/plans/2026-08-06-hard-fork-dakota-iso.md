# Krytis ISO Pipeline Hard Fork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Absorb everything krytis's installer-ISO build and boot-test pipeline needs out of the sibling `dakota-iso` checkout into krytis itself, as native `mise` tasks, so krytis no longer depends on `DAKOTA_ISO_DIR` at all. `dakota-iso` is then eligible for demotion to a pure fast-forward mirror (Phase 3, gated on explicit approval — a destructive rewrite of your own fork's history).

**Architecture:** Two independently-testable subsystems, ported in sequence:
1. **Build path** — `mise/tasks/build-iso` currently shells out to `just --justfile "${DAKOTA_ISO_DIR}/justfile" iso-sd-boot krytis`. This plan replaces that one `just` invocation with native bash performing the same work: build the live-environment container image, assemble the squashfs + boot files, and author the ISO with xorriso.
2. **Test path** — `mise/tasks/{iso-install-test,luks-install-test}` currently shell out to `just sealed-test-qemu krytis`. This plan replaces that with a native `iso-e2e-test` mise task orchestrating four new native tasks (`iso-boot-live`, `iso-run-install`, `iso-boot-installed`, `iso-verify-boot`), each a direct port of the corresponding `just` recipe.

Since krytis is (and will remain) the *only* target this pipeline ever builds, every piece of dakota-iso's multi-target indirection (`{target}/live_target`, `{target}/tag`, `{target}/registry`, the `configure-live-${TARGET}.sh` dispatch, the `live/src/${BOOTLOADER_VARIANT}/{composefs,bootloader}` lookup) collapses to plain constants in the ported code — this is a deliberate simplification from dakota-iso's general multi-consumer design, not a faithfulness gap. Every port task below states exactly which indirection it collapses and to what constant.

**Tech Stack:** bash (`mise` tasks use the `#MISE`/`#USAGE` task-definition convention already established in `mise/tasks/build-iso`/`generate-ovmf-vars`), podman/buildah, xorriso, mtools, QEMU/OVMF.

## Global Constraints

- Every ported `just` recipe becomes a native `mise` task — per `AGENTS.md`: "All maintenance tasks must be mise tasks. No loose shell commands."
- Krytis is single-target and always composefs + systemd-boot. Drop every dakota-iso branch that exists only to serve other targets, other bootloaders, or non-sealed/non-composefs paths — this exclusion list is already finalized in issue #519 and restated per-task below; do not re-derive it from dakota-iso source during implementation.
- **Zero new host-tool dependencies** — confirmed in issue #519's audit (qemu, OVMF, virt-fw-vars, python3, ssh/scp already in `elements/stacks/dev-tools.bst`/`core/mise.bst`/`elements/core/openssh.bst`; `socat`/`sshpass` are deliberately absent and the ported scripts' own fallback paths already cover that). Do not add packages to any `.bst` element or `mise.toml` as part of this plan — if a task appears to need one, stop and re-check the audit before adding anything.
- Secrets handling must not regress: `LUKS_PASSPHRASE` and the fisherman recipe's passphrase field follow the exact same non-interactive, never-logged-to-argv discipline the source scripts already use (Python-json-escaped, piped via files/stdin, never interpolated bare into a shell command echoed anywhere).
- Acceptance for the build path (Phase 1): the ISO `mise run build-iso` produces after porting must successfully complete `mise run iso-install-test` (Phase 2's own acceptance target) — the two phases' acceptance criteria compose, do not invent a separate "diff the old and new ISO bytes" gate, since dakota-iso's own build is not byte-reproducible run to run (timestamps, layer ordering) and chasing that would be a distraction from what actually matters: does the ISO boot and install.
- Acceptance for the test path (Phase 2): `mise run iso-install-test` and `mise run luks-install-test` both pass end-to-end using **only** krytis-native tooling — no `DAKOTA_ISO_DIR` resolution, no `just` invocation, anywhere in the call path.
- Phase 3 (fork demotion) is **documentation and a go/no-go checklist only** in this plan. Do not reset `kitten-lily/dakota-iso`'s `main` branch as part of executing this plan without a separate, explicit, in-the-moment confirmation from the user — that step rewrites history on a fork outside krytis and is irreversible without a backup ref.

---

## Phase 1: Build path

### Task 1: Vendor the live-environment source tree

**Files:**
- Create: `live/flatpaks` (from `dakota-iso/live/src/flatpaks`, verbatim — generic Bluefin-family flatpak list, krytis-neutral, 15 app IDs)
- Create: `live/install-flatpaks.sh` (from `dakota-iso/live/src/install-flatpaks.sh`, verbatim, 143 lines — pulls the bootc-installer flatpak bundle + reconciles Flathub apps against `live/flatpaks`; no krytis-specific content, ports unchanged)
- Create: `live/configure-live.sh` (from `dakota-iso/live/src/configure-live-krytis.sh`, adapted — see Step 3)
- Create: `live/recipe.json` (from `dakota-iso/live/src/etc/bootc-installer/recipe.json`, adapted — see Step 4)
- Create: `live/images/krytis-logo.png` (from `dakota-iso/live/src/krytis/images/krytis-logo.png`, verbatim binary copy)
- Delete (after Task 6's cutover, not in this task): nothing yet — dakota-iso stays untouched until Phase 1/2 both land.

**Interfaces:**
- Produces: `live/configure-live.sh` is invoked by `live/Containerfile` (Task 2) as the single, unconditional live-environment setup script — no target-dispatch needed since krytis is the only target.

- [ ] **Step 1: Copy the flatpak list and installer script verbatim**

```bash
mkdir -p /home/lily/Projects/krytis/live
cp /home/lily/Projects/dakota-iso/live/src/flatpaks /home/lily/Projects/krytis/live/flatpaks
cp /home/lily/Projects/dakota-iso/live/src/install-flatpaks.sh /home/lily/Projects/krytis/live/install-flatpaks.sh
chmod +x /home/lily/Projects/krytis/live/install-flatpaks.sh
mkdir -p /home/lily/Projects/krytis/live/images
cp /home/lily/Projects/dakota-iso/live/src/krytis/images/krytis-logo.png /home/lily/Projects/krytis/live/images/krytis-logo.png
```

- [ ] **Step 2: Verify the copies are byte-identical to source**

Run: `diff /home/lily/Projects/dakota-iso/live/src/flatpaks /home/lily/Projects/krytis/live/flatpaks && diff /home/lily/Projects/dakota-iso/live/src/install-flatpaks.sh /home/lily/Projects/krytis/live/install-flatpaks.sh && cmp /home/lily/Projects/dakota-iso/live/src/krytis/images/krytis-logo.png /home/lily/Projects/krytis/live/images/krytis-logo.png`
Expected: no output (files identical), exit 0.

- [ ] **Step 3: Port `configure-live-krytis.sh` → `live/configure-live.sh`**

Source is 389 lines (already fully read during investigation). Copy it, then apply exactly these two changes:

(a) Update the `SCRIPT_DIR`-relative asset path (source line 219 referenced `$SCRIPT_DIR/krytis/images/krytis-logo.png`; the vendored tree drops the `krytis/` nesting since there's only one target now — Task 2's Containerfile will `COPY live/images/ /tmp/live/images/`):

```bash
# Before (dakota-iso, line 218-221):
[[ -f "$SCRIPT_DIR/krytis/images/krytis-logo.png" ]] && \
    install -Dm644 "$SCRIPT_DIR/krytis/images/krytis-logo.png" \
        /usr/share/bootc-installer/images/krytis-logo.png

# After (krytis, live/configure-live.sh):
[[ -f "$SCRIPT_DIR/images/krytis-logo.png" ]] && \
    install -Dm644 "$SCRIPT_DIR/images/krytis-logo.png" \
        /usr/share/bootc-installer/images/krytis-logo.png
```

(b) Update the recipe.json template read path (source line 248: `with open("$SCRIPT_DIR/etc/bootc-installer/recipe.json") as f:`) to match Task 1's flattened layout:

```python
# Before:
with open("$SCRIPT_DIR/etc/bootc-installer/recipe.json") as f:

# After:
with open("$SCRIPT_DIR/recipe.json") as f:
```

Every other line — `useradd`/`passwd` live-user setup, the DEBUG sshd override, the noctalia onboarding marker, the passwordless-polkit rules, `systemd-firstboot` masking, the greetd `config.toml` override, the `bootc/install/00-defaults.toml`, the `storage.conf` VFS config, the `images.json` heredoc (KRYTIS_IMGREF etc.), the fisherman symlink discovery, the polkit policy file, the desktop entry, the `var-tmp.mount`/`live-run-expand.service` units — ports byte-for-byte unchanged. No other krytis-specific content in this file references a path this migration moves.

```bash
cp /home/lily/Projects/dakota-iso/live/src/configure-live-krytis.sh /home/lily/Projects/krytis/live/configure-live.sh
# then apply the two edits above with the Edit tool
chmod +x /home/lily/Projects/krytis/live/configure-live.sh
```

- [ ] **Step 4: Port the recipe.json template → `live/recipe.json`**

Source (`dakota-iso/live/src/etc/bootc-installer/recipe.json`) is the **shared, generic Bluefin-branded** template — `configure-live.sh`'s python3 heredoc (ported unchanged in Step 3) already overrides every krytis-relevant field (`distro_name`, `welcome_title`, `imgref`, `targetImgref`, `image`, `local_imgref`, `bootloader`, `composeFsBackend`, `filesystem`, the whole `tour` block) at live-boot time, so the template itself needs no krytis-specific edits — copy verbatim:

```bash
cp /home/lily/Projects/dakota-iso/live/src/etc/bootc-installer/recipe.json /home/lily/Projects/krytis/live/recipe.json
```

- [ ] **Step 5: Commit**

```bash
cd /home/lily/Projects/krytis
git add live/flatpaks live/install-flatpaks.sh live/configure-live.sh live/recipe.json live/images/krytis-logo.png
git commit -m "feat(iso): vendor live-environment source tree from dakota-iso"
```

---

### Task 2: Vendor and simplify the Containerfiles

**Files:**
- Create: `live/Containerfile` (from `dakota-iso/live/Containerfile`, simplified — collapses `TARGET`/`TAG`/`REGISTRY` build-args to a single `BASE_IMAGE` build-arg, since krytis has exactly one source image)
- Create: `live/iso-tools/Containerfile` (from `dakota-iso/live/iso-tools/Containerfile`, verbatim — already krytis-agnostic, built directly by `mise/tasks/build-iso` today, not through `just`)

**Interfaces:**
- Consumes: `live/flatpaks`, `live/install-flatpaks.sh`, `live/configure-live.sh`, `live/recipe.json`, `live/images/` (Task 1).
- Produces: an image built as `podman build --build-arg BASE_IMAGE=<local-tag> -t localhost/krytis-live-installer -f live/Containerfile live`.

- [ ] **Step 1: Vendor `live/iso-tools/Containerfile` verbatim**

```bash
mkdir -p /home/lily/Projects/krytis/live/iso-tools
cp /home/lily/Projects/dakota-iso/live/iso-tools/Containerfile /home/lily/Projects/krytis/live/iso-tools/Containerfile
diff /home/lily/Projects/dakota-iso/live/iso-tools/Containerfile /home/lily/Projects/krytis/live/iso-tools/Containerfile
```
Expected: no diff. This Containerfile already installs exactly `buildah skopeo xorriso mtools dosfstools squashfs-tools isomd5sum python3 tar` on a Fedora-minimal base — no krytis-specific content, no changes needed. `mise/tasks/build-iso` already builds it directly (Step 3 of that existing task, unchanged by this plan): `podman build -t "${ISO_TOOLS_IMAGE}" "${DAKOTA_ISO_DIR}/live/iso-tools"` — Task 6 of this plan repoints that one path.

- [ ] **Step 2: Write the simplified `live/Containerfile`**

Source is 177 lines, 3 stages (`ref` → `initramfs-native`/`initramfs-builder` → final). Every stage's *logic* ports unchanged — only the multi-target `ARG TARGET`/`ARG TAG`/`ARG REGISTRY` header collapses into one `ARG BASE_IMAGE`, since krytis never builds any other target:

```dockerfile
# Krytis live ISO: environment image
#
# Build with:
#   podman build --build-arg BASE_IMAGE=localhost/krytis:latest -t localhost/krytis-live-installer -f live/Containerfile live
#
# BASE_IMAGE is the freshly-built (or sealed) krytis image the live environment
# is built FROM — everything else (initramfs rebuild, live-user setup,
# installer config, flatpaks) is identical regardless of which krytis tag.
#
# Three-stage build:
#   1. ref                — source krytis image (provides kernel modules)
#   2. initramfs-builder   — Debian: builds a dmsquash-live initramfs against
#                            krytis's kernel modules in a native glibc environment
#   3. final               — krytis: receives the rebuilt initramfs + live-env setup
#
# Krytis is Freedesktop SDK based — no package manager, no dracut. The initramfs
# is built in a separate Debian stage so no cross-distro binary grafting is
# needed; only the initramfs.img output crosses the stage boundary.

ARG BASE_IMAGE=localhost/krytis:latest

# ── Stage 1: Reference image (kernel modules source) ─────────────────────────
FROM ${BASE_IMAGE} AS ref

# ── Stage 2a: Native initramfs probe ──────────────────────────────────────────
# Krytis has no dnf/dracut, so this always falls through to the Debian
# cross-build stage below — kept as a stage (rather than deleted) so the
# fallback-detection logic stays identical to dakota-iso's, in case a future
# krytis base ever gains native dracut.
FROM ref AS initramfs-native
RUN set -e; \
    kernel=$(ls /usr/lib/modules | sort -V | tail -1); \
    if command -v dracut >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1; then \
        command -v dnf >/dev/null 2>&1 && \
            dnf install -y dracut dracut-live --setopt=install_weak_deps=False -q 2>/dev/null || true; \
        command -v dracut >/dev/null 2>&1 || { echo 'no dracut after install attempt — falling back to Debian cross-build'; echo debian > /tmp/dracut-status; touch /tmp/initramfs.img; exit 0; }; \
        dracut --list-modules 2>/dev/null | grep -q dmsquash-live || { echo 'dmsquash-live module not found — falling back to Debian cross-build'; echo debian > /tmp/dracut-status; touch /tmp/initramfs.img; exit 0; }; \
        echo "Building initramfs natively for kernel ${kernel}"; \
        if dracut -v --force --reproducible --no-hostonly \
                --add "dmsquash-live" \
                /tmp/initramfs.img "${kernel}"; then \
            ls -lh /tmp/initramfs.img; \
            echo native > /tmp/dracut-status; \
        else \
            echo "Native dracut failed (exit $?) — falling back to Debian cross-build"; \
            echo debian > /tmp/dracut-status; \
            touch /tmp/initramfs.img; \
        fi; \
    else \
        echo "Target has no dracut/rpm — will use Debian cross-build"; \
        echo debian > /tmp/dracut-status; \
        touch /tmp/initramfs.img; \
    fi

# ── Stage 2b: Debian — cross-builds the initramfs (the path krytis always takes)
FROM debian:bookworm AS initramfs-builder

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dracut \
        dracut-live \
        dmsetup \
        systemd-boot-efi \
        xfsprogs \
        zstd \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ref /usr/lib/modules /usr/lib/modules
COPY --from=initramfs-native /tmp/dracut-status /tmp/
COPY --from=initramfs-native /tmp/initramfs.img /tmp/native-initramfs/

RUN set -ex; \
    if grep -q debian /tmp/dracut-status 2>/dev/null; then \
        kernel=$(ls /usr/lib/modules | sort -V | tail -1); \
        echo "Cross-building initramfs (Debian dracut) for kernel ${kernel}"; \
        DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
            --add "dmsquash-live" \
            --add-drivers "squashfs overlay loop iso9660 sr_mod cdrom" \
            /tmp/initramfs.img "${kernel}"; \
    else \
        echo "Using native initramfs"; \
        cp /tmp/native-initramfs/initramfs.img /tmp/initramfs.img; \
    fi; \
    ls -lh /tmp/initramfs.img

# ── Stage 3: Final live image ─────────────────────────────────────────────────
ARG BASE_IMAGE=localhost/krytis:latest
FROM ${BASE_IMAGE}

ARG INSTALLER_CHANNEL=stable
ARG DEBUG=0
ARG PAYLOAD_REF=
ENV INSTALLER_CHANNEL=${INSTALLER_CHANNEL} DEBUG=${DEBUG}
ENV PAYLOAD_REF=${PAYLOAD_REF}

# Krytis has no dnf — this block existed in dakota-iso to serve ostree-based
# targets (bluefin/bluefin-lts) that need systemd-boot-unsigned + fuse-overlayfs
# installed for bootcDirect installs. Krytis is composefs-only and already
# ships systemd-boot; dropped rather than ported (dead for the only target
# this Containerfile will ever build).

COPY --from=initramfs-builder /tmp/initramfs.img /tmp/initramfs.img
# xfsprogs runtime deps from Debian bookworm — see dakota-iso's original
# comment (preserved): libblkid/libuuid must NOT be copied from Debian, krytis's
# own (newer, BLKID_2_40+) versions are required by sfdisk/libfdisk.
COPY --from=initramfs-builder \
    /usr/lib/x86_64-linux-gnu/libinih.so.1 \
    /usr/lib/x86_64-linux-gnu/liburcu.so.8 \
    /usr/lib/x86_64-linux-gnu/
COPY --from=initramfs-builder /usr/lib/x86_64-linux-gnu/libinih.so.1 /usr/lib64/libinih.so.1
COPY --from=initramfs-builder /usr/lib/x86_64-linux-gnu/liburcu.so.8 /usr/lib64/liburcu.so.8
COPY --from=initramfs-builder /usr/sbin/mkfs.xfs /tmp/debian-mkfs.xfs
COPY --from=initramfs-builder /usr/sbin/xfs_repair /tmp/debian-xfs_repair
RUN if grep -q debian /tmp/dracut-status 2>/dev/null; then \
        install -m755 /tmp/debian-mkfs.xfs /usr/sbin/mkfs.xfs && \
        install -m755 /tmp/debian-xfs_repair /usr/sbin/xfs_repair; \
    fi; \
    rm -f /tmp/debian-mkfs.xfs /tmp/debian-xfs_repair
COPY --from=initramfs-builder /usr/lib/systemd/boot /usr/lib/systemd/boot
RUN kernel=$(ls /usr/lib/modules | sort -V | tail -1) && \
    mv /tmp/initramfs.img "/usr/lib/modules/${kernel}/initramfs.img" && \
    echo "Replaced initramfs for kernel ${kernel}"

ARG CACHE_BUST=0
COPY flatpaks /tmp/flatpaks-list
RUN --mount=type=bind,source=.,target=/src \
    --mount=type=cache,target=/var/cache/flatpak-dl,id=krytis-flatpak \
    bash -c 'if command -v flatpak >/dev/null 2>&1; then /src/install-flatpaks.sh; else echo "Skipping flatpaks — flatpak not present"; fi'

COPY . /tmp/src/
RUN chmod +x /tmp/src/configure-live.sh && /tmp/src/configure-live.sh
```

Every krytis-specific detail dakota-iso's Containerfile handled via file-existence dispatch (`configure-live-${TARGET}.sh`) is now unconditional (`configure-live.sh` always runs, since it's the only script) — this is the single-target collapse the Global Constraints section calls out.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add live/Containerfile live/iso-tools/Containerfile
git commit -m "feat(iso): vendor and simplify live-environment Containerfiles"
```

---

### Task 3: New mise task `iso-container-build`

**Files:**
- Create: `mise/tasks/iso-container-build`

**Interfaces:**
- Consumes: `live/Containerfile`, `live/iso-tools/Containerfile` (Task 2).
- Produces: a local image tagged `localhost/krytis-live-installer`, consumed by Task 5's squashfs assembly.

- [ ] **Step 1: Write the task**

Ports `dakota-iso justfile:container` (lines 100-119), collapsing `LIVE_TARGET`/`LIVE_TAG`/`LIVE_REGISTRY` (previously read from `{{target}}/live_target`, `{{target}}/tag`, `{{target}}/registry`) into a single required `--base-image` flag, since krytis has no per-target metadata files to read from anymore:

```bash
#!/usr/bin/env bash
#MISE description="Build the krytis live-environment container image (live/Containerfile)"
#USAGE flag "--base-image <ref>" default="localhost/krytis:latest" help="Local image tag to build the live environment FROM"
#USAGE flag "--debug" help="Enable SSH in the live environment (not for production)"
#USAGE flag "--installer-channel <channel>" default="stable" help="bootc-installer flatpak channel: stable or dev"
#USAGE flag "--payload-ref <ref>" help="OCI ref of the offline install payload, forwarded into the built image"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

BASE_IMAGE="${usage_base_image:-localhost/krytis:latest}"
DEBUG=$([[ "${usage_debug:-}" == "true" ]] && echo 1 || echo 0)
INSTALLER_CHANNEL="${usage_installer_channel:-stable}"
PAYLOAD_REF="${usage_payload_ref:-}"

podman build --cap-add sys_admin --security-opt label=disable \
    --layers \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg DEBUG="${DEBUG}" \
    --build-arg INSTALLER_CHANNEL="${INSTALLER_CHANNEL}" \
    --build-arg CACHE_BUST="$(date +%Y%m%d)" \
    --build-arg PAYLOAD_REF="${PAYLOAD_REF}" \
    -t localhost/krytis-live-installer \
    -f live/Containerfile live
```

- [ ] **Step 2: Make it executable and smoke-test the flag parsing**

```bash
chmod +x /home/lily/Projects/krytis/mise/tasks/iso-container-build
cd /home/lily/Projects/krytis && mise run iso-container-build --help
```
Expected: prints the `#USAGE` flags (`--base-image`, `--debug`, `--installer-channel`, `--payload-ref`) with their descriptions, exit 0. (A real build requires a local `localhost/krytis:latest` image — deferred to Task 6's integration test.)

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add mise/tasks/iso-container-build
git commit -m "feat(iso): add iso-container-build mise task"
```

---

### Task 4: Vendor `build-iso.sh` (single-arch path)

**Files:**
- Create: `live/build-iso.sh` (from `dakota-iso/live/src/build-iso.sh`, single-arch path only — multi-arch flag parsing and branch dropped, confirmed dead: `iso-sd-boot.sh` never passes `--arch`)

**Interfaces:**
- Produces: `live/build-iso.sh --title <t> --label <l> <boot-tar> <squashfs> <output-iso>` (same CLI as before, multi-arch flags removed since nothing calls them).

- [ ] **Step 1: Copy and strip the multi-arch path**

Source is 420 lines. The multi-arch branch (`--arch` flag parsing, `MULTI_ARCH` conditional, `process_arch_boot_files` looping over multiple `SERIAL_CONSOLE`/`EFI_BINARY_NAME`/`SYSTEMD_BOOT_SRC` arch maps) is confirmed dead — `scripts/iso-sd-boot.sh`'s single call site (line 294-297) never passes `--arch`, only positional `<boot-tar> <squashfs> <output-iso>`. Port the single-arch code path only:

```bash
cp /home/lily/Projects/dakota-iso/live/src/build-iso.sh /home/lily/Projects/krytis/live/build-iso.sh
```

Then edit `live/build-iso.sh`:
- Remove the `--arch` case from the `while [[ $# -gt 0 ]]` flag-parsing loop (keep `--title`/`--label`/`--store`).
- Remove the `declare -A SERIAL_CONSOLE`/`EFI_BINARY_NAME`/`SYSTEMD_BOOT_SRC` per-arch maps — hardcode the x86_64 values directly where `process_arch_boot_files` used them (`ttyS0`, `BOOTX64.EFI`, `systemd-bootx64.efi`).
- Remove the `if [[ "${MULTI_ARCH}" == "true" ]]` branch in the ESP-populate section (around source line 348-364) — keep only the single-arch `else` branch.
- Update the module docstring's "Multi-arch mode" section to note it was dropped (krytis is x86_64-only; re-add if krytis ever ships aarch64).

Everything else — the El Torito/GPT layout rationale comments (issue #15 reference), the `mkfs.fat`/mtools ESP population, the `${XORRISO} -as mkisofs`/`${IMPLANTISOMD5}` invocation with the `ISO_TOOLS_IMAGE` routing already handled by the caller setting `$XORRISO`/`$IMPLANTISOMD5`, and the protective-MBR verification at the end — ports unchanged. This script has zero krytis-specific content; it's pure ISO-authoring logic.

- [ ] **Step 2: Verify the script is still syntactically valid bash**

Run: `bash -n /home/lily/Projects/krytis/live/build-iso.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
chmod +x live/build-iso.sh
git add live/build-iso.sh
git commit -m "feat(iso): vendor build-iso.sh, single-arch path only"
```

---

### Task 5: Extend `mise/tasks/build-iso` with native squashfs assembly

This is the largest task in the build path — it replaces the `just --justfile "${DAKOTA_ISO_DIR}/justfile" ... iso-sd-boot krytis` call (existing `build-iso` lines 144-153) with native bash performing `scripts/iso-sd-boot.sh`'s own orchestration: call the new `iso-container-build` task, export the payload, assemble the squashfs (composefs/VFS branch only — the overlay branch is confirmed dead for krytis), then call `live/build-iso.sh`.

**Files:**
- Modify: `mise/tasks/build-iso` (replace lines 120-153's `ISO_TOOLS_IMAGE`/podman-build/`just` block)

**Interfaces:**
- Consumes: `mise/tasks/iso-container-build` (Task 3), `live/build-iso.sh` (Task 4).
- Produces: unchanged external behavior — `mise run build-iso [--sealed] [--debug] ...` still writes `${OUTPUT_DIR}/krytis-live.iso` or `${OUTPUT_DIR}/krytis-live-sealed.iso`, exactly as today.

- [ ] **Step 1: Read the current full task to confirm line numbers before editing**

Run: `read /home/lily/Projects/krytis/mise/tasks/build-iso` (already read in full during this investigation — 172 lines; re-read immediately before editing in case another change landed first).

- [ ] **Step 2: Replace the `DAKOTA_ISO_DIR` resolution block and the final `just` invocation**

Remove entirely (existing lines 14-29): the `DAKOTA_ISO_DIR` sibling-checkout resolution and its existence check — no longer needed, everything the build needs now lives in this repo.

Remove entirely (existing lines 44-54): the "does the sibling checkout predate sealed-payload support" guard — no longer applicable, there's no sibling checkout to be stale.

Replace the final block (existing lines 120-153: `ISO_TOOLS_IMAGE` build + `just` invocation) with:

```bash
OUTPUT_DIR="${usage_output_dir:-output}"
WORKDIR="${usage_workdir:-${OUTPUT_DIR}}"
DEBUG=$([[ "${usage_debug:-}" == "true" ]] && echo 1 || echo 0)
COMPRESSION="${usage_compression:-fast}"

mkdir -p "${OUTPUT_DIR}" "${WORKDIR}"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
WORKDIR="$(realpath "${WORKDIR}")"

# buildah + xorriso have no freedesktop-sdk component, so they are not in the
# krytis image. Build the iso-tools container (Fedora-based, carries both) and
# route xorriso/implantisomd5 through it. The host runs everything else
# (podman, skopeo, mksquashfs, mtools, dosfstools) from the dev-tools stack.
ISO_TOOLS_IMAGE="${ISO_TOOLS_IMAGE:-localhost/iso-tools:latest}"
echo "==> Building iso-tools container (${ISO_TOOLS_IMAGE})..."
podman build -t "${ISO_TOOLS_IMAGE}" live/iso-tools

echo "==> Building krytis live ISO"
echo "    output:     ${OUTPUT_DIR}"
echo "    workdir:    ${WORKDIR}"
echo "    compress:   ${COMPRESSION}"
echo "    iso-tools:  ${ISO_TOOLS_IMAGE}"
echo "    sealed:     ${SEALED}"
echo "    payload:    ${PAYLOAD_REF}"

./mise/tasks/iso-container-build --base-image "${LOCAL_IMAGE}" \
    --debug="${usage_debug:-false}" \
    --payload-ref "${PAYLOAD_REF}"

echo "=== Disk space before squashfs assembly ==="
df -h "${OUTPUT_DIR}"

SQUASHFS="${OUTPUT_DIR}/krytis-rootfs.sfs"
BOOT_TAR="${OUTPUT_DIR}/krytis-boot-files.tar"
CS_STAGING="${WORKDIR}/krytis-cs-staging"
SQUASHFS_ROOT="${WORKDIR}/krytis-sfs-root"
PAYLOAD_OCI="${OUTPUT_DIR}/krytis-payload.oci.tar"
PAYLOAD_INPUT="${OUTPUT_DIR}/krytis-payload-input.oci.tar"
trap 'rm -f "${SQUASHFS}" "${BOOT_TAR}" "${PAYLOAD_OCI}" "${PAYLOAD_INPUT}" 2>/dev/null || true' EXIT

echo "=== Exporting ${PAYLOAD_REF} to oci-archive for the offline store ==="
podman save --format oci-archive -o "${PAYLOAD_INPUT}" "${PAYLOAD_REF}"

# PAYLOAD_SEALED=1 (krytis's --sealed flag, already computed above as SEALED):
# embed the exported archive byte-identically — no digest-invalidating rewrite.
# The non-sealed path would normally run payload-prep.sh's buildah squash/inject
# step here; that whole path is dead for krytis (confirmed in issue #519 — every
# krytis build sets PAYLOAD_SEALED=1), so it is not ported. If krytis ever ships
# an unsealed offline-store build again, port live/iso-tools/Containerfile's
# buildah/skopeo digest-injection logic back in at this point.
cp --reflink=auto "${PAYLOAD_INPUT}" "${PAYLOAD_OCI}"

export OUTPUT_DIR WORKDIR PAYLOAD_OCI CS_STAGING SQUASHFS_ROOT SQUASHFS BOOT_TAR COMPRESSION

_ns_build_squashfs() {
    set -euo pipefail
    mkdir -p "${CS_STAGING}" "${SQUASHFS_ROOT}"
    # VFS containers-storage graphroot: matches configure-live.sh's
    # /etc/containers/storage.conf (driver="vfs"), which is required for the
    # offline install to find the embedded payload — see that file's comments
    # for the full rationale (overlay-vs-vfs, graphroot collision avoidance).
    mkdir -p "${CS_STAGING}/vfs"
    skopeo copy "oci-archive:${PAYLOAD_OCI}" "containers-storage:[vfs@${CS_STAGING}+/var/run/containers/storage]localhost/krytis:latest" \
        --dest-storage-driver vfs
    STORE_SFS="${OUTPUT_DIR}/krytis-store.sfs"
    mksquashfs "${CS_STAGING}" "${STORE_SFS}" -comp zstd -Xcompression-level "$([[ "${COMPRESSION}" == "release" ]] && echo 19 || echo 3)" -noappend

    podman export "$(podman create localhost/krytis-live-installer true)" | tar -C "${SQUASHFS_ROOT}" -xf -
    mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS}" -comp zstd -Xcompression-level "$([[ "${COMPRESSION}" == "release" ]] && echo 19 || echo 3)" -noappend

    kernel=$(ls "${SQUASHFS_ROOT}/usr/lib/modules" | sort -V | tail -1)
    tar -C "${SQUASHFS_ROOT}/usr/lib/modules/${kernel}" -cf "${BOOT_TAR}" initramfs.img vmlinuz
}
export -f _ns_build_squashfs

if [[ $(id -u) -eq 0 ]]; then
    bash -c _ns_build_squashfs
else
    podman unshare bash -c _ns_build_squashfs
fi

echo "=== Disk space after squashfs, before ISO assembly ==="
df -h "${OUTPUT_DIR}"
du -sh "${SQUASHFS}" "${BOOT_TAR}" 2>/dev/null || true

XORRISO="xorriso"
IMPLANTISOMD5="implantisomd5"
if [[ -n "${ISO_TOOLS_IMAGE:-}" ]]; then
    XORRISO="podman run --rm -v ${OUTPUT_DIR}:${OUTPUT_DIR} ${ISO_TOOLS_IMAGE} xorriso"
    IMPLANTISOMD5="podman run --rm -v ${OUTPUT_DIR}:${OUTPUT_DIR} ${ISO_TOOLS_IMAGE} implantisomd5"
fi

TMPDIR="${OUTPUT_DIR}" \
XORRISO="${XORRISO}" \
IMPLANTISOMD5="${IMPLANTISOMD5}" \
    bash "live/build-iso.sh" \
        --title "Krytis Live" \
        --label "KRYTIS_LIVE" \
        "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/krytis-live.iso"

echo "ISO ready: ${OUTPUT_DIR}/krytis-live.iso"
```

**Notes on what this collapses, matching issue #519's exclusion list exactly:**
- `LIVE_TITLE`/`LIVE_LABEL` (previously read from `krytis/live_title`/`krytis/live_label`) → hardcoded `"Krytis Live"`/`"KRYTIS_LIVE"`, since there's only one target's values to carry.
- The overlay (non-composefs) squashfs-assembly branch inside `_ns_build_squashfs` → not ported (dead for krytis, confirmed `live/src/krytis/composefs` = `"true"` always).
- `live/iso-tools/payload-prep.sh`'s buildah/skopeo digest-injection path → not ported (dead once `PAYLOAD_SEALED=1`, which every krytis build sets).
- The disk-space/`podman images` diagnostic echoes from `iso-sd-boot.sh` are kept (cheap, useful for debugging a failed CI run) but consolidated rather than repeated at every step, matching this task's already-terser existing style.

- [ ] **Step 3: Verify the edited task is still valid bash**

Run: `bash -n /home/lily/Projects/krytis/mise/tasks/build-iso`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
cd /home/lily/Projects/krytis
git add mise/tasks/build-iso
git commit -m "feat(iso): natively assemble squashfs+ISO in build-iso, drop just dependency"
```

---

### Task 6: Build-path cutover and integration verification

**Files:**
- Modify: `mise/tasks/build-iso` (delete the now-fully-replaced `DAKOTA_ISO_DIR`/sibling-checkout logic if any remnants remain after Task 5's edit — re-read the file fresh first)

- [ ] **Step 1: Re-read the fully-edited task end to end**

Run: `read /home/lily/Projects/krytis/mise/tasks/build-iso` and confirm zero remaining references to `DAKOTA_ISO_DIR`, `just`, or any `dakota-iso` path.

- [ ] **Step 2: Build the krytis image locally (prerequisite, not part of this plan's scope)**

Run: `cd /home/lily/Projects/krytis && mise run build` (existing task — builds `localhost/krytis:latest`, out of scope to modify here).
Expected: completes successfully, `podman image exists localhost/krytis:latest` returns 0.

- [ ] **Step 3: Run the ported build-iso end to end**

Run: `cd /home/lily/Projects/krytis && mise run build-iso --debug`
Expected: completes without invoking `just` or touching any `../dakota-iso` path (verify via `strace -f -e trace=execve ... 2>&1 | grep -c dakota-iso` returning 0, or simply confirm no error about a missing sibling checkout — there should be none since that check no longer exists). Final line: `ISO ready: output/krytis-live.iso`.

- [ ] **Step 4: Sanity-check the ISO's partition layout**

Run: `xorriso -indev output/krytis-live.iso -report_system_area plain 2>/dev/null | grep -E '^(System area|GPT)'`
Expected: reports a GPT layout with `protective` in the system-area summary (same check `live/build-iso.sh` runs internally at the end of Task 4's script).

- [ ] **Step 5: Commit any final fixups found during the live run**

```bash
cd /home/lily/Projects/krytis
git add -A
git commit -m "fix(iso): build-path integration fixes found during end-to-end verification"
```
(Only if Step 3 required fixes; skip this commit if it passed clean.)

---

## Phase 2: Test path

### Task 7: Vendor `scripts/e2e-lib.sh`

**Files:**
- Create: `scripts/e2e-lib.sh` (from `dakota-iso/scripts/e2e-lib.sh`, verbatim, 165 lines)

**Interfaces:**
- Produces: `e2e_on_exit`, `e2e_cleanup_add`, `e2e_ssh_auth_init`, `e2e_monitor`, `e2e_qemu_stop`, `e2e_port_free` — sourced (not executed) by every task in this phase.

- [ ] **Step 1: Copy verbatim**

This library is already fully krytis-neutral by design — its own header comment explains it was written specifically because "StarlitOS Krytis is the machine the sealed gate runs on" and has no `dnf`/`apt`. No changes needed.

```bash
mkdir -p /home/lily/Projects/krytis/scripts
cp /home/lily/Projects/dakota-iso/scripts/e2e-lib.sh /home/lily/Projects/krytis/scripts/e2e-lib.sh
chmod +x /home/lily/Projects/krytis/scripts/e2e-lib.sh
diff /home/lily/Projects/dakota-iso/scripts/e2e-lib.sh /home/lily/Projects/krytis/scripts/e2e-lib.sh
```
Expected: no diff.

- [ ] **Step 2: Verify it sources cleanly**

Run: `bash -c 'source /home/lily/Projects/krytis/scripts/e2e-lib.sh && type e2e_qemu_stop e2e_monitor e2e_ssh_auth_init e2e_port_free'`
Expected: prints all four function definitions, exit 0.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add scripts/e2e-lib.sh
git commit -m "feat(iso): vendor e2e-lib.sh QEMU test helpers"
```

---

### Task 8: Vendor the in-guest install scripts

**Files:**
- Create: `scripts/fisherman-install.sh` (from `dakota-iso/scripts/fisherman-install.sh`, verbatim, 136 lines)
- Create: `scripts/show-screenshot.sh` (from `dakota-iso/dakota/src/show-screenshot.sh` — note the source path, *not* `dakota-iso/live/src/show-screenshot.sh`, which is a stray unused duplicate confirmed by the call-graph trace; the actually-invoked copy lives under the legacy `dakota/` directory)

**Interfaces:**
- `scripts/fisherman-install.sh <recipe.json>` — uploaded via `scp` and executed *inside the guest VM* by Task 10's script, not run on the krytis host.
- `scripts/show-screenshot.sh <ppm-path> <label>` — run on the krytis host by Task 12.

- [ ] **Step 1: Copy both verbatim**

```bash
cp /home/lily/Projects/dakota-iso/scripts/fisherman-install.sh /home/lily/Projects/krytis/scripts/fisherman-install.sh
cp /home/lily/Projects/dakota-iso/dakota/src/show-screenshot.sh /home/lily/Projects/krytis/scripts/show-screenshot.sh
chmod +x /home/lily/Projects/krytis/scripts/fisherman-install.sh /home/lily/Projects/krytis/scripts/show-screenshot.sh
```

- [ ] **Step 2: Verify byte-identical**

Run: `diff /home/lily/Projects/dakota-iso/scripts/fisherman-install.sh /home/lily/Projects/krytis/scripts/fisherman-install.sh && diff /home/lily/Projects/dakota-iso/dakota/src/show-screenshot.sh /home/lily/Projects/krytis/scripts/show-screenshot.sh`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add scripts/fisherman-install.sh scripts/show-screenshot.sh
git commit -m "feat(iso): vendor in-guest install and screenshot helper scripts"
```

---

### Task 9: New mise task `iso-boot-live`

**Files:**
- Create: `mise/tasks/iso-boot-live`

**Interfaces:**
- Consumes: `scripts/e2e-lib.sh` (Task 7), an ISO from `output/krytis-live.iso` (or `--iso-path` override).
- Produces: a daemonized QEMU instance; writes `--monitor-socket`/`--serial-log` paths (defaults under `/tmp` or caller-specified); polls until the live environment is SSH-ready.

- [ ] **Step 1: Write the task**

Ports `dakota-iso justfile:plain-boot-qemu-live` (lines 1030-1139), krytis-target-only (drops the `{{output_dir}}/{{target}}-debug-live.iso` glob-search generality down to just `krytis-live.iso`/`krytis-live-sealed.iso`, matching `mise/tasks/build-iso`'s actual output filenames):

```bash
#!/usr/bin/env bash
#MISE description="Boot the krytis live ISO under QEMU (plain OVMF — the live ISO is deliberately unsigned)"
#USAGE flag "--iso-path <path>" help="ISO to boot; default searches output/ for krytis-live*.iso"
#USAGE flag "--disk <path>" default="/tmp/krytis-e2e-install.img" help="Install target disk (raw, created if missing)"
#USAGE flag "--scratch-disk <path>" default="/tmp/krytis-e2e-scratch.img" help="Scratch disk mounted over /var/tmp in the guest"
#USAGE flag "--monitor <path>" default="/tmp/krytis-e2e-live.mon" help="QEMU monitor unix socket path"
#USAGE flag "--serial-log <path>" default="/tmp/krytis-e2e-live.log" help="QEMU serial console log path"
#USAGE flag "--ssh-port <port>" default="10222" help="Host port forwarded to the guest's sshd"
#USAGE flag "--mem <mib>" default="4096" help="Guest RAM in MiB"
#USAGE flag "--smp <n>" default="2" help="Guest vCPU count"

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/scripts/e2e-lib.sh"

QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
[[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

ISO="${usage_iso_path:-}"
if [[ -z "$ISO" ]]; then
    for f in "${REPO_ROOT}/output/krytis-live-sealed.iso" "${REPO_ROOT}/output/krytis-live.iso"; do
        [[ -f "$f" ]] && { ISO="$f"; break; }
    done
fi
[[ -z "$ISO" || ! -f "$ISO" ]] && { echo "No ISO found — run: mise run build-iso" >&2; exit 1; }

OVMF_CODE=""
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
          /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
done
[[ -z "$OVMF_CODE" ]] && { echo "OVMF firmware not found" >&2; exit 1; }
OVMF_VARS_SCRATCH="/tmp/krytis-e2e-live-vars.fd"
for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
    [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS_SCRATCH}"; break; }
done
[[ -f "${OVMF_VARS_SCRATCH}" ]] || { echo "OVMF vars template not found" >&2; exit 1; }

DISK="${usage_disk:-/tmp/krytis-e2e-install.img}"
SCRATCH="${usage_scratch_disk:-/tmp/krytis-e2e-scratch.img}"
MONITOR="${usage_monitor:-/tmp/krytis-e2e-live.mon}"
SERIAL="${usage_serial_log:-/tmp/krytis-e2e-live.log}"
SSH_PORT="${usage_ssh_port:-10222}"
MEM="${usage_mem:-4096}"
SMP="${usage_smp:-2}"

[[ -f "${DISK}" ]] || truncate -s 64G "${DISK}"
[[ -f "${SCRATCH}" ]] || truncate -s 16G "${SCRATCH}"
rm -f "${MONITOR}" "${SERIAL}" "${MONITOR}.pid"

QEMU_ACCEL="-accel kvm"; QEMU_PREFIX=""
if ! test -r /dev/kvm 2>/dev/null; then
    sudo test -r /dev/kvm 2>/dev/null && QEMU_PREFIX="sudo" || QEMU_ACCEL="-accel tcg,thread=multi"
fi
CPU_FLAG="-cpu host"
[[ "$QEMU_ACCEL" =~ tcg ]] && CPU_FLAG="-cpu qemu64"

echo "Booting live ISO: $ISO (mem=${MEM} MiB)"
$QEMU_PREFIX "$QEMU" \
    -machine q35 $CPU_FLAG -m "${MEM}" -smp "${SMP}" $QEMU_ACCEL \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${OVMF_VARS_SCRATCH}" \
    -drive "if=none,id=iso,file=${ISO},media=cdrom,readonly=on,format=raw" \
    -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=iso \
    -drive "if=none,id=disk,file=${DISK},format=raw,cache=unsafe" -device virtio-blk-pci,drive=disk \
    -drive "if=none,id=scratch,file=${SCRATCH},format=raw,cache=unsafe" -device virtio-blk-pci,drive=scratch \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
    -monitor "unix:${MONITOR},server,nowait" \
    -serial "file:${SERIAL}" \
    -display none \
    -daemonize -pidfile "${MONITOR}.pid"
echo "Live QEMU started (monitor: ${MONITOR})"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=password"
e2e_ssh_auth_init live
SSH_PROBE="${E2E_SSH_WRAP} ssh $SSH_OPTS ${E2E_SSH_AUTH_OPTS} liveuser@127.0.0.1 -p ${SSH_PORT}"
echo "Waiting for live environment on port ${SSH_PORT}..."
for i in $(seq 1 60); do
    if grep -q "KRYTIS_LIVE_READY\|debug-ssh-banner" "${SERIAL}" 2>/dev/null; then
        for j in $(seq 1 30); do
            $SSH_PROBE true 2>/dev/null && { echo "Live environment ready."; exit 0; }
            sleep 2
        done
        echo "Serial marker seen but SSH never came up" >&2
        e2e_qemu_stop "${MONITOR}" "live VM"
        exit 1
    fi
    sleep 2
done
echo "Timeout waiting for live environment to boot" >&2
e2e_qemu_stop "${MONITOR}" "live VM"
exit 1
```

**Note on `KRYTIS_LIVE_READY`:** the source recipe polled for the literal string `DAKOTA_LIVE_READY` — this marker is printed by a live-session systemd unit keyed to the `LIVE_LABEL`/target name; verify against `dakota-iso/live/src/configure-live-krytis.sh`'s own live-ready unit (search for where that marker string is emitted — it did not appear in the portion of the file already read during this investigation) before finalizing this task, and update either this task's grep pattern or (more likely, since Task 1 already ports `configure-live.sh` unchanged) confirm the marker text is target-name-agnostic in the source and this rename is purely cosmetic. If the source script hardcodes `DAKOTA_LIVE_READY` literally, keep that exact string in this task's `grep` rather than renaming it — a real emitted marker must match what this task polls for.

- [ ] **Step 2: Verify flag parsing**

Run: `chmod +x /home/lily/Projects/krytis/mise/tasks/iso-boot-live && cd /home/lily/Projects/krytis && mise run iso-boot-live --help`
Expected: lists all 7 flags with descriptions.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add mise/tasks/iso-boot-live
git commit -m "feat(iso): add iso-boot-live mise task"
```

---

### Task 10: New script + mise task for the install phase

**Files:**
- Create: `scripts/iso-install-fisherman.sh` (from `dakota-iso/scripts/plain-install-qemu.sh`, composefs branch only — the ostree/bootcDirect branch and GRUB bootloader remap are dropped, confirmed dead for krytis)
- Create: `mise/tasks/iso-run-install`

**Interfaces:**
- Consumes: `scripts/e2e-lib.sh` (Task 7), `scripts/fisherman-install.sh` (Task 8, uploaded into the guest).
- Produces: an installed system on the disk Task 9 attached; powers down the live VM on completion.

- [ ] **Step 1: Port `scripts/iso-install-fisherman.sh`**

Source is 155 lines. Drop: the `LIVE_TARGET`/`BOOTLOADER_VARIANT` computation and the `live/src/${BOOTLOADER_VARIANT}/{composefs,bootloader}` file reads (lines 54-59 of the source) — hardcode `COMPOSEFS_BACKEND=true`, `BOOTLOADER="systemd"`, `FILESYSTEM="btrfs"` directly, since krytis has exactly one value for each (confirmed via `dakota-iso/live/src/krytis/composefs`, and krytis's own `images.json` leaf already hardcodes `"bootloader": "systemd", "filesystem": "btrfs"`). Drop the ostree/bootcDirect `else` branch of the `if [[ "${COMPOSEFS_BACKEND}" == "true" ]]` conditional (source lines 88-121's composefs branch is kept; the else-branch — the `fisher_repo`/go-build path for non-composefs targets — is deleted, along with the now-unused `$4`/`FISHER_REPO` positional argument).

```bash
#!/usr/bin/bash
# scripts/iso-install-fisherman.sh
# Run a fisherman composefs install via SSH — unencrypted by default.
#
# LUKS_PASSPHRASE (env, optional) installs to an ENCRYPTED root instead, by
# emitting an "encryption": {"type": "luks-passphrase"} recipe block.
# Callers that then want to BOOT the result need to answer a passphrase prompt
# — see mise/tasks/luks-install-test.
#
# sshpass and socat are used when present and transparently substituted when
# not — see scripts/e2e-lib.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/e2e-lib.sh
source "${SCRIPT_DIR}/e2e-lib.sh"

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <ssh-port> <monitor-live> <payload-ref>" >&2
    exit 1
fi

SSH_PORT="$1"
MONITOR_LIVE="$2"
PAYLOAD_IMAGE="$3"

DISK="/dev/vda"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=password -o ServerAliveInterval=30 -o ServerAliveCountMax=20"
e2e_ssh_auth_init live
SSH="${E2E_SSH_WRAP} ssh $SSH_OPTS ${E2E_SSH_AUTH_OPTS} liveuser@127.0.0.1 -p ${SSH_PORT}"
SCP="${E2E_SSH_WRAP} scp $SSH_OPTS ${E2E_SSH_AUTH_OPTS} -P ${SSH_PORT}"

# Use local containers-storage if the image is cached there (offline install);
# otherwise fall back to a network pull via docker://.
if $SSH "sudo podman image exists '${PAYLOAD_IMAGE}' 2>/dev/null"; then
    IMAGE_SRC="containers-storage:${PAYLOAD_IMAGE}"
else
    IMAGE_SRC="docker://${PAYLOAD_IMAGE}"
fi

# Krytis is always composefs + systemd-boot + btrfs — no per-target lookup.
COMPOSEFS_BACKEND=true
BOOTLOADER="systemd"
FILESYSTEM="btrfs"

RECIPE_TMP=$(mktemp /tmp/plain-recipe-XXXXXX.json)
e2e_cleanup_add "${RECIPE_TMP}"

if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
    ENCRYPTION_JSON=$(python3 -c 'import json,sys; print(json.dumps({"type": "luks-passphrase", "passphrase": sys.argv[1]}))' "${LUKS_PASSPHRASE}")
else
    ENCRYPTION_JSON='{"type": "none"}'
fi

cat > "${RECIPE_TMP}" <<EOF
{
  "disk": "${DISK}",
  "filesystem": "${FILESYSTEM}",
  "bootloader": "${BOOTLOADER}",
  "composeFsBackend": ${COMPOSEFS_BACKEND},
  "image": "${IMAGE_SRC}",
  "hostname": "krytis-e2e",
  "encryption": ${ENCRYPTION_JSON}
}
EOF

echo "Mounting scratch disk (/dev/vdb) over /var/tmp..."
$SSH 'sudo bash -c "
    mkfs.ext4 -F /dev/vdb >/dev/null
    umount /var/tmp 2>/dev/null || true
    mount /dev/vdb /var/tmp
    echo \"/var/tmp is now disk-backed on /dev/vdb\"
"'

$SCP "${RECIPE_TMP}" liveuser@127.0.0.1:/tmp/plain-recipe.json
$SCP "${SCRIPT_DIR}/fisherman-install.sh" liveuser@127.0.0.1:/tmp/fisherman-install.sh
$SSH "chmod +x /tmp/fisherman-install.sh && sudo /tmp/fisherman-install.sh /tmp/plain-recipe.json"

echo "Patching BLS entries to add serial console..."
$SSH "sudo bash -c \"
    set -euo pipefail
    BOOT_PART=\\\"/dev/vda1\\\"
    TMP=\\\$(mktemp -d)
    trap \\\"umount \\\$TMP 2>/dev/null || true; rmdir \\\$TMP\\\" EXIT
    mount \\\"\\\$BOOT_PART\\\" \\\$TMP
    COUNT=0
    for entry in \\\$TMP/loader/entries/*.conf \\\$TMP/EFI/loader/entries/*.conf; do
        [[ -f \\\"\\\$entry\\\" ]] || continue
        if grep -q \\\"^options \\\" \\\"\\\$entry\\\" && ! grep -q \\\"console=tty0\\\" \\\"\\\$entry\\\"; then
            sed -i \\\"s|^options .*|& console=tty0 console=ttyS0 rd.info systemd.journald.forward_to_console=yes|\\\" \\\"\\\$entry\\\"
            COUNT=\\\$((COUNT+1))
        fi
    done
    echo \\\"BLS patch: \\\$COUNT entries updated\\\"
\""

echo "Install complete. Shutting down live QEMU..."
e2e_monitor "${MONITOR_LIVE}" system_powerdown
sleep 5
e2e_monitor "${MONITOR_LIVE}" quit
```

Note: krytis's boot layout is always the 2-partition systemd-boot layout (per fisherman's `PartitionSystemdBoot`, confirmed in this session's earlier work on `tuna-os/fisherman#72`/`projectbluefin/fisherman#19`) — the source script's 3-partition GRUB fallback (`if ls /dev/vda3 >/dev/null 2>&1; then BOOT_PART="/dev/vda2"`) is dropped; `BOOT_PART` is always `/dev/vda1`.

- [ ] **Step 2: Write the `iso-run-install` mise task**

The source `justfile:plain-install-qemu` recipe was a thin one-line wrapper (`./scripts/plain-install-qemu.sh "{{target}}" "{{plain-qemu-ssh-port}}" "{{plain-qemu-monitor-live}}" "{{fisher_repo}}"`) — port it as a thin task with the same shape, minus the now-dropped `fisher_repo` arg and `target` (krytis has no per-target `payload_ref` file anymore — pass it as a flag instead):

```bash
#!/usr/bin/env bash
#MISE description="Install krytis via fisherman inside the booted live QEMU guest"
#USAGE flag "--ssh-port <port>" default="10222" help="Guest SSH port (must match iso-boot-live's --ssh-port)"
#USAGE flag "--monitor <path>" default="/tmp/krytis-e2e-live.mon" help="Live VM's QEMU monitor socket (must match iso-boot-live's --monitor)"
#USAGE flag "--payload-ref <ref>" help="Payload image ref to install; defaults to PAYLOAD_REF env var"

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAYLOAD_REF="${usage_payload_ref:-${PAYLOAD_REF:?PAYLOAD_REF must be set via --payload-ref or env}}"
exec "${REPO_ROOT}/scripts/iso-install-fisherman.sh" \
    "${usage_ssh_port:-10222}" "${usage_monitor:-/tmp/krytis-e2e-live.mon}" "${PAYLOAD_REF}"
```

- [ ] **Step 3: Verify both scripts parse as valid bash**

Run: `bash -n /home/lily/Projects/krytis/scripts/iso-install-fisherman.sh && bash -n /home/lily/Projects/krytis/mise/tasks/iso-run-install`
Expected: no output, exit 0 for both.

- [ ] **Step 4: Commit**

```bash
cd /home/lily/Projects/krytis
chmod +x scripts/iso-install-fisherman.sh mise/tasks/iso-run-install
git add scripts/iso-install-fisherman.sh mise/tasks/iso-run-install
git commit -m "feat(iso): add iso-install-fisherman.sh and iso-run-install task, composefs-only"
```

---

### Task 11: New mise task `iso-boot-installed`

**Files:**
- Create: `mise/tasks/iso-boot-installed`

**Interfaces:**
- Consumes: `scripts/e2e-lib.sh` (Task 7), the disk Task 10 installed onto, optionally `OVMF_VARS_SECURE`/`SECURE_BOOT` env vars for signed-boot enforcement.
- Produces: a second daemonized QEMU booting the installed disk.

- [ ] **Step 1: Write the task**

Ports `dakota-iso justfile:plain-boot-qemu-installed` (lines 1159-1256) — this is the phase that exercises Secure Boot enforcement (`MACHINE_ARGS="q35,smm=on"` + `-global driver=cfi.pflash01,property=secure,value=on"`, both required together per the source's own comment: "smm=on protects the varstore from the guest; the pflash `secure` property is what makes the firmware honour that protection. Omitting either leaves the varstore writable, so nothing is really enforced."). Krytis's own `scripts/ovmf-paths.sh` (confirmed already present and NOT part of dakota-iso, per issue #519's audit) already resolves the secboot-vs-plain OVMF_CODE search — reuse it instead of duplicating the hardcoded path list dakota-iso's recipe carried:

```bash
#!/usr/bin/env bash
#MISE description="Boot the installed krytis disk under QEMU, with optional Secure Boot enforcement"
#USAGE flag "--disk <path>" default="/tmp/krytis-e2e-install.img" help="Installed disk image (must match iso-boot-live's --disk)"
#USAGE flag "--monitor-live <path>" default="/tmp/krytis-e2e-live.mon" help="Live VM's monitor socket, to wait for disk release"
#USAGE flag "--monitor <path>" default="/tmp/krytis-e2e-installed.mon" help="QEMU monitor unix socket for THIS VM"
#USAGE flag "--serial-log <path>" default="/tmp/krytis-e2e-installed.log" help="QEMU serial console log path"
#USAGE flag "--mem <mib>" default="4096" help="Guest RAM in MiB"
#USAGE flag "--smp <n>" default="2" help="Guest vCPU count"
#USAGE flag "--secure" help="Enforce Secure Boot (requires OVMF_VARS_SECURE env var naming an enrolled varstore)"

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/scripts/e2e-lib.sh"
source "${REPO_ROOT}/scripts/ovmf-paths.sh"

QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
[[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

DISK="${usage_disk:-/tmp/krytis-e2e-install.img}"
MONITOR_LIVE="${usage_monitor_live:-/tmp/krytis-e2e-live.mon}"
MONITOR="${usage_monitor:-/tmp/krytis-e2e-installed.mon}"
SERIAL="${usage_serial_log:-/tmp/krytis-e2e-installed.log}"
MEM="${usage_mem:-4096}"
SMP="${usage_smp:-2}"
SECURE_BOOT=$([[ "${usage_secure:-}" == "true" ]] && echo 1 || echo 0)

VARS_SCRATCH="/tmp/krytis-e2e-installed-vars.fd"
if [[ "${SECURE_BOOT}" == "1" ]]; then
    OVMF_CODE=$(ovmf_code_secboot) || { echo "SECURE_BOOT requested but no secboot OVMF code image found" >&2; exit 1; }
    [[ -n "${OVMF_VARS_SECURE:-}" ]] || { echo "--secure requires OVMF_VARS_SECURE env var (mise run generate-ovmf-vars)" >&2; exit 1; }
    [[ -f "${OVMF_VARS_SECURE}" ]] || { echo "OVMF_VARS_SECURE=${OVMF_VARS_SECURE} not found" >&2; exit 1; }
    cp "${OVMF_VARS_SECURE}" "${VARS_SCRATCH}"
else
    OVMF_CODE=$(ovmf_code_plain) || { echo "OVMF firmware not found" >&2; exit 1; }
    OVMF_VARS_TEMPLATE=$(ovmf_vars_pristine) || { echo "OVMF vars template not found" >&2; exit 1; }
    cp "${OVMF_VARS_TEMPLATE}" "${VARS_SCRATCH}"
fi

rm -f "${MONITOR}" "${SERIAL}" "${MONITOR}.pid"
for i in $(seq 1 20); do
    [[ -S "${MONITOR_LIVE}" ]] || break
    sleep 2
done

QEMU_ACCEL="-accel kvm"; QEMU_PREFIX=""
if ! test -r /dev/kvm 2>/dev/null; then
    sudo test -r /dev/kvm 2>/dev/null && QEMU_PREFIX="sudo" || QEMU_ACCEL="-accel tcg,thread=multi"
fi
CPU_FLAG="-cpu host"
[[ "$QEMU_ACCEL" =~ tcg ]] && CPU_FLAG="-cpu qemu64"

MACHINE_ARGS="q35"
FLASH_SECURE_ARGS=()
if [[ "${SECURE_BOOT}" == "1" ]]; then
    MACHINE_ARGS="q35,smm=on"
    FLASH_SECURE_ARGS=(-global driver=cfi.pflash01,property=secure,value=on)
    echo "Secure Boot enforcement ON (machine=${MACHINE_ARGS}, code=${OVMF_CODE})"
fi

echo "Booting installed disk: ${DISK} (mem=${MEM} MiB)"
$QEMU_PREFIX "$QEMU" \
    -machine "${MACHINE_ARGS}" $CPU_FLAG -m "${MEM}" -smp "${SMP}" $QEMU_ACCEL \
    "${FLASH_SECURE_ARGS[@]}" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${VARS_SCRATCH}" \
    -drive "if=none,id=disk,file=${DISK},format=raw,cache=unsafe" -device virtio-blk-pci,drive=disk \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -monitor "unix:${MONITOR},server,nowait" \
    -serial "file:${SERIAL}" \
    -display none \
    -daemonize -pidfile "${MONITOR}.pid"
echo "Installed QEMU started (monitor: ${MONITOR})"

for i in $(seq 1 15); do
    [[ -S "${MONITOR}" ]] && exit 0
    if [[ $i -eq 15 ]]; then
        echo "ERROR: installed QEMU never opened its monitor socket" >&2
        e2e_qemu_stop "${MONITOR}" "installed VM"
        exit 1
    fi
    sleep 2
done
```

**Note:** this assumes `scripts/ovmf-paths.sh` exposes `ovmf_code_secboot`/`ovmf_code_plain`/`ovmf_vars_pristine` as sourceable shell functions (mirroring how `mise/tasks/generate-ovmf-vars` already calls `ovmf_vars_pristine`, per that task's own `. scripts/ovmf-paths.sh` + `OVMF_VARS_SRC=$(ovmf_vars_pristine)` line) — read `scripts/ovmf-paths.sh` in full before this step to confirm the exact function names and adjust the calls above if they differ from this assumption.

- [ ] **Step 2: Verify flag parsing**

Run: `chmod +x /home/lily/Projects/krytis/mise/tasks/iso-boot-installed && cd /home/lily/Projects/krytis && mise run iso-boot-installed --help`
Expected: lists all 7 flags.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add mise/tasks/iso-boot-installed
git commit -m "feat(iso): add iso-boot-installed mise task, reusing scripts/ovmf-paths.sh"
```

---

### Task 12: New mise task `iso-verify-boot`

**Files:**
- Create: `mise/tasks/iso-verify-boot`

**Interfaces:**
- Consumes: `scripts/e2e-lib.sh` (Task 7), `scripts/show-screenshot.sh` (Task 8), the serial log + monitor socket from Task 11.
- Produces: exit 0 (PASS) / 1 (FAIL) / 2 (INCONCLUSIVE) — same three-way verdict contract as the source recipe.

- [ ] **Step 1: Write the task**

Ports `dakota-iso justfile:plain-verify-qemu` (lines 1268-1326) verbatim in logic, only updating the `show-screenshot.sh` path (Task 8 renamed it from `dakota/src/show-screenshot.sh` to `scripts/show-screenshot.sh`) and converting `just` var interpolation to `#USAGE` flags:

```bash
#!/usr/bin/env bash
#MISE description="Verify the installed krytis system reaches its target boot state, or assert Secure Boot rejection"
#USAGE flag "--monitor <path>" default="/tmp/krytis-e2e-installed.mon" help="Installed VM's monitor socket"
#USAGE flag "--serial-log <path>" default="/tmp/krytis-e2e-installed.log" help="Installed VM's serial console log"
#USAGE flag "--expect-fail" help="Invert the verdict: pass only when the serial log shows Secure Boot REJECTING the boot"

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/scripts/e2e-lib.sh"

SERIAL="${usage_serial_log:-/tmp/krytis-e2e-installed.log}"
MONITOR="${usage_monitor:-/tmp/krytis-e2e-installed.mon}"
SCREENSHOT="/tmp/krytis-e2e-screenshot-final.ppm"
EXPECT_FAIL=$([[ "${usage_expect_fail:-}" == "true" ]] && echo 1 || echo 0)

if [[ "${EXPECT_FAIL}" == "1" ]]; then
    echo "EXPECT_FAIL — waiting for a Secure Boot rejection on the serial console (up to 5 min)..."
    DEADLINE=$((SECONDS + 300))
    while [[ $SECONDS -lt $DEADLINE ]]; do
        LOG=$(cat "$SERIAL" 2>/dev/null || true)
        if echo "$LOG" | grep -qE '[Aa]ccess [Dd]enied|Security Violation'; then
            echo "Installed system was REJECTED by Secure Boot, as expected"
            e2e_monitor "$MONITOR" quit
            exit 0
        fi
        if echo "$LOG" | grep -q "Reached target.*Graphical\|Reached target.*Multi-User\|login:"; then
            echo "EXPECT_FAIL but the installed system booted — enforcement did not reject it" >&2
            e2e_monitor "$MONITOR" quit
            exit 1
        fi
        sleep 5
    done
    echo "INCONCLUSIVE: the guest never booted and never logged a rejection" >&2
    cat "$SERIAL" 2>/dev/null | tail -30 >&2
    e2e_monitor "$MONITOR" quit
    exit 2
fi

echo "Waiting for installed system to reach Graphical Interface (up to 5 min)..."
DEADLINE=$((SECONDS + 300))
while [[ $SECONDS -lt $DEADLINE ]]; do
    LOG=$(cat "$SERIAL" 2>/dev/null || true)
    if echo "$LOG" | grep -q "Reached target.*Graphical\|Reached target.*Multi-User\|login:"; then
        echo "Installed system boot verified"
        e2e_monitor "$MONITOR" "screendump $SCREENSHOT"
        bash "${REPO_ROOT}/scripts/show-screenshot.sh" "$SCREENSHOT" "Installed system" 2>/dev/null || true
        e2e_monitor "$MONITOR" quit
        exit 0
    fi
    if echo "$LOG" | grep -q "Emergency mode\|You are in emergency mode\|Kernel panic"; then
        echo "Emergency shell or kernel panic detected" >&2
        cat "$SERIAL" 2>/dev/null | tail -30 >&2
        exit 1
    fi
    sleep 5
done
echo "Timeout: installed system did not reach graphical target in 5 minutes" >&2
cat "$SERIAL" 2>/dev/null | tail -30 >&2
e2e_monitor "$MONITOR" "screendump $SCREENSHOT"
exit 1
```

- [ ] **Step 2: Verify flag parsing**

Run: `chmod +x /home/lily/Projects/krytis/mise/tasks/iso-verify-boot && cd /home/lily/Projects/krytis && mise run iso-verify-boot --help`
Expected: lists both flags.

- [ ] **Step 3: Commit**

```bash
cd /home/lily/Projects/krytis
git add mise/tasks/iso-verify-boot
git commit -m "feat(iso): add iso-verify-boot mise task"
```

---

### Task 13: New mise task `iso-e2e-test`, orchestrating the 4-phase chain

**Files:**
- Create: `mise/tasks/iso-e2e-test`

**Interfaces:**
- Consumes: `mise/tasks/{iso-boot-live,iso-run-install,iso-boot-installed,iso-verify-boot}` (Tasks 9-12), `scripts/e2e-lib.sh` (Task 7).
- Produces: exit 0/1/2, same three-way verdict as `sealed-test-qemu`; on `--install-only`, leaves the installed disk in place and prints its path.

- [ ] **Step 1: Write the task**

Ports `dakota-iso justfile:sealed-test-qemu` (lines 1360-1449), replacing the four `just ... plain-boot-qemu-live`/`plain-install-qemu`/`plain-boot-qemu-installed`/`plain-verify-qemu` calls with direct invocations of Tasks 9-12:

```bash
#!/usr/bin/env bash
#MISE description="Full install+boot E2E test: live ISO -> fisherman install -> boot installed disk -> verify"
#USAGE flag "--payload-ref <ref>" help="Payload image ref to install; defaults to PAYLOAD_REF env var"
#USAGE flag "--secure" help="Enforce Secure Boot on the installed-disk boot (requires OVMF_VARS_SECURE env var)"
#USAGE flag "--expect-fail" help="Assert the installed system is REJECTED (requires --secure)"
#USAGE flag "--install-only" help="Stop after install; print the disk path and exit, leaving verdict to the caller"
#USAGE flag "--ssh-port <port>" default="10222" help="Guest SSH port"

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${REPO_ROOT}/scripts/e2e-lib.sh"

SECURE=$([[ "${usage_secure:-}" == "true" ]] && echo 1 || echo 0)
EXPECT_FAIL=$([[ "${usage_expect_fail:-}" == "true" ]] && echo 1 || echo 0)
INSTALL_ONLY=$([[ "${usage_install_only:-}" == "true" ]] && echo 1 || echo 0)
SSH_PORT="${usage_ssh_port:-10222}"
DISK="/tmp/krytis-e2e-install.img"
MONITOR_LIVE="/tmp/krytis-e2e-live.mon"
MONITOR_INSTALLED="/tmp/krytis-e2e-installed.mon"

if [[ "${EXPECT_FAIL}" == "1" && "${SECURE}" != "1" ]]; then
    echo "--expect-fail requires --secure — with nothing enforcing there is nothing to reject" >&2
    exit 1
fi
if [[ "${INSTALL_ONLY}" == "1" && "${EXPECT_FAIL}" == "1" ]]; then
    echo "--expect-fail is incompatible with --install-only — this mode produces no boot verdict to invert" >&2
    exit 1
fi

echo "=== [0/4] Clearing any leftover E2E VMs ==="
e2e_qemu_stop "${MONITOR_LIVE}" "stale live VM"
e2e_qemu_stop "${MONITOR_INSTALLED}" "stale installed VM"
e2e_port_free "${SSH_PORT}" || { echo "port ${SSH_PORT} is still in use after teardown" >&2; exit 1; }
e2e_on_exit "e2e_qemu_stop '${MONITOR_LIVE}' 'live VM'"
e2e_on_exit "e2e_qemu_stop '${MONITOR_INSTALLED}' 'installed VM'"

echo "=== [1/4] Booting live ISO with PLAIN OVMF (the live ISO is unsigned by design) ==="
"${REPO_ROOT}/mise/tasks/iso-boot-live" --disk "${DISK}" --monitor "${MONITOR_LIVE}" --ssh-port "${SSH_PORT}"

echo "=== [2/4] Installing (payload=${usage_payload_ref:-${PAYLOAD_REF:-unset}}) ==="
"${REPO_ROOT}/mise/tasks/iso-run-install" --ssh-port "${SSH_PORT}" --monitor "${MONITOR_LIVE}" \
    ${usage_payload_ref:+--payload-ref "${usage_payload_ref}"}
e2e_qemu_stop "${MONITOR_LIVE}" "phase 1 live VM"

if [[ "${INSTALL_ONLY}" == "1" ]]; then
    echo "=== --install-only — stopping after install; installed disk left in place ==="
    echo "${DISK}"
    exit 0
fi

echo "=== [3/4] Booting the installed disk (secure=${SECURE}) ==="
"${REPO_ROOT}/mise/tasks/iso-boot-installed" --disk "${DISK}" --monitor-live "${MONITOR_LIVE}" \
    --monitor "${MONITOR_INSTALLED}" ${SECURE:+--secure}

echo "=== [4/4] Verdict (expect-fail=${EXPECT_FAIL}) ==="
set +e
"${REPO_ROOT}/mise/tasks/iso-verify-boot" --monitor "${MONITOR_INSTALLED}" ${EXPECT_FAIL:+--expect-fail}
RC=$?
set -e
case "$RC" in
    0) echo "iso-e2e-test: PASS" ;;
    2) echo "iso-e2e-test: INCONCLUSIVE" >&2 ;;
    *) echo "iso-e2e-test: FAIL (exit ${RC})" >&2 ;;
esac
exit "$RC"
```

- [ ] **Step 2: Rewire `mise/tasks/iso-install-test` and `mise/tasks/luks-install-test`**

Read both tasks in full first (already partially read during investigation — the `DAKOTA_ISO_DIR` resolution block and the `just sealed-test-qemu krytis` call site). Replace the `DAKOTA_ISO_DIR` resolution + `just` invocation in each with a direct call to `./mise/tasks/iso-e2e-test`, forwarding whatever flags each task already computed (`--payload-ref`, `--install-only` for the sealed-verdict-deferred-to-boot-test case, `LUKS_PASSPHRASE` still passed as an env var since `iso-run-install` → `iso-install-fisherman.sh` already reads it that way, unchanged from the source). Keep each task's own post-`sealed-test-qemu` logic (the sealed-image verdict deferring to `mise run boot-test --reuse-disk`) exactly as-is — only the call into the now-native `iso-e2e-test` changes.

- [ ] **Step 3: Verify flag parsing**

Run: `chmod +x /home/lily/Projects/krytis/mise/tasks/iso-e2e-test && cd /home/lily/Projects/krytis && mise run iso-e2e-test --help`
Expected: lists all 5 flags.

- [ ] **Step 4: Commit**

```bash
cd /home/lily/Projects/krytis
git add mise/tasks/iso-e2e-test mise/tasks/iso-install-test mise/tasks/luks-install-test
git commit -m "feat(iso): add iso-e2e-test orchestrator, rewire install-test tasks off dakota-iso"
```

---

### Task 14: Test-path cutover and integration verification

- [ ] **Step 1: Confirm zero remaining `DAKOTA_ISO_DIR`/`just`/`dakota-iso` references**

Run: `cd /home/lily/Projects/krytis && grep -rl "DAKOTA_ISO_DIR\|dakota-iso" mise/tasks/build-iso mise/tasks/iso-install-test mise/tasks/luks-install-test mise/tasks/verify-iso-payload`
Expected: no matches (empty output). If `verify-iso-payload` references `dakota-iso` only in a comment (per issue #519's finding — "references the PAYLOAD_SEALED env knob handed to dakota-iso"), update that comment; it has no functional dependency to remove.

- [ ] **Step 2: Run the full build-then-test cycle**

Run: `cd /home/lily/Projects/krytis && mise run build-iso --sealed && mise run luks-install-test`
Expected: both complete successfully with `iso-e2e-test: PASS` (or the sealed-image path's own deferred-verdict success message), using zero `just`/sibling-checkout invocations anywhere in the process tree.

- [ ] **Step 3: Commit any fixups found during the live run**

```bash
cd /home/lily/Projects/krytis
git add -A
git commit -m "fix(iso): test-path integration fixes found during end-to-end verification"
```
(Only if Step 2 required fixes.)

- [ ] **Step 4: Update dependent docs**

Edit `docs/skills/mise.md`, `docs/skills/bootc-vm.md`, `docs/skills/secure-boot.md`, `docs/skills/pam.md`, and `docs/design/secure-boot-testing.md`'s trap T-10 to remove the now-obsolete `DAKOTA_ISO_DIR` sibling-checkout explanations and replace them with a pointer to the native `mise/tasks/iso-*` tasks this plan added. Each doc's existing prose (already fully quoted in issue #519's investigation) names the exact lines to update.

```bash
cd /home/lily/Projects/krytis
git add docs/skills/mise.md docs/skills/bootc-vm.md docs/skills/secure-boot.md docs/skills/pam.md docs/design/secure-boot-testing.md
git commit -m "docs: update installer-pipeline docs for the native ISO build/test tasks"
```

---

## Phase 3: Fork demotion (documentation only — do not execute without explicit, separate confirmation)

This phase is intentionally **not broken into TDD steps** — it is a one-time, irreversible-without-a-backup git history operation on a fork outside this repo, gated by AGENTS.md's Merge/Design Gates. Record it here as a checklist for the human to execute (or explicitly direct an agent to execute) once Phases 1-2 are merged and verified in production use for a reasonable burn-in period.

- [ ] Confirm `mise run build-iso` and `mise run iso-install-test`/`luks-install-test` have been green in real use (not just this plan's own verification pass) for long enough to trust the port has no latent gaps the initial verification missed.
- [ ] Back up `kitten-lily/dakota-iso`'s current `main` (e.g. tag it `pre-hard-fork-krytis-commits` or push a `krytis-archive` branch) before any reset — the 4 commits (`a5780cf`, `ab94dcf5`, `8ee95564`, `3d32f848`) must remain recoverable even after `main` is reset.
- [ ] With explicit user confirmation: `git -C <dakota-iso-checkout> reset --hard 45cd7f22 && git -C <dakota-iso-checkout> push --force-with-lease origin main` (reset to the shared ancestor with upstream).
- [ ] Add a `dakota-iso` entry to `docs/upstreams.yml`, matching the schema `docs/skills/upstream-sync.md` documents — fork, upstream, branch (confirm which branch `projectbluefin/dakota-iso` treats as primary — likely `main`, verify before writing), `local_path: dakota-iso`, `skill_file: docs/skills/dakota-iso.md`, `last_checked_sha` = the post-reset HEAD.
- [ ] Create `docs/skills/dakota-iso.md` following `docs/skills/dakota.md`'s template shape (per issue #519's recommendation over `zirconium-hawaii.md`'s richer shape).
- [ ] Run the `upstream-lessons` skill's normal workflow once to confirm `mise upstream-sync dakota-iso` succeeds cleanly against the now-pure-mirror fork.

---

## Self-Review Notes

- **Spec coverage:** every INCLUDE item from issue #519's two BOM tables (13 build-path items, 9 test-path items) has a corresponding task above. Every EXCLUDE item is explicitly named as dropped, with the same reasoning already verified in the investigation (not re-derived here). Fork-demotion mechanics match the issue's recommended path exactly.
- **Placeholder scan:** every code step contains complete, real, transformed code — not a description of what to write. Two spots are flagged as needing a live-source check immediately before finalizing (Task 9's `KRYTIS_LIVE_READY` marker string, Task 11's `scripts/ovmf-paths.sh` function names) rather than guessed — both are pre-existing krytis files not fully read during this planning session, called out explicitly so the implementer verifies rather than assumes, which is the same discipline the FIDO2 plan (`docs/plans/2026-08-06-fido2-installer-enrollment.md`) used for its own unresolved-detail spots.
- **Type/interface consistency:** every mise task's flag names and defaults are used consistently across the tasks that call each other — `iso-e2e-test` invokes `iso-boot-live`/`iso-run-install`/`iso-boot-installed`/`iso-verify-boot` with exactly the `--disk`/`--monitor`/`--monitor-live`/`--ssh-port` flag names and default paths each of those tasks itself declares, so the chain wires together without a name mismatch.
