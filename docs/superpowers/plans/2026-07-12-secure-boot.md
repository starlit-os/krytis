# Secure Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement EFI secure boot for krytis — signed UKI, signed systemd-boot, and firmware key enrollment — using the existing `Containerfile` expanded with a conditional signing step.

**Architecture:** The existing `mise build` pipeline produces `localhost/krytis-input:latest` (BST) → `localhost/krytis:latest` (lint via `Containerfile`). The `Containerfile` is expanded with a `SEAL_SECURE_BOOT` build arg: when `true`, `bootc container ukify` builds and signs the UKI and `sbsign` signs `systemd-boot`, all inside the image with keys passed via podman `--secret` mounts. Keys (PK, KEK, db — sbctl model, RSA 4096) are retrieved from Proton Pass via `fnox get`. Firmware enrollment uses systemd-boot's native `loader/keys/` mechanism, automated by bootc's `/usr/lib/bootc/install/secureboot-keys`.

**Tech Stack:** BuildStream 2, bootc v1.16.3, systemd-ukify, sbsigntools, efitools, fnox + pass-cli (Proton Pass), podman, OVMF (QEMU testing)

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only
- All maintenance tasks must be `mise` tasks — no loose shell commands
- `mise lint` must pass before opening a PR
- The image must boot — use `mise boot-test` / `mise boot-vm` for verification
- Agents MUST NOT push directly to `main` — all changes via PR from a feature branch
- Worktree + branch required before touching files (AGENTS.md convention)
- Skill file updates must be in the same commit as the change that produced the learning (Self-Improvement Loop)
- 3-key model: PK, KEK, db (sbctl model, RSA 4096) — db signs all EFI binaries
- `files/boot-keys/` and `files/secureboot-keys/` are gitignored — keys and .auth files never committed
- This plan touches the boot path and LUKS — Breakage Gate (#312) must be cleared before full boot chain verification
- `--allow-missing-verity` must be passed to `bootc container ukify` — the Containerfile build filesystem does not support fs-verity
- systemd-boot binary lives at `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` in the image — `/boot` is empty (wiped by `stack.bst`). Sign in place at the source path, not at `/boot/EFI/systemd/`.
- bootc discovers UKIs at `/boot/EFI/Linux/` inside the composefs image tree. The Containerfile `RUN` step adds the UKI there, and bootc's `Type2Entry::load_all` finds it. bootc validates the UKI's `composefs=` cmdline matches the deployment ID.
- `loader.conf` is written by `bootctl install` at install time — a shipped `/boot/loader/loader.conf` gets wiped. `secure-boot-enroll` must be configured via a bootc install hook or a `/usr/lib/bootc/` mechanism, not a static file in `/boot/`.

## Prerequisites (before starting any task)

- [ ] Read `AGENTS.md`, `docs/SKILL.md`, `docs/skills/bst.md`, `docs/skills/workflow.md`
- [ ] Read `docs/plan/secure-boot-uki.md` (the design notes / architecture decisions)
- [ ] Create a worktree: `git worktree add -b <branch> <base>/feat/gh16-secure-boot`
- [ ] `mise trust` in the worktree
- [ ] `fnox` and `pass-cli` installed on the developer's machine
- [ ] `pass-cli login` completed (browser-based, one time)
- [ ] Proton Pass vault item "Secure Boot Keys" with fields: `PK.key`, `PK.crt`, `KEK.key`, `KEK.crt`, `db.key`, `db.crt`
- [ ] Existing sbctl-generated keys (PK, KEK, db — RSA 4096) stored in Proton Pass

---

## Task 1: Add `generate-keys` mise task (#31)

**Files:**
- Create: `mise/tasks/generate-keys`

**Interfaces:**
- Produces: `files/boot-keys/{PK,KEK,db}.{key,crt}` + `files/boot-keys/extra-db/` directory
- Consumes: nothing (fallback path; #311 is the preferred path for existing keys)

**Issue:** #31

- [ ] **Step 1: Create the `generate-keys` mise task**

Create `mise/tasks/generate-keys`:

```bash
#!/usr/bin/env bash
#MISE description="Generate secure boot signing keys (fallback — use pull-keys for existing keys)"

set -euo pipefail

mkdir -p files/boot-keys/extra-db

VENDOR="${VENDOR:-Krytis}"

for f in PK KEK db; do
    keyfile="files/boot-keys/${f}.key"
    crtfile="files/boot-keys/${f}.crt"
    if [ ! -f "$keyfile" ] && [ ! -f "$crtfile" ]; then
        echo "==> Generating ${f} key pair..."
        openssl req -new -x509 -newkey rsa:4096 \
            -subj "/CN=${VENDOR} ${f} key/" \
            -keyout "$keyfile" -out "$crtfile" \
            -days 3650 -nodes -sha256
        chmod 600 "$keyfile"
        chmod 644 "$crtfile"
    else
        echo "==> ${f} key pair already exists, skipping."
    fi
done

echo "==> Keys ready in files/boot-keys/"
```

- [ ] **Step 2: Verify the task is listed**

Run: `mise tasks`
Expected: `generate-keys` appears with its description

- [ ] **Step 3: Test idempotency — run on clean checkout**

```bash
rm -rf files/boot-keys
mise run generate-keys
ls -la files/boot-keys/{PK,KEK,db}.{key,crt}
```
Expected: all 6 files exist, `extra-db/` exists, `.key` files mode 600, `.crt` files mode 644

- [ ] **Step 4: Test idempotency — run again (should be no-op)**

```bash
mise run generate-keys
```
Expected: prints "already exists, skipping" for each key, exits 0, no files modified

- [ ] **Step 5: Validate generated keys**

```bash
for key in PK KEK db; do
    openssl rsa -check -in "files/boot-keys/${key}.key" -noout
    openssl x509 -noout -in "files/boot-keys/${key}.crt"
done
```
Expected: all pass without error

- [ ] **Step 6: Commit**

```bash
git add mise/tasks/generate-keys
git commit -m "feat(mise): add generate-keys task for secure boot keys

Idempotent task generating PK, KEK, db key pairs (RSA 4096, matching
sbctl) into files/boot-keys/ (gitignored). Skips generation if keys
already exist — reuse existing keys via pull-keys (#311) instead.

Closes #31

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 2: Add `pull-keys` mise task + `fnox.toml` (#311)

**Files:**
- Create: `fnox.toml`
- Create: `mise/tasks/pull-keys`

**Interfaces:**
- Consumes: Proton Pass vault item "Secure Boot Keys" with fields `PK.key`, `PK.crt`, `KEK.key`, `KEK.crt`, `db.key`, `db.crt`
- Produces: `files/boot-keys/{PK,KEK,db}.{key,crt}` + `files/boot-keys/extra-db/` directory (same as #31)

**Issue:** #311
**Blocked by:** #31 (Task 1)

- [ ] **Step 1: Create `fnox.toml` at repo root**

Create `fnox.toml`:

```toml
[providers.protonpass]
type = "proton-pass"
vault = "Krytis"
agent_reason = "krytis secure boot key retrieval"

[secrets]
PK_KEY  = { provider = "protonpass", value = "Secure Boot Keys/PK.key" }
PK_CRT  = { provider = "protonpass", value = "Secure Boot Keys/PK.crt" }
KEK_KEY = { provider = "protonpass", value = "Secure Boot Keys/KEK.key" }
KEK_CRT = { provider = "protonpass", value = "Secure Boot Keys/KEK.crt" }
DB_KEY  = { provider = "protonpass", value = "Secure Boot Keys/db.key" }
DB_CRT  = { provider = "protonpass", value = "Secure Boot Keys/db.crt" }
```

Note: adjust `vault = "Krytis"` and the item name `"Secure Boot Keys"` to match the actual Proton Pass vault and item names.

- [ ] **Step 2: Create the `pull-keys` mise task**

Create `mise/tasks/pull-keys`:

```bash
#!/usr/bin/env bash
#MISE description="Pull secure boot keys from Proton Pass into files/boot-keys/"

set -euo pipefail

mkdir -p files/boot-keys/extra-db

declare -A KEYS=(
    [PK_KEY]=PK.key    [PK_CRT]=PK.crt
    [KEK_KEY]=KEK.key  [KEK_CRT]=KEK.crt
    [DB_KEY]=db.key    [DB_CRT]=db.crt
)

for secret in "${!KEYS[@]}"; do
    dest="files/boot-keys/${KEYS[$secret]}"
    echo "==> Pulling ${secret} → ${dest}..."
    fnox get "$secret" > "$dest"
done

chmod 600 files/boot-keys/*.key
chmod 644 files/boot-keys/*.crt

echo "==> Validating keys..."
for key in PK KEK db; do
    openssl rsa -check -in "files/boot-keys/${key}.key" -noout 2>/dev/null || \
        openssl ec -check -in "files/boot-keys/${key}.key" -noout 2>/dev/null || \
        { echo "ERROR: ${key}.key failed validation"; exit 1; }
    openssl x509 -noout -in "files/boot-keys/${key}.crt" || \
        { echo "ERROR: ${key}.crt failed validation"; exit 1; }
done

echo "==> Keys pulled and validated in files/boot-keys/"
```

- [ ] **Step 3: Verify the task is listed**

Run: `mise tasks`
Expected: `pull-keys` appears with its description

- [ ] **Step 4: Test pulling keys**

Prerequisites: `pass-cli login` completed, Proton Pass vault item populated.

```bash
rm -rf files/boot-keys
mise run pull-keys
ls -la files/boot-keys/{PK,KEK,db}.{key,crt}
```
Expected: all 6 files exist, validation passes, modes correct

- [ ] **Step 5: Verify pulled keys match sbctl-generated keys**

```bash
for key in PK KEK db; do
    openssl x509 -in "files/boot-keys/${key}.crt" -noout -fingerprint -sha256
done
```
Expected: fingerprints match the developer's existing sbctl keys

- [ ] **Step 6: Commit**

```bash
git add fnox.toml mise/tasks/pull-keys
git commit -m "feat(mise): add pull-keys task + fnox.toml for Proton Pass key retrieval

Closes #311

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 3: Spike — bootc UKI consumption + fido2-luks/TPM (#312)

**Files:**
- No code changes — investigation and documentation only
- Create: `docs/plan/secure-boot-tpm-analysis.md` (analysis results)

**Interfaces:**
- Consumes: existing `files/bootc-config/30-fido2-luks.toml`, current LUKS/TPM setup, a test sealed image
- Produces: a decision document that gates Tasks 5+ (UKI consumption verified, `--allow-missing-verity` confirmed, `--measure` decision, `systemd-tpm2-*` masking decision, TPM re-enrollment decision)

**Issue:** #312 (Breakage Gate — must be cleared before Tasks 5 and 7)

This task combines two investigations:
1. **Blocker B spike:** Does `bootc install to-disk` actually boot a pre-built UKI from `/boot/EFI/Linux/`? Does the composefs digest in the UKI match what bootc computes at install time?
2. **fido2-luks/TPM:** Does enabling secure boot + UKI break TPM-bound LUKS unlock?

### Part A: UKI consumption spike

- [ ] **Step 1: Build a test sealed image**

First add the secure boot tools to the image dep tree (do Task 4 Steps 1-3 only — create `secure-boot-tools.bst`, add to `stacks/bootc.bst`, validate). Then:

```bash
mise run pull-keys
mise build
# Test the seal step manually (before writing the seal-uki task):
podman build --squash-all -t localhost/krytis:sealed-test \
    --build-arg SEAL_SECURE_BOOT=true \
    --secret id=db_key,src=files/boot-keys/db.key \
    --secret id=db_crt,src=files/boot-keys/db.crt \
    --secret id=kek_key,src=files/boot-keys/kek.key \
    --secret id=kek_crt,src=files/boot-keys/kek.crt \
    --secret id=pk_key,src=files/boot-keys/pk.key \
    --secret id=pk_crt,src=files/boot-keys/pk.crt \
    --build-arg SEAL_SECURE_BOOT=true \
    -f Containerfile .
```

Note: this requires the Containerfile to already have the conditional signing step (Task 5 Step 2). If doing this spike before Task 5, use a temporary Containerfile or run the ukify command manually inside a container:

```bash
# Alternative: run ukify manually inside the image
podman run --rm -it \
    --secret id=db_key,src=files/boot-keys/db.key \
    --secret id=db_crt,src=files/boot-keys/db.crt \
    localhost/krytis:latest bash -c '
        mkdir -p /boot/EFI/Linux
        bootc container ukify --allow-missing-verity -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi
        '
# Commit the container as a new image
podman commit <container-id> localhost/krytis:sealed-test
```

- [ ] **Step 2: Install the sealed image to a test disk (no secure boot yet)**

```bash
# Add --image flag to generate-disk or use podman tag
sudo podman tag localhost/krytis:sealed-test localhost/krytis:latest
mise run generate-disk --disk /tmp/test-uki.raw
mise run boot-vm --disk /tmp/test-uki.raw
```

- [ ] **Step 3: Verify the UKI was used (not vmlinuz)**

In the guest:
```bash
# Check if the system booted via UKI
ls /boot/EFI/Linux/bootc/  # bootc copies UKIs here
bootctl list               # should show the UKI entry
```

Document: did bootc find the UKI at `/boot/EFI/Linux/`? Did it use it instead of vmlinuz? Did the composefs digest match?

- [ ] **Step 4: If the UKI was NOT used — investigate why**

Possible issues:
- `bootc container ukify` computes a different composefs digest than `bootc install`'s `generate_boot_image`
- The UKI at `/boot/EFI/Linux/` is not found by `Type2Entry::load_all` (composefs tree doesn't include it)
- bootc prefers `UsrLibModulesVmlinuz` over Type2 entries

Check bootc install logs for "Failed to get version and boot label from UKI" or "No boot entries!" or "wrong composefs= parameter".

Document the root cause and the fix. This may require adjusting how the UKI is placed (e.g., the composefs digest computation must match, or the UKI must be at a specific path).

### Part B: fido2-luks / TPM analysis

- [ ] **Step 5: Check if current krytis LUKS volumes are TPM-bound**

On a running krytis system:

```bash
for dev in $(lsblk -o NAME,FSTYPE -n | grep crypto_LUKS | awk '{print $1}'); do
    echo "=== /dev/${dev} ==="
    cryptsetup luksDump /dev/${dev} | grep -A5 "Tokens"
    systemd-cryptenroll list /dev/${dev} 2>/dev/null || true
done
```

Document: are any volumes bound to TPM PCRs? Or FIDO2-only? Or passphrase-only?

- [ ] **Step 6: If TPM-bound, identify which PCRs and analyze UKI impact**

```bash
systemd-cryptenroll list /dev/<luks-device>
```

Document which PCRs are used (7 = secure boot policy, 4 = boot manager, 9 = kernel). Analyze: does switching from unsigned to signed UKI change these PCRs?

- [ ] **Step 7: Evaluate `ukify --measure` and `systemd-tpm2-*` masking**

Read travier's `uki.sh` — it uses `--measure` and masks `systemd-tpm2-setup-early.service`, `systemd-tpm2-setup.service`, `systemd-pcrphase.service`, `systemd-pcrproduct.service`. Determine if these are needed for krytis.

- [ ] **Step 8: Write the analysis document**

Create `docs/plan/secure-boot-tpm-analysis.md` with:
- Part A results: does bootc install boot a pre-built UKI? What path? What composefs digest requirement?
- Part B results: TPM-bound or not? PCR impact? Mitigations needed?
- Decisions: `--allow-missing-verity` (yes), `--measure` (yes/no), `systemd-tpm2-*` masking (yes/no), TPM re-enrollment procedure (if needed)
- Whether the plan needs revision based on findings

- [ ] **Step 9: Commit**

```bash
git add docs/plan/secure-boot-tpm-analysis.md
git commit -m "docs(secure-boot): UKI consumption spike + fido2-luks/TPM analysis

Closes #312

[Summary of findings]

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 4: Add secure boot tools to the image dep tree

**Files:**
- Create: `elements/core/secure-boot-tools.bst`
- Modify: `elements/stacks/bootc.bst` (add the new element to depends)

**Interfaces:**
- Produces: a BST element bringing `ukify`, `sbsign`, `cert-to-efi-sig-list`, `sign-efi-sig-list`, and the EFI stub into the runtime image
- Consumes: freedesktop-sdk junction components

**Issue:** Part of #32 (runtime deps)
**Note:** Steps 1-3 of this task are needed before the Task 3 spike. Do them first, then complete Steps 4-6 after the spike.

- [ ] **Step 1: Create the `secure-boot-tools.bst` element**

Create `elements/core/secure-boot-tools.bst`:

```yaml
kind: stack

# Runtime tools for secure boot signing and key enrollment.
# Used by the seal-uki Containerfile step (bootc container ukify + sbsign)
# and by the secureboot-keys BST element (.auth file generation).
depends:
- freedesktop-sdk.bst:components/systemd-ukify.bst    # ukify + EFI stub (linuxx64.efi.stub)
- freedesktop-sdk.bst:components/sbsigntools.bst      # sbsign / sbverify
- freedesktop-sdk.bst:components/efitools.bst         # cert-to-efi-sig-list / sign-efi-sig-list
- freedesktop-sdk.bst:components/efivar.bst           # efivar library (efitools runtime dep)
```

- [ ] **Step 2: Add to `stacks/bootc.bst`**

Modify `elements/stacks/bootc.bst`:

```yaml
depends:
  - freedesktop-sdk.bst:vm/config/useradd-ostree.bst
  - freedesktop-sdk.bst:components/podman.bst
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/skopeo.bst
  - core/bootc.bst
  - core/efibootmgr.bst
  - core/secure-boot-tools.bst
  - config/bootc.bst
```

- [ ] **Step 3: Validate the element graph**

Run: `mise validate`
Expected: passes with no errors

- [ ] **Step 4: Build and verify tools are present**

```bash
mise bst build elements/core/secure-boot-tools.bst
mise bst artifact list-contents elements/core/secure-boot-tools.bst | grep -E "ukify$|sbsign$|cert-to-efi-sig-list$|sign-efi-sig-list$"
```
Expected: all four binaries listed

- [ ] **Step 5: Verify the EFI stub is in the image**

```bash
mise build
podman run --rm localhost/krytis:latest ls /usr/lib/systemd/boot/efi/linuxx64.efi.stub
```
Expected: file exists

If the stub is missing: `systemd-ukify.bst` is a `kind: filter` with `include: [ukify, systemd-license]`. The EFI stub may not be in the `ukify` split — it may be in the main `systemd.bst` split or `systemd-bootctl.bst`. If so, add the appropriate element (e.g., `freedesktop-sdk.bst:components/systemd.bst` or a split that includes `systemd/boot/efi/*.efi.stub`).

- [ ] **Step 6: Commit**

```bash
git add elements/core/secure-boot-tools.bst elements/stacks/bootc.bst
git commit -m "feat(secure-boot): add secure boot tools to image dep tree

Brings systemd-ukify (ukify + EFI stub), sbsigntools (sbsign/sbverify),
and efitools (cert-to-efi-sig-list / sign-efi-sig-list) into the
runtime image.

Part of #32

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 5: Expand `Containerfile` with conditional UKI signing (#32, #33)

**Files:**
- Modify: `Containerfile`
- Create: `mise/tasks/seal-uki`

**Interfaces:**
- Consumes: `localhost/krytis-input:latest` (BST output), `files/boot-keys/{PK,KEK,db}.{key,crt}` (from #31 or #311)
- Produces: `localhost/krytis:sealed` (image with signed UKI at `/boot/EFI/Linux/` and signed `systemd-boot` at `/usr/lib/systemd/boot/efi/`)

**Issues:** #32, #33
**Blocked by:** #31 (Task 1), #311 (Task 2), #312 (Task 3 — Breakage Gate), Task 4 (needs ukify/sbsign in image)

- [ ] **Step 1: Read the #312 analysis**

Read `docs/plan/secure-boot-tpm-analysis.md`. Determine:
- Did the UKI consumption spike succeed? What path did bootc find the UKI at?
- Is `ukify --measure` needed?
- Do any `systemd-tpm2-*` services need masking?

If the spike found that the UKI is NOT consumed by bootc, revise this task based on the spike findings before proceeding.

- [ ] **Step 2: Expand the `Containerfile`**

Modify `Containerfile`:

```dockerfile
FROM localhost/krytis-input:latest

# Run bootc container lint (existing)
RUN bootc container lint

# Conditional secure boot sealing — gated by build arg.
# mise build (unsigned) skips this; mise run seal-uki enables it.
ARG SEAL_SECURE_BOOT=false

# --allow-missing-verity: the Containerfile build filesystem does not support fs-verity.
# systemd-boot is signed in place at /usr/lib/systemd/boot/efi/ — bootc install
# copies it from there to the ESP at install time. /boot is empty in the image
# (wiped by stack.bst); the UKI is placed at /boot/EFI/Linux/ where bootc's
# Type2Entry::load_all discovers it in the composefs image tree.
RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        set -ex \
        && mkdir -p /boot/EFI/Linux \
        && bootc container ukify --allow-missing-verity -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi \
        && sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
    ; fi
```

Note: if Task 3 determined `--measure` is needed, add it to the ukify passthrough: `-- --measure --secureboot-private-key ...`. If `systemd-tpm2-*` masking is needed, add `RUN` steps to create mask symlinks (`ln -s /dev/null /usr/lib/systemd/system/systemd-tpm2-setup-early.service` etc.) before the signing step.

- [ ] **Step 3: Verify unsigned build still works (no keys required)**

```bash
mise build
```
Expected: `localhost/krytis:latest` built — `SEAL_SECURE_BOOT` defaults to `false`, signing step skipped, lint passes

- [ ] **Step 4: Create the `seal-uki` mise task**

Create `mise/tasks/seal-uki`:

```bash
#!/usr/bin/env bash
#MISE description="Build a signed UKI + signed systemd-boot via the Containerfile"

set -euo pipefail

if [ ! -f files/boot-keys/db.key ] || [ ! -f files/boot-keys/db.crt ]; then
    echo "==> Keys not found, pulling from Proton Pass..."
    mise run pull-keys
fi

echo "==> Building sealed image (SEAL_SECURE_BOOT=true)..."
podman build --squash-all -t localhost/krytis:sealed \
    --build-arg SEAL_SECURE_BOOT=true \
    --secret id=db_key,src=files/boot-keys/db.key \
    --secret id=db_crt,src=files/boot-keys/db.crt \
    --secret id=kek_key,src=files/boot-keys/kek.key \
    --secret id=kek_crt,src=files/boot-keys/kek.crt \
    --secret id=pk_key,src=files/boot-keys/pk.key \
    --secret id=pk_crt,src=files/boot-keys/pk.crt \
    -f Containerfile .

echo "==> Sealed image: localhost/krytis:sealed"
```

- [ ] **Step 5: Run `mise run seal-uki`**

```bash
mise run seal-uki
```
Expected: `localhost/krytis:sealed` built, no errors from `bootc container ukify` or `sbsign`

- [ ] **Step 6: Verify the UKI exists and is signed**

```bash
podman run --rm localhost/krytis:sealed cat /boot/EFI/Linux/krytis.efi > /tmp/krytis.efi
sbverify /tmp/krytis.efi files/boot-keys/db.crt
```
Expected: `Signature verification OK`

- [ ] **Step 7: Verify systemd-boot is signed in place**

```bash
podman run --rm localhost/krytis:sealed cat /usr/lib/systemd/boot/efi/systemd-bootx64.efi > /tmp/systemd-bootx64.efi
sbverify /tmp/systemd-bootx64.efi files/boot-keys/db.crt
```
Expected: `Signature verification OK`

- [ ] **Step 8: Verify the UKI cmdline contains composefs digest and kargs**

```bash
ukify inspect /tmp/krytis.efi 2>/dev/null | grep -iE "cmdline|composefs|quiet|splash|fido2"
```
Expected: cmdline contains `composefs=<digest> rw`, `quiet splash`, `rd.luks.options=fido2-device=auto`

If kargs are missing: `bootc container ukify`'s `get_kargs_in_root()` may not pick up krytis's `kargs.d`. Debug: `podman run --rm localhost/krytis:latest bootc container ukify --allow-missing-verity --json pretty` to see the resolved cmdline.

- [ ] **Step 9: Verify keys are NOT in the image layer**

```bash
podman run --rm localhost/krytis:sealed find / -name "*.key" -path "*/boot-keys/*" 2>/dev/null
podman run --rm localhost/krytis:sealed find / -name "db.key" 2>/dev/null
```
Expected: no key files found (they were only available via `--secret` mounts during the `RUN` step)

- [ ] **Step 10: Commit**

```bash
git add Containerfile mise/tasks/seal-uki
git commit -m "feat(secure-boot): expand Containerfile with conditional UKI signing

Closes #32, #33

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 6: Add `.auth` file generation + `secureboot-keys` BST element (#309)

**Files:**
- Create: `mise/tasks/generate-auth`
- Create: `mise/tasks/fetch-microsoft-certs`
- Create: `elements/config/secureboot-keys.bst`
- Create: `files/microsoft-uefi-certs/` (committed — public certs, not secrets)
- Modify: `.gitignore` (add `files/secureboot-keys/`)
- Modify: `elements/stacks/bootc.bst` (add `config/secureboot-keys.bst`)

**Interfaces:**
- Consumes: `files/boot-keys/{PK,KEK,db}.{key,crt}`, `files/microsoft-uefi-certs/*.der` (committed public certs)
- Produces: `.auth` files at `/usr/lib/bootc/install/secureboot-keys/auto/` in the image

**Issue:** #309 (enrollment — real hardware path)
**Blocked by:** #312 (Task 3 — Breakage Gate), Task 4 (needs efitools in image)

- [ ] **Step 1: Create `fetch-microsoft-certs` mise task**

Microsoft's UEFI CA certs are public and well-known. They must be committed to the repo (not in the gitignored `files/boot-keys/`) so CI and fresh checkouts can generate db.auth.

Create `mise/tasks/fetch-microsoft-certs`:

```bash
#!/usr/bin/env bash
#MISE description="Fetch Microsoft UEFI CA certificates into files/microsoft-uefi-certs/"

set -euo pipefail

CERTS_DIR="files/microsoft-uefi-certs"
mkdir -p "$CERTS_DIR"

# Microsoft Corporation UEFI CA 2011
curl -sSfL "https://go.microsoft.com/fwlink/p/?linkid=321506" -out "$CERTS_DIR/microsoft-uefi-ca-2011.der"
# Microsoft Corporation UEFI CA 2023
curl -sSfL "https://go.microsoft.com/fwlink/p/?linkid=2093978" -out "$CERTS_DIR/microsoft-uefi-ca-2023.der"

# Verify
for cert in "$CERTS_DIR"/*.der; do
    openssl x509 -inform DER -in "$cert" -noout || { echo "ERROR: $cert is not a valid DER cert"; exit 1; }
done

echo "==> Microsoft UEFI CA certs in $CERTS_DIR/"
```

Note: if the URLs are unavailable, extract Microsoft's UEFI CA certs from an sbctl installation (`/usr/share/secureboot/keys/db/`) or from the UEFI forum. The certs are public and do not need to be kept secret.

- [ ] **Step 2: Fetch and commit the Microsoft certs**

```bash
mise run fetch-microsoft-certs
ls -la files/microsoft-uefi-certs/
```
Expected: `microsoft-uefi-ca-2011.der` and `microsoft-uefi-ca-2023.der` present, both valid DER certs

- [ ] **Step 3: Create the `generate-auth` mise task**

Create `mise/tasks/generate-auth`:

```bash
#!/usr/bin/env bash
#MISE description="Generate .auth EFI signature lists from PEM keys for firmware enrollment"

set -euo pipefail

KEYS_DIR="files/boot-keys"
AUTH_DIR="files/secureboot-keys/auto"
MS_CERTS_DIR="files/microsoft-uefi-certs"
GUID="${GUID:-$(uuidgen)}"

mkdir -p "$AUTH_DIR"

# Convert our PEM certs to DER
openssl x509 -in "${KEYS_DIR}/PK.crt" -outform DER -out /tmp/PK.der
openssl x509 -in "${KEYS_DIR}/KEK.crt" -outform DER -out /tmp/KEK.der
openssl x509 -in "${KEYS_DIR}/db.crt" -outform DER -out /tmp/db.der

# Create EFI signature lists (esl)
# cert-to-efi-sig-list takes: <cert.der> <output.esl> (NO type argument)
cert-to-efi-sig-list /tmp/PK.der /tmp/PK.esl
cert-to-efi-sig-list /tmp/KEK.der /tmp/KEK.esl
cert-to-efi-sig-list /tmp/db.der /tmp/db.esl

# Append Microsoft CA certs to the db signature list
for ms_cert in "${MS_CERTS_DIR}"/*.der; do
    [ -f "$ms_cert" ] || continue
    cert-to-efi-sig-list "$ms_cert" /tmp/ms-entry.esl
    cat /tmp/ms-entry.esl >> /tmp/db.esl
    rm /tmp/ms-entry.esl
done

# Sign the signature lists to create .auth files
# PK.auth: self-signed by PK (initial enrollment)
# KEK.auth: signed by PK
# db.auth: signed by KEK
sign-efi-sig-list \
    -k "${KEYS_DIR}/PK.key" -c "${KEYS_DIR}/PK.crt" \
    PK /tmp/PK.esl "${AUTH_DIR}/PK.auth"

sign-efi-sig-list \
    -k "${KEYS_DIR}/PK.key" -c "${KEYS_DIR}/PK.crt" \
    KEK /tmp/KEK.esl "${AUTH_DIR}/KEK.auth"

sign-efi-sig-list \
    -k "${KEYS_DIR}/KEK.key" -c "${KEYS_DIR}/KEK.crt" \
    db /tmp/db.esl "${AUTH_DIR}/db.auth"

rm -f /tmp/PK.der /tmp/KEK.der /tmp/db.der /tmp/PK.esl /tmp/KEK.esl /tmp/db.esl

echo "==> .auth files generated in ${AUTH_DIR}/"
ls -la "${AUTH_DIR}/"
```

Note: `sign-efi-sig-list` takes the type (`PK`, `KEK`, `db`) as its first positional argument — this is the variable name being updated. `cert-to-efi-sig-list` does NOT take a type argument.

- [ ] **Step 4: Add `files/secureboot-keys/` to `.gitignore`**

Modify `.gitignore` — add after `files/boot-keys/`:

```
files/boot-keys/
files/secureboot-keys/
```

- [ ] **Step 5: Generate the `.auth` files**

```bash
mise run pull-keys
mise run generate-auth
ls -la files/secureboot-keys/auto/
```
Expected: `PK.auth`, `KEK.auth`, `db.auth` present

- [ ] **Step 6: Create the `secureboot-keys.bst` BST element**

Create `elements/config/secureboot-keys.bst`:

```yaml
kind: manual

# Places .auth files at /usr/lib/bootc/install/secureboot-keys/auto/
# bootc install copies them to ESP/loader/keys/auto/ at install time.
# systemd-boot enrolls them at first boot if firmware is in setup mode
# and secure-boot-enroll is configured in loader.conf.
build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm644 auto/PK.auth "%{install-root}%{indep-libdir}/bootc/install/secureboot-keys/auto/PK.auth"
    install -Dm644 auto/KEK.auth "%{install-root}%{indep-libdir}/bootc/install/secureboot-keys/auto/KEK.auth"
    install -Dm644 auto/db.auth "%{install-root}%{indep-libdir}/bootc/install/secureboot-keys/auto/db.auth"
  - '%{install-extra}'

sources:
- kind: local
  path: files/secureboot-keys
```

- [ ] **Step 7: Add to `stacks/bootc.bst`**

Modify `elements/stacks/bootc.bst` — add `config/secureboot-keys.bst`:

```yaml
depends:
  - freedesktop-sdk.bst:vm/config/useradd-ostree.bst
  - freedesktop-sdk.bst:components/podman.bst
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/skopeo.bst
  - core/bootc.bst
  - core/efibootmgr.bst
  - core/secure-boot-tools.bst
  - config/bootc.bst
  - config/secureboot-keys.bst
```

- [ ] **Step 8: Handle `secure-boot-enroll` in `loader.conf`**

`loader.conf` is written by `bootctl install` at install time — a shipped `/boot/loader/loader.conf` gets wiped with `/boot`. Investigate how to set `secure-boot-enroll`:

Option A: Check if bootc has a config option for `secure-boot-enroll` (check `bootc install print-configuration` or the bootc config files under `/usr/lib/bootc/`).

Option B: Use a bootc install hook or a systemd tmpfiles entry that writes `secure-boot-enroll manual` to `ESP/loader/loader.conf` after `bootctl install`.

Option C: Document that the user must manually set it in the boot menu (less ideal).

Document the chosen approach. If Option B, create the appropriate config element.

- [ ] **Step 9: Validate and build**

```bash
mise validate
mise build
```
Expected: passes, `.auth` files in the image

- [ ] **Step 10: Verify `.auth` files are in the image**

```bash
podman run --rm localhost/krytis:latest ls -la /usr/lib/bootc/install/secureboot-keys/auto/
```
Expected: `PK.auth`, `KEK.auth`, `db.auth` present

- [ ] **Step 11: Commit**

```bash
git add mise/tasks/fetch-microsoft-certs mise/tasks/generate-auth \
    elements/config/secureboot-keys.bst elements/stacks/bootc.bst \
    .gitignore files/microsoft-uefi-certs/
# Also add loader.conf handling if Option B was chosen
git commit -m "feat(secure-boot): add .auth file generation and secureboot-keys element

Closes #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 7: Add OVMF secure boot testing (#309 — QEMU path)

**Files:**
- Create: `mise/tasks/generate-ovmf-vars`
- Modify: `mise/tasks/generate-disk` (add `--image` flag)
- Modify: `mise/tasks/boot-vm` (add `--secure` flag)

**Interfaces:**
- Consumes: `files/boot-keys/{PK,KEK,db}.crt` (PEM certs for baking into OVMF vars)
- Produces: `.ovmf-vars-secure.fd` (OVMF variables file with enrolled keys)

**Issue:** #309 (enrollment — QEMU testing path)
**Blocked by:** #312 (Task 3), Task 5 (needs sealed image)

- [ ] **Step 1: Create the `generate-ovmf-vars` mise task**

Create `mise/tasks/generate-ovmf-vars`:

```bash
#!/usr/bin/env bash
#MISE description="Generate OVMF vars file with secure boot keys enrolled for QEMU testing"

set -euo pipefail

KEYS_DIR="files/boot-keys"
GUID="${GUID:-$(uuidgen)}"

# Find the base OVMF secboot vars file
OVMF_VARS_SRC=""
for candidate in \
        /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2 \
        /usr/share/OVMF/OVMF_VARS_4M.secboot.qcow2 \
        /usr/share/edk2/x64/OVMF_VARS.4m.secboot.qcow2; do
    [ -f "${candidate}" ] && OVMF_VARS_SRC="${candidate}" && break
done
if [ -z "${OVMF_VARS_SRC}" ]; then
    echo "ERROR: OVMF secure boot vars not found. Install edk2-ovmf with secboot variant." >&2
    exit 1
fi

echo "==> Generating OVMF vars with enrolled keys..."
echo "    GUID: ${GUID}"

# virt-fw-vars accepts PEM certs directly (no DER conversion needed)
virt-fw-vars \
    --input "${OVMF_VARS_SRC}" \
    --secure-boot \
    --set-pk  "${GUID}" "${KEYS_DIR}/PK.crt" \
    --add-kek "${GUID}" "${KEYS_DIR}/KEK.crt" \
    --add-db  "${GUID}" "${KEYS_DIR}/db.crt" \
    -o ".ovmf-vars-secure.fd"

echo "==> OVMF vars: .ovmf-vars-secure.fd"
```

Note: `virt-fw-vars` is from `python3-virt-firmware` (Fedora). It accepts PEM directly — no DER conversion needed. Check `virt-fw-vars --help` to confirm.

- [ ] **Step 2: Generate OVMF vars**

```bash
mise run pull-keys
mise run generate-ovmf-vars
ls -la .ovmf-vars-secure.fd
```
Expected: `.ovmf-vars-secure.fd` created

- [ ] **Step 3: Add `--image` flag to `generate-disk`**

Modify `mise/tasks/generate-disk` — add a `--image` flag so we can install from `localhost/krytis:sealed` without clobbering `:latest`:

Add to the USAGE flags:
```bash
#USAGE flag "--image <tag>" default="localhost/krytis:latest" help="Image tag to install"
```

Replace the hardcoded `localhost/krytis:latest` references with `${usage_image:-localhost/krytis:latest}`.

- [ ] **Step 4: Add `--secure` flag to `boot-vm`**

Modify `mise/tasks/boot-vm` — add `--secure` flag. Secure boot enforcement requires:
- q35 machine type with SMM
- The `.secboot` OVMF CODE variant (not the regular `OVMF_CODE.fd`)
- `secure=on` on the pflash device
- The `.ovmf-vars-secure.fd` vars file

Add to the USAGE flags:
```bash
#USAGE flag "--secure" help="Boot with OVMF secure boot enabled"
```

In the native qemu path, when `--secure` is set:

```bash
SECURE="${usage_secure:-}"

if [ "$SECURE" = "true" ]; then
    OVMF_VARS=".ovmf-vars-secure.fd"
    # Use secboot OVMF code
    for candidate in \
            /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd \
            /usr/share/OVMF/OVMF_CODE_4M.secboot.qcow2 \
            /usr/share/edk2/x64/OVMF_CODE.4m.secboot.fd; do
        [ -f "${candidate}" ] && OVMF_CODE="${candidate}" && break
    done
    if [ ! -f "$OVMF_VARS" ]; then
        echo "ERROR: .ovmf-vars-secure.fd not found — run 'mise run generate-ovmf-vars' first." >&2
        exit 1
    fi
fi
```

Then in the qemu invocation, when `--secure`:
- Change `-machine` to include `q35,smm=on`
- Add `-global driver=cfi.pflash01,property=secure,value=on`
- Use the secboot OVMF_CODE and the secure vars

```bash
if [ "$SECURE" = "true" ]; then
    MACHINE_ARGS="q35,smm=on"
    FLASH_SECURE="-global driver=cfi.pflash01,property=secure,value=on"
else
    MACHINE_ARGS="q35"
    FLASH_SECURE=""
fi

qemu-system-x86_64 \
    -enable-kvm \
    -m "${VM_RAM}" \
    -machine "${MACHINE_ARGS}" \
    ${FLASH_SECURE} \
    -drive "file=${DISK},format=raw,if=virtio" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
    ...rest of args...
```

- [ ] **Step 5: Generate a sealed disk image**

```bash
mise run pull-keys
mise run seal-uki
mise run generate-disk --image localhost/krytis:sealed --disk /tmp/test-secure.raw
```
Expected: disk generated from the sealed image

- [ ] **Step 6: Boot with secure boot**

```bash
mise run boot-vm --disk /tmp/test-secure.raw --secure
```
Expected: VM boots successfully with secure boot, reaches login prompt

- [ ] **Step 7: Verify secure boot is active in the guest**

```bash
ssh -p 2222 root@localhost
bootctl status | grep "Secure Boot"
```
Expected: `Secure Boot: enabled (user)`

- [ ] **Step 8: Negative test — boot unsigned image with secure boot**

```bash
mise run generate-disk --image localhost/krytis:latest --disk /tmp/test-unsigned.raw
mise run boot-vm --disk /tmp/test-unsigned.raw --secure
```
Expected: **boot fails** — firmware rejects the unsigned UKI. VM drops to UEFI shell or firmware menu, does NOT reach the OS. This confirms secure boot enforcement.

If the unsigned image boots: secure boot is NOT enforcing. Check that SMM is enabled (`-machine q35,smm=on`), the secboot OVMF CODE is used, and `secure=on` is on the pflash device.

- [ ] **Step 9: Commit**

```bash
git add mise/tasks/generate-ovmf-vars mise/tasks/generate-disk mise/tasks/boot-vm
git commit -m "feat(secure-boot): add OVMF secure boot testing for QEMU

generate-ovmf-vars bakes PK/KEK/db keys into an OVMF vars file.
generate-disk --image allows installing from sealed image without
clobbering :latest. boot-vm --secure uses q35+smm+secboot OVMF code
with secure pflash for real secure boot enforcement.

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 8: Add `docs/skills/secure-boot.md` (AGENTS.md mandate)

**Files:**
- Create: `docs/skills/secure-boot.md`

**Issue:** AGENTS.md Self-Improvement Loop — skill file updates must be in the same PR

- [ ] **Step 1: Write the skill file**

Create `docs/skills/secure-boot.md` documenting the non-obvious patterns discovered during implementation:

- `/boot` is empty in the image (wiped by `stack.bst`) — the UKI is placed at `/boot/EFI/Linux/` by the Containerfile `RUN` step, and bootc discovers it there via `Type2Entry::load_all`
- `systemd-boot` binary lives at `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` — sign in place, not at `/boot/EFI/systemd/`
- `--allow-missing-verity` required for `bootc container ukify` in a Containerfile build (no fs-verity support)
- podman `--secret` mounts for keys — keys never enter the image layer
- `cert-to-efi-sig-list` takes no type argument; `sign-efi-sig-list` takes the type as first positional
- `loader.conf` is written at install time by `bootctl install` — not shippable in `/boot/`
- QEMU secure boot requires q35+smm+secboot OVMF CODE + `secure=on` on pflash
- Microsoft UEFI CA certs are committed in `files/microsoft-uefi-certs/` (public, not secret)
- bootc validates the UKI's `composefs=` cmdline matches the deployment ID

- [ ] **Step 2: Update `docs/SKILL.md` router**

Add a row to the Task → Skill table:
```
| Work with secure boot, UKI signing, key enrollment | [`docs/skills/secure-boot.md`](skills/secure-boot.md) |
```

- [ ] **Step 3: Commit**

```bash
git add docs/skills/secure-boot.md docs/SKILL.md
git commit -m "docs(skills): add secure-boot skill file

Documents non-obvious patterns: empty /boot in image, systemd-boot
source path, --allow-missing-verity, --secret mounts, cert-to-efi-sig-list
syntax, loader.conf install-time generation, QEMU SMM requirement.

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 9: Integration test — full secure boot chain

**Files:**
- No new files — verification milestone

**Blocked by:** Tasks 1-8 all complete

- [ ] **Step 1: Full build pipeline**

```bash
mise run pull-keys
mise run fetch-microsoft-certs
mise run generate-auth
mise build
mise run seal-uki
```
Expected: all steps succeed, `localhost/krytis:sealed` produced

- [ ] **Step 2: Generate OVMF vars and sealed disk**

```bash
mise run generate-ovmf-vars
mise run generate-disk --image localhost/krytis:sealed --disk /tmp/test-final.raw
```

- [ ] **Step 3: Boot with secure boot**

```bash
mise run boot-vm --disk /tmp/test-final.raw --secure
```
Expected: boots to login prompt

- [ ] **Step 4: Verify the full chain in the guest**

```bash
ssh -p 2222 root@localhost
bootctl status | grep "Secure Boot"      # → enabled (user)
ls /usr/lib/bootc/install/secureboot-keys/auto/  # → PK.auth KEK.auth db.auth
```

- [ ] **Step 5: Verify fido2-luks unlock still works**

Per #312 analysis:
```bash
lsblk -f | grep crypto_LUKS
systemctl status systemd-cryptsetup@* 2>/dev/null | grep "Active:"
```
Expected: LUKS volume unlocked (per #312 mitigations if TPM-bound)

- [ ] **Step 6: Negative test — unsigned image rejected**

```bash
mise run generate-disk --image localhost/krytis:latest --disk /tmp/test-unsigned.raw
mise run boot-vm --disk /tmp/test-unsigned.raw --secure
```
Expected: boot fails (unsigned UKI rejected by firmware)

- [ ] **Step 7: `mise lint` passes**

```bash
mise run load-image
mise lint
```
Expected: lint passes

- [ ] **Step 8: Open the PR**

```bash
gh pr create --title "feat(secure-boot): implement EFI secure boot" --body 'Closes #16

## Summary

[Summarize the full implementation]

## Verification

- [x] `mise run seal-uki` produces a signed UKI + signed systemd-boot
- [x] Sealed image boots with OVMF secure boot enabled (`mise run boot-vm --secure`)
- [x] `bootctl status` shows "Secure Boot: enabled (user)" in the guest
- [x] Negative test: unsigned image is rejected by secure boot
- [x] Fido2-luks unlock works after secure boot enablement (#312 analysis)
- [x] `mise lint` passes

[Link to #312 analysis document]

Assisted-by: Claude Sonnet 4.6'
```

---

## Notes for the implementer

1. **Task 3 (spike) is the critical path.** The UKI consumption spike determines whether `bootc install to-disk` actually boots a pre-built UKI from `/boot/EFI/Linux/`. If it doesn't, the plan needs revision before Tasks 5+. Do Task 4 Steps 1-3 first (add the tools), then the spike, then complete Task 4 and proceed.

2. **`--allow-missing-verity` is required.** The Containerfile build filesystem does not support fs-verity. Without this flag, `bootc container ukify` may abort when computing the composefs digest.

3. **systemd-boot is signed at `/usr/lib/systemd/boot/efi/systemd-bootx64.efi`**, not at `/boot/EFI/systemd/systemd-bootx64.efi`. `/boot` is empty in the image. `bootc install --bootloader systemd` runs `bootctl install` which copies the binary from `/usr/lib/` to the ESP.

4. **bootc discovers UKIs at `/boot/EFI/Linux/`** in the composefs image tree. The Containerfile `RUN` step places the UKI there. bootc's `Type2Entry::load_all` finds it and validates the `composefs=` cmdline matches the deployment ID.

5. **`cert-to-efi-sig-list` takes NO type argument.** Its syntax is `cert-to-efi-sig-list <cert.der> <output.esl>`. `sign-efi-sig-list` takes the type (`PK`, `KEK`, `db`) as its first positional — that's the variable name being updated.

6. **Microsoft UEFI CA certs are committed** in `files/microsoft-uefi-certs/` — they are public, not secret. They must not be in the gitignored `files/boot-keys/` or CI/fresh checkouts can't generate db.auth.

7. **QEMU secure boot requires SMM.** Without `-machine q35,smm=on` + the secboot OVMF CODE + `secure=on` on pflash, an unsigned image may still boot — negative tests would falsely pass.

8. **`loader.conf` is install-time.** `bootctl install` writes it to the ESP. A shipped `/boot/loader/loader.conf` gets wiped with `/boot`. `secure-boot-enroll` must be configured via a bootc mechanism or install hook.

9. **`generate-disk --image` flag** replaces the `podman tag` hack. Don't clobber `:latest` — it breaks the rootless→root store copy in `generate-disk`.

10. **CI signing is a prerequisite for registry publishes.** Do not publish unsigned images to a public registry. CI must sign from day one using a single `PROTON_PASS_PERSONAL_ACCESS_TOKEN`.
