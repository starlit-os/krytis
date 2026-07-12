# Secure Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement EFI secure boot for krytis — signed UKI, signed systemd-boot, and firmware key enrollment — using the existing `Containerfile` expanded with a conditional signing step.

**Architecture:** The existing `mise build` pipeline produces `localhost/krytis-input:latest` (BST) → `localhost/krytis:latest` (lint via `Containerfile`). The `Containerfile` is expanded with a `SEAL_SECURE_BOOT` build arg: when `true`, `bootc container ukify` builds and signs the UKI and `sbsign` signs `systemd-boot`, all inside the image with keys passed via podman `--secret` mounts. Keys (PK, KEK, db — sbctl model, RSA 4096) are retrieved from Proton Pass via `fnox get`. Firmware enrollment uses systemd-boot's native `loader/keys/` mechanism, automated by bootc's `/usr/lib/bootc/install/secureboot-keys`.

**Tech Stack:** BuildStream 2, bootc v1.16.3, systemd-ukify, sbsigntools, efitools, fnox + pass-cli (Proton Pass), podman, OVMF (QEMU testing)

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only
- All maintenance tasks must be `mise` tasks — no loose shell commands
- Every element with a `kind: tar` or `kind: remote` source needs a mise update task + CI job (track-mise pattern) or a `git_repo` track matrix entry
- `mise lint` must pass before opening a PR
- The image must boot — use `mise boot-test` / `mise boot-vm` for verification
- Agents MUST NOT push directly to `main` — all changes via PR from a feature branch
- Worktree + branch required before touching files (AGENTS.md convention)
- Skill file updates must be in the same commit as the change that produced the learning (Self-Improvement Loop)
- 3-key model: PK, KEK, db (sbctl model, RSA 4096) — db signs all EFI binaries
- `files/boot-keys/` is gitignored — keys never committed
- This plan touches the boot path and LUKS — Breakage Gate (#312) must be cleared before full boot chain verification

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
- Modify: `.gitignore` (already has `files/boot-keys/` — verify)

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
Expected: `generate-keys` appears in the list with description "Generate secure boot signing keys (fallback — use pull-keys for existing keys)"

- [ ] **Step 3: Test idempotency — run on clean checkout**

```bash
rm -rf files/boot-keys
mise run generate-keys
ls -la files/boot-keys/{PK,KEK,db}.{key,crt}
```
Expected: all 6 files exist, `extra-db/` directory exists, `.key` files are mode 600, `.crt` files are mode 644

- [ ] **Step 4: Test idempotency — run again (should be no-op)**

```bash
mise run generate-keys
```
Expected: prints "==> PK key pair already exists, skipping." for each key, exits 0, no files modified

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

Note: adjust `vault = "Krytis"` and the item name `"Secure Boot Keys"` to match the actual Proton Pass vault and item names the developer uses.

- [ ] **Step 2: Create the `pull-keys` mise task**

Create `mise/tasks/pull-keys`:

```bash
#!/usr/bin/env bash
#MISE description="Pull secure boot keys from Proton Pass into files/boot-keys/"

set -euo pipefail

mkdir -p files/boot-keys/extra-db

# Map fnox secret names to boot-keys filenames
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

# Validate keys round-trip cleanly from Proton Pass
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
Expected: `pull-keys` appears with description "Pull secure boot keys from Proton Pass into files/boot-keys/"

- [ ] **Step 4: Test pulling keys**

Prerequisites: `pass-cli login` completed, Proton Pass vault item populated.

```bash
rm -rf files/boot-keys
mise run pull-keys
ls -la files/boot-keys/{PK,KEK,db}.{key,crt}
```
Expected: all 6 files exist, `extra-db/` directory exists, validation passes, `.key` files mode 600, `.crt` files mode 644

- [ ] **Step 5: Verify pulled keys match sbctl-generated keys**

```bash
for key in PK KEK db; do
    openssl x509 -in "files/boot-keys/${key}.crt" -noout -fingerprint -sha256
done
```
Expected: fingerprints match the developer's existing sbctl keys (compare with `sbctl status` or the original sbctl key directory)

- [ ] **Step 6: Commit**

```bash
git add fnox.toml mise/tasks/pull-keys
git commit -m "feat(mise): add pull-keys task + fnox.toml for Proton Pass key retrieval

fnox.toml maps secret names to pass:// references (no secrets in the
repo). mise run pull-keys retrieves 3 key pairs (PK, KEK, db) from
Proton Pass via fnox get, validates with openssl, writes to
files/boot-keys/.

Closes #311

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 3: Investigate fido2-luks / TPM PCR interaction (#312)

**Files:**
- No code changes — investigation and documentation only
- Create: `docs/plan/secure-boot-tpm-analysis.md` (analysis results)

**Interfaces:**
- Consumes: existing `files/bootc-config/30-fido2-luks.toml`, current LUKS/TPM setup
- Produces: a decision document that gates Tasks 5+ (whether `ukify --measure` is needed, whether `systemd-tpm2-*` services must be masked, whether re-enrollment is required)

**Issue:** #312 (Breakage Gate — must be cleared before Tasks 5 and 7)

- [ ] **Step 1: Check if current krytis LUKS volumes are TPM-bound**

On a running krytis system (or the developer's machine if running krytis):

```bash
# List LUKS devices and their token types
lsblk -f | grep crypto_LUKS
for dev in $(lsblk -o NAME,FSTYPE -n | grep crypto_LUKS | awk '{print $1}'); do
    echo "=== /dev/${dev} ==="
    cryptsetup luksDump /dev/${dev} | grep -A5 "Tokens"
    systemd-cryptenroll list /dev/${dev} 2>/dev/null || true
done
```

Document: are any volumes bound to TPM PCRs? Or FIDO2-only? Or passphrase-only?

- [ ] **Step 2: If TPM-bound, identify which PCRs are used**

```bash
# Check TPM2 PCR allocations
systemd-cryptenroll list /dev/<luks-device> 2>/dev/null
# Or check the token directly
cryptsetup token export /dev/<luks-device> 2>/dev/null | jq '.'
```

Document: which PCRs (7 = secure boot policy, 4 = boot manager, 9 = kernel, etc.) are bound.

- [ ] **Step 3: Analyze PCR impact of switching to signed UKI**

Research and document:
- PCR 4 (boot manager): changes when switching from unsigned systemd-boot to signed systemd-boot + UKI
- PCR 7 (secure boot policy): changes when secure boot is enabled (was disabled)
- PCR 9 (kernel): changes if the kernel image format changes (vmlinuz → UKI)

Will existing TPM-enrolled LUKS volumes be locked out after enabling secure boot?

- [ ] **Step 4: Evaluate `ukify --measure`**

Read the bootc `contrib/packaging/seal-uki` script and travier's `uki.sh`:
- `--measure` measures the UKI into TPM PCRs at boot time
- travier masks `systemd-tpm2-setup-early.service`, `systemd-tpm2-setup.service`, `systemd-pcrphase.service`, `systemd-pcrproduct.service` as workarounds

Document: should `ukify --measure` be used? What `systemd-tpm2-*` services need masking?

- [ ] **Step 5: Write the analysis document**

Create `docs/plan/secure-boot-tpm-analysis.md` with:
- Whether current LUKS is TPM-bound (Step 1-2 results)
- PCR impact analysis (Step 3)
- Decision on `ukify --measure` and `systemd-tpm2-*` masking (Step 4)
- Mitigations needed (if any): re-enrollment procedure, service masking, or "non-issue — FIDO2-only"
- Whether this gates Task 5 (#32) and Task 7 (#309)

- [ ] **Step 6: Commit**

```bash
git add docs/plan/secure-boot-tpm-analysis.md
git commit -m "docs(secure-boot): fido2-luks TPM PCR interaction analysis

Closes #312

[Summary of findings — TPM-bound or not, mitigations needed or not]

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 4: Add secure boot tools to the image dep tree

**Files:**
- Create: `elements/core/secure-boot-tools.bst`
- Modify: `elements/stacks/bootc.bst` (add the new element to depends)
- Modify: `docs/skills/bst.md` (if any non-obvious pattern discovered)

**Interfaces:**
- Produces: a BST element that brings `ukify`, `sbsign`, `cert-to-efi-sig-list`, `sign-efi-sig-list`, and the EFI stub into the runtime image
- Consumes: freedesktop-sdk junction components

**Issue:** Part of #32 (runtime deps)

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

Modify `elements/stacks/bootc.bst` — add `core/secure-boot-tools.bst` to `depends:`:

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

- [ ] **Step 4: Build and verify tools are in the image**

```bash
mise bst build elements/core/secure-boot-tools.bst
mise bst artifact list-contents elements/core/secure-boot-tools.bst | grep -E "ukify$|sbsign$|cert-to-efi-sig-list$|sign-efi-sig-list$"
```
Expected: all four binaries listed

- [ ] **Step 5: Verify the EFI stub is present**

```bash
mise bst build oci/krytis/image.bst
# Check the filesystem.bst artifact for the stub
mise bst artifact list-contents oci/krytis/filesystem.bst | grep "linuxx64.efi.stub"
```
Expected: `/usr/lib/systemd/boot/efi/linuxx64.efi.stub` present

If the stub is missing, `systemd-ukify.bst` may not include it — check if `systemd.bst` (full) is needed instead. `systemd-ukify.bst` is a `kind: filter` over `systemd-base.bst` with `include: [ukify, systemd-license]` — the stub may be in a different split. If so, add the appropriate element.

- [ ] **Step 6: Full image build to confirm no breakage**

```bash
mise build
```
Expected: `localhost/krytis:latest` built successfully, `bootc container lint` passes

- [ ] **Step 7: Commit**

```bash
git add elements/core/secure-boot-tools.bst elements/stacks/bootc.bst
git commit -m "feat(secure-boot): add secure boot tools to image dep tree

Brings systemd-ukify (ukify + EFI stub), sbsigntools (sbsign/sbverify),
and efitools (cert-to-efi-sig-list / sign-efi-sig-list) into the
runtime image. Used by the seal-uki Containerfile step and .auth file
generation.

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
- Produces: `localhost/krytis:sealed` (image with signed UKI at `/boot/EFI/Linux/` and signed `systemd-boot`)

**Issues:** #32, #33
**Blocked by:** #31 (Task 1), #311 (Task 2), #312 (Task 3 — Breakage Gate must be cleared)

- [ ] **Step 1: Read the #312 analysis**

Read `docs/plan/secure-boot-tpm-analysis.md` (from Task 3). Determine:
- Is `ukify --measure` needed?
- Do any `systemd-tpm2-*` services need masking in the image?
- Adjust the Containerfile `RUN` step below accordingly

- [ ] **Step 2: Expand the `Containerfile`**

Modify `Containerfile`:

```dockerfile
FROM localhost/krytis-input:latest

# Run bootc container lint (existing)
RUN bootc container lint

# Conditional secure boot sealing — gated by build arg.
# mise build (unsigned) skips this; mise run seal-uki enables it.
ARG SEAL_SECURE_BOOT=false

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        set -ex \
        && mkdir -p /boot/EFI/Linux \
        && bootc container ukify -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi \
        && sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /boot/EFI/systemd/systemd-bootx64.efi \
            /boot/EFI/systemd/systemd-bootx64.efi \
    ; fi
```

Note: if Task 3 determined `--measure` is needed, add it to the `ukify` passthrough args: `-- --measure --secureboot-private-key ...`. If `systemd-tpm2-*` masking is needed, add `RUN` steps to create mask symlinks before the signing step.

- [ ] **Step 3: Verify unsigned build still works (no keys required)**

```bash
mise build
```
Expected: `localhost/krytis:latest` built successfully — `SEAL_SECURE_BOOT` defaults to `false`, signing step skipped, `bootc container lint` passes

- [ ] **Step 4: Create the `seal-uki` mise task**

Create `mise/tasks/seal-uki`:

```bash
#!/usr/bin/env bash
#MISE description="Build a signed UKI + signed systemd-boot via the Containerfile"

set -euo pipefail

# Ensure keys are present (pull from Proton Pass if configured, or generate as fallback)
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

- [ ] **Step 5: Verify the task is listed**

Run: `mise tasks`
Expected: `seal-uki` appears with description "Build a signed UKI + signed systemd-boot via the Containerfile"

- [ ] **Step 6: Run `mise run seal-uki`**

```bash
mise run pull-keys
mise run seal-uki
```
Expected: `localhost/krytis:sealed` built successfully, no errors from `bootc container ukify` or `sbsign`

- [ ] **Step 7: Verify the UKI exists in the sealed image**

```bash
podman run --rm localhost/krytis:sealed ls -la /boot/EFI/Linux/
```
Expected: `krytis.efi` present

- [ ] **Step 8: Verify the UKI is signed**

```bash
# Extract the UKI to a temp file
podman run --rm localhost/krytis:sealed cat /boot/EFI/Linux/krytis.efi > /tmp/krytis.efi
sbverify /tmp/krytis.efi files/boot-keys/db.crt
```
Expected: `Signature verification OK`

- [ ] **Step 9: Verify systemd-boot is signed**

```bash
# Extract systemd-boot to a temp file
podman run --rm localhost/krytis:sealed cat /boot/EFI/systemd/systemd-bootx64.efi > /tmp/systemd-bootx64.efi
sbverify /tmp/systemd-bootx64.efi files/boot-keys/db.crt
```
Expected: `Signature verification OK`

- [ ] **Step 10: Verify the UKI cmdline contains composefs digest**

```bash
ukify inspect /tmp/krytis.efi 2>/dev/null | grep -i "cmdline\|composefs"
```
Expected: cmdline section present, contains `composefs=<digest> rw`

- [ ] **Step 11: Verify kargs.d is baked into the cmdline**

```bash
ukify inspect /tmp/krytis.efi 2>/dev/null | grep -i "quiet\|splash\|fido2"
```
Expected: `quiet splash` (from `20-plymouth.toml`) and `rd.luks.options=fido2-device=auto` (from `30-fido2-luks.toml`) present in the cmdline

If not present: `bootc container ukify`'s `get_kargs_in_root()` may not be picking up krytis's `kargs.d`. Debug by running `bootc container ukify --rootfs / --json pretty` inside the image to see the resolved cmdline.

- [ ] **Step 12: Verify keys are NOT in the image layer**

```bash
podman run --rm localhost/krytis:sealed find / -name "*.key" -o -name "db.key" -o -name "PK.key" 2>/dev/null | head
```
Expected: no key files found in the image (they were only available via `--secret` mounts during the `RUN` step)

- [ ] **Step 13: Commit**

```bash
git add Containerfile mise/tasks/seal-uki
git commit -m "feat(secure-boot): expand Containerfile with conditional UKI signing

The existing Containerfile (FROM localhost/krytis-input:latest + bootc
container lint) is expanded with a SEAL_SECURE_BOOT build arg. When
true, bootc container ukify builds and signs the UKI and sbsign signs
systemd-boot, all inside the image with keys passed via podman --secret
mounts (keys never enter the image layer).

mise build (unsigned) skips the signing step. mise run seal-uki
produces localhost/krytis:sealed.

Closes #32, #33

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 6: Add `.auth` file generation + `secureboot-keys` BST element (#309)

**Files:**
- Create: `mise/tasks/generate-auth`
- Create: `elements/config/secureboot-keys.bst`
- Create: `files/secureboot-keys/` (generated `.auth` files go here, gitignored)
- Modify: `.gitignore` (add `files/secureboot-keys/`)
- Modify: `elements/stacks/bootc.bst` (add `config/secureboot-keys.bst`)

**Interfaces:**
- Consumes: `files/boot-keys/{PK,KEK,db}.{key,crt}` (from #31 or #311), Microsoft CA certs (well-known public keys)
- Produces: `.auth` files at `/usr/lib/bootc/install/secureboot-keys/auto/` in the image

**Issue:** #309 (enrollment — real hardware path)
**Blocked by:** #312 (Task 3 — Breakage Gate)

- [ ] **Step 1: Download Microsoft's well-known UEFI CA certificates**

```bash
mkdir -p files/boot-keys/extra-db

# Microsoft Corporation UEFI CA 2011 (3K = 30MB, contains the CA cert)
# The well-known Microsoft UEFI CA certs are publicly available.
# Download the DER-formatted CA certs:
curl -sSfL "https://go.microsoft.com/fwlink/p/?linkid=321506" -o files/boot-keys/extra-db/microsoft-uefi-ca-2011.der
curl -sSfL "https://go.microsoft.com/fwlink/p/?linkid=2093978" -o files/boot-keys/extra-db/microsoft-uefi-ca-2023.der

# Verify they are valid X.509 certs
openssl x509 -inform DER -in files/boot-keys/extra-db/microsoft-uefi-ca-2011.der -noout
openssl x509 -inform DER -in files/boot-keys/extra-db/microsoft-uefi-ca-2023.der -noout
```

Note: the exact URLs may change — verify against the Arch Wiki or sbctl's vendored Microsoft certs. If the URLs are unavailable, sbctl vendors Microsoft's CA certs at `/usr/share/secureboot/keys/db/` on a system with sbctl installed.

- [ ] **Step 2: Create the `generate-auth` mise task**

Create `mise/tasks/generate-auth`:

```bash
#!/usr/bin/env bash
#MISE description="Generate .auth EFI signature lists from PEM keys for firmware enrollment"

set -euo pipefail

KEYS_DIR="files/boot-keys"
AUTH_DIR="files/secureboot-keys/auto"
EXTRA_DB_DIR="${KEYS_DIR}/extra-db"

mkdir -p "$AUTH_DIR"

# Convert our PEM certs to DER for the signature list
openssl x509 -in "${KEYS_DIR}/PK.crt" -outform DER -o /tmp/PK.der
openssl x509 -in "${KEYS_DIR}/KEK.crt" -outform DER -o /tmp/KEK.der
openssl x509 -in "${KEYS_DIR}/db.crt" -outform DER -o /tmp/db.der

# Create EFI signature lists (esl) — one entry per cert
# Format: cert-to-efi-sig-list <type> <cert.der> <output.esl>
cert-to-efi-sig-list PK /tmp/PK.der /tmp/PK.esl
cert-to-efi-sig-list KEK /tmp/KEK.der /tmp/KEK.esl

# db signature list: our db cert + Microsoft CA certs (to retain third-party EFI binary support)
cert-to-efi-sig-list db /tmp/db.der /tmp/db.esl
for ms_cert in "${EXTRA_DB_DIR}"/*.der; do
    [ -f "$ms_cert" ] || continue
    cert-to-efi-sig-list db "$ms_cert" /tmp/ms-entry.esl
    cat /tmp/ms-entry.esl >> /tmp/db.esl
done

# Sign the signature lists to create .auth files
# PK.auth: self-signed by PK (initial enrollment)
# KEK.auth: signed by PK
# db.auth: signed by KEK
sign-efi-sig-list -t "2030-01-01" \
    -k "${KEYS_DIR}/PK.key" -c "${KEYS_DIR}/PK.crt" \
    PK /tmp/PK.esl "${AUTH_DIR}/PK.auth"

sign-efi-sig-list -t "2030-01-01" \
    -k "${KEYS_DIR}/PK.key" -c "${KEYS_DIR}/PK.crt" \
    KEK /tmp/KEK.esl "${AUTH_DIR}/KEK.auth"

sign-efi-sig-list -t "2030-01-01" \
    -k "${KEYS_DIR}/KEK.key" -c "${KEYS_DIR}/KEK.crt" \
    db /tmp/db.esl "${AUTH_DIR}/db.auth"

rm -f /tmp/PK.der /tmp/KEK.der /tmp/db.der /tmp/PK.esl /tmp/KEK.esl /tmp/db.esl /tmp/ms-entry.esl

echo "==> .auth files generated in ${AUTH_DIR}/"
ls -la "${AUTH_DIR}/"
```

Note: the `-t` flag sets the timestamp in the .auth file. Use a fixed future timestamp to avoid timezone/time skew issues. Adjust the date as needed.

- [ ] **Step 3: Add `files/secureboot-keys/` to `.gitignore`**

Modify `.gitignore` — add after the `files/boot-keys/` line:

```
files/boot-keys/
files/secureboot-keys/
```

- [ ] **Step 4: Generate the `.auth` files**

```bash
mise run pull-keys
mise run generate-auth
ls -la files/secureboot-keys/auto/
```
Expected: `PK.auth`, `KEK.auth`, `db.auth` present

- [ ] **Step 5: Create the `secureboot-keys.bst` BST element**

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

- [ ] **Step 6: Add `secureboot-keys.bst` to `stacks/bootc.bst`**

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

- [ ] **Step 7: Set `secure-boot-enroll manual` in `loader.conf`**

This needs to be in the image at `/boot/loader/loader.conf` or via a bootc config. Check how systemd-boot's `loader.conf` is managed in the current image. If there's no existing `loader.conf` element, create one or add it to `config/bootc.bst`.

If creating a new config element, add a `loader.conf` with:

```
timeout 3
secure-boot-enroll manual
```

If `loader.conf` is managed by bootc at install time, check if bootc has a config option for `secure-boot-enroll`. Otherwise, ship a `loader.conf` in the image.

- [ ] **Step 8: Validate and build**

```bash
mise validate
mise build
```
Expected: passes, `.auth` files present in the image at `/usr/lib/bootc/install/secureboot-keys/auto/`

- [ ] **Step 9: Verify `.auth` files are in the image**

```bash
podman run --rm localhost/krytis:latest ls -la /usr/lib/bootc/install/secureboot-keys/auto/
```
Expected: `PK.auth`, `KEK.auth`, `db.auth` present

- [ ] **Step 10: Commit**

```bash
git add mise/tasks/generate-auth elements/config/secureboot-keys.bst \
    elements/stacks/bootc.bst .gitignore files/bootc-config/loader.conf
git commit -m "feat(secure-boot): add .auth file generation and secureboot-keys element

generate-auth mise task creates signed EFI signature lists (.auth)
from PEM keys using efitools (cert-to-efi-sig-list + sign-efi-sig-list).
db.auth bundles Microsoft CA certs (2011 + 2023) to retain third-party
EFI binary support.

secureboot-keys.bst places .auth files at
/usr/lib/bootc/install/secureboot-keys/auto/ — bootc install copies
them to ESP/loader/keys/auto/, systemd-boot enrolls at first boot.

secure-boot-enroll manual set in loader.conf — real hardware requires
explicit user confirmation in the boot menu.

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 7: Add OVMF secure boot testing (#309 — QEMU path)

**Files:**
- Create: `mise/tasks/generate-ovmf-vars`
- Modify: `mise/tasks/boot-vm` (add `--secure` flag)

**Interfaces:**
- Consumes: `files/boot-keys/{PK,KEK,db}.crt` (PEM certs for baking into OVMF vars)
- Produces: `.ovmf-vars-secure.fd` (OVMF variables file with enrolled keys)

**Issue:** #309 (enrollment — QEMU testing path)
**Blocked by:** #312 (Task 3), Task 6 (needs the sealed image)

- [ ] **Step 1: Create the `generate-ovmf-vars` mise task**

Create `mise/tasks/generate-ovmf-vars`:

```bash
#!/usr/bin/env bash
#MISE description="Generate OVMF vars file with secure boot keys enrolled for QEMU testing"

set -euo pipefail

KEYS_DIR="files/boot-keys"
GUID="${GUID:-$(uuidgen)}"

# Find the base OVMF vars file (secure boot variant)
OVMF_VARS_SRC=""
for candidate in \
        /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2 \
        /usr/share/OVMF/OVMF_VARS_4M.secboot.qcow2 \
        /usr/share/edk2/x64/OVMF_VARS.4m.secboot.qcow2; do
    [ -f "${candidate}" ] && OVMF_VARS_SRC="${candidate}" && break
done
if [ -z "${OVMF_VARS_SRC}" ]; then
    echo "ERROR: OVMF secure boot vars not found. Install edk2-ovmf (Fedora) with secboot variant." >&2
    exit 1
fi

echo "==> Generating OVMF vars with enrolled keys..."
echo "    Base: ${OVMF_VARS_SRC}"
echo "    GUID: ${GUID}"

# Convert PEM certs to DER for virt-fw-vars
openssl x509 -in "${KEYS_DIR}/PK.crt" -outform DER -o /tmp/PK.der
openssl x509 -in "${KEYS_DIR}/KEK.crt" -outform DER -o /tmp/KEK.der
openssl x509 -in "${KEYS_DIR}/db.crt" -outform DER -o /tmp/db.der

virt-fw-vars \
    --input "${OVMF_VARS_SRC}" \
    --secure-boot \
    --set-pk  "${GUID}" "${KEYS_DIR}/PK.crt" \
    --add-kek "${GUID}" "${KEYS_DIR}/KEK.crt" \
    --add-db  "${GUID}" "${KEYS_DIR}/db.crt" \
    -o ".ovmf-vars-secure.fd"

rm -f /tmp/PK.der /tmp/KEK.der /tmp/db.der

echo "==> OVMF vars: .ovmf-vars-secure.fd"
```

Note: `virt-fw-vars` is from `python3-virt-firmware` (Fedora) or `python3-virt-firmware` (Debian). It accepts PEM directly — the DER conversion may not be needed. Check `virt-fw-vars --help`.

- [ ] **Step 2: Generate OVMF vars**

```bash
mise run pull-keys
mise run generate-ovmf-vars
ls -la .ovmf-vars-secure.fd
```
Expected: `.ovmf-vars-secure.fd` created

- [ ] **Step 3: Add `--secure` flag to `boot-vm`**

Modify `mise/tasks/boot-vm` — add a `--secure` flag that uses the secure boot OVMF vars and code:

Add to the USAGE flags:
```bash
#USAGE flag "--secure" help="Boot with OVMF secure boot enabled"
```

In the native qemu path, when `--secure` is set:
- Use `.ovmf-vars-secure.fd` instead of `.ovmf-vars.fd`
- Use the secure boot OVMF code variant if available (`OVMF_CODE_4M.secboot.fd` or equivalent)
- Add `-global driver=cfi.pflash01,secure=on` or the appropriate QEMU secure boot flag

```bash
SECURE="${usage_secure:-}"

if [ "$SECURE" = "true" ]; then
    OVMF_VARS=".ovmf-vars-secure.fd"
    # Use secboot OVMF code if available
    for candidate in \
            /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd \
            /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
            /usr/share/edk2/x64/OVMF_CODE.4m.secboot.fd; do
        [ -f "${candidate}" ] && OVMF_CODE="${candidate}" && break
    done
    if [ ! -f "$OVMF_VARS" ]; then
        echo "ERROR: .ovmf-vars-secure.fd not found — run 'mise run generate-ovmf-vars' first." >&2
        exit 1
    fi
fi
```

- [ ] **Step 4: Generate a sealed disk image**

```bash
mise run pull-keys
mise run seal-uki
# Generate disk from the sealed image (not the unsigned one)
# This may require modifying generate-disk to accept a --tag flag
# or creating a variant that uses localhost/krytis:sealed
sudo podman tag localhost/krytis:sealed localhost/krytis:latest
mise run generate-disk
```

- [ ] **Step 5: Boot with secure boot enabled**

```bash
mise run boot-vm --secure
```
Expected: VM boots successfully with secure boot enabled, reaches login prompt

- [ ] **Step 6: Verify secure boot is active in the guest**

```bash
# SSH into the guest (port 2222)
ssh -p 2222 root@localhost
# Inside the guest:
bootctl status | grep "Secure Boot"
```
Expected: `Secure Boot: enabled (user)`

- [ ] **Step 7: Negative test — boot unsigned image with secure boot**

```bash
# Generate disk from the unsigned image
sudo podman tag localhost/krytis-input:latest localhost/krytis:latest
mise run generate-disk
mise run boot-vm --secure
```
Expected: **boot fails** — firmware rejects the unsigned UKI. This confirms secure boot enforcement is working. The VM should drop to a UEFI shell or firmware boot menu, not reach the OS.

- [ ] **Step 8: Commit**

```bash
git add mise/tasks/generate-ovmf-vars mise/tasks/boot-vm
git commit -m "feat(secure-boot): add OVMF secure boot testing for QEMU

generate-ovmf-vars bakes PK/KEK/db keys into an OVMF vars file using
virt-fw-vars. boot-vm --secure boots with the secure boot OVMF code
and vars, enabling end-to-end secure boot testing in QEMU.

Closes #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 8: Integration test — full secure boot chain

**Files:**
- No new files — this is a verification milestone

**Blocked by:** Tasks 1-7 all complete

- [ ] **Step 1: Full build pipeline**

```bash
mise run pull-keys
mise run generate-auth
mise build
mise run seal-uki
```
Expected: all steps succeed, `localhost/krytis:sealed` produced

- [ ] **Step 2: Generate OVMF vars and sealed disk**

```bash
mise run generate-ovmf-vars
sudo podman tag localhost/krytis:sealed localhost/krytis:latest
mise run generate-disk
```

- [ ] **Step 3: Boot with secure boot**

```bash
mise run boot-vm --secure
```
Expected: boots to login prompt

- [ ] **Step 4: Verify the full chain in the guest**

```bash
ssh -p 2222 root@localhost
# Inside guest:
bootctl status | grep "Secure Boot"      # → enabled (user)
sbverify /boot/EFI/Linux/krytis.efi /boot-keys/db.crt  # → OK (if sbverify is in the image)
ls /usr/lib/bootc/install/secureboot-keys/auto/        # → PK.auth KEK.auth db.auth
```

- [ ] **Step 5: Verify fido2-luks unlock still works**

If the system has a LUKS volume with fido2 enrollment (per #312 analysis):
```bash
# Inside guest, check that the LUKS volume unlocked during boot
lsblk -f | grep crypto_LUKS
systemctl status systemd-cryptsetup@* 2>/dev/null | grep "Active:"
```
Expected: LUKS volume is unlocked (per #312 analysis — if TPM-bound, the mitigations from Task 3 should have resolved this)

- [ ] **Step 6: Negative test — unsigned image rejected**

```bash
sudo podman tag localhost/krytis-input:latest localhost/krytis:latest
mise run generate-disk
mise run boot-vm --secure
```
Expected: boot fails (unsigned UKI rejected by firmware)

- [ ] **Step 7: Open the PR**

```bash
# From the worktree
gh pr create --title "feat(secure-boot): implement EFI secure boot" --body 'Closes #16

## Summary

[Summarize the full implementation: Containerfile expansion, key retrieval via fnox, .auth enrollment, OVMF testing]

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

1. **#312 is a Breakage Gate.** Task 3 (investigation) must complete before Tasks 5 and 7. If the analysis finds that TPM-bound LUKS breaks, the mitigations must be implemented before the full boot chain can be verified. The plan may need revision based on #312's outcome.

2. **`bootc container ukify` is the core.** It handles kernel discovery, composefs digest computation, `kargs.d` resolution, and `ukify build` invocation natively. The Containerfile just needs to pass the right `--secret` mounts and `--secureboot-private-key` / `--secureboot-certificate` args.

3. **Keys never enter the image layer.** podman `--secret` mounts exist only during the `RUN` step. Do not copy keys to a path that persists in the image.

4. **`mise build` (unsigned) must still work.** The `SEAL_SECURE_BOOT` build arg defaults to `false`. The signing step is conditional. This is critical — unsigned development builds must not require signing keys.

5. **CI signing is a prerequisite for registry publishes.** Do not publish unsigned images to a public registry if any user will track it with secure boot enabled. The CI workflow must sign from day one (single Proton Pass PAT).

6. **Microsoft CA URLs may change.** If the `go.microsoft.com` URLs in Task 6 Step 1 don't work, extract Microsoft's UEFI CA certs from an sbctl installation (`/usr/share/secureboot/keys/db/`) or from the UEFI forum.

7. **`virt-fw-vars` accepts PEM directly.** The DER conversion in Task 7 Step 1 may be unnecessary — check `virt-fw-vars --help` and simplify if PEM is accepted.

8. **The `generate-disk` task may need a `--tag` flag.** Currently it hardcodes `localhost/krytis:latest`. For secure boot testing, you need to install from `localhost/krytis:sealed`. The simplest approach (used in Task 7) is `podman tag`, but a `--tag` flag would be cleaner.
