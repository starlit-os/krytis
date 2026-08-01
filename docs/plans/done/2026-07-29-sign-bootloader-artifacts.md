# Sign Bootloader Artifacts — Close-Out Plan (#33)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to run this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confirm all four of #33's acceptance criteria are actually met and close the issue. The signing mechanism itself is **already implemented and merged** — this plan is verification, not new signing code.

**Architecture:** No architecture change. `systemd-boot` is signed with `sbsign --key db.key --cert db.crt` inside the existing `SEAL_SECURE_BOOT` Containerfile stage (merged via PR #370, which closed #32 and implemented this simultaneously — see `Containerfile`'s `sealed` stage and `docs/skills/secure-boot.md`). No shim. What's missing is the *proof* for the two acceptance criteria that require a trusted key to chain against, which didn't exist until #309 landed.

**Tech Stack:** sbsigntools (`sbsign`/`sbverify`, already in the image), the enrollment + OVMF testing infrastructure added by #309.

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only (AGENTS.md)
- All maintenance tasks must be `mise` tasks — no loose shell commands (AGENTS.md)
- Agents MUST NOT push directly to `main` (AGENTS.md)
- `#33` is a child of parent issue `#16` — worktree path `<base>/gh16/33-sign-bootloader-artifacts`, branch `33-sign-bootloader-artifacts`
- **Do not re-implement signing.** `Containerfile`'s `sealed` stage already runs `sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt` against `/usr/lib/systemd/boot/efi/systemd-bootx64.efi`, gated by `SEAL_SECURE_BOOT=true`, keys via `--secret` mounts. Re-deriving this from the issue's original Containerfile sketch (which predates the two-stage `--rootfs` fix) would reintroduce the `Cannot operate on active root filesystem` bug already fixed and documented in `docs/skills/secure-boot.md`.
- ~~This plan is **blocked by `docs/superpowers/plans/2026-07-29-secure-boot-key-enrollment.md` (#309)** for Tasks 2 and 3 below~~ — **unblocked 2026-07-31**: #375 (enrollment, `generate-ovmf-vars`, `boot-vm --secure`) and #407 (the `boot-test` harness) both merged. Note the split: the original text attributed `boot-test` to #375, but it was moved to its own PR during review, so Tasks 2 and 3 depend on **both**.

## Prerequisites

- [x] Read `docs/skills/secure-boot.md` (current signing state + all learnings from #32/#33/#309)
- [x] Read `Containerfile` (confirm the `sealed` stage still matches this plan's assumptions — re-read before touching anything if it's drifted)
  - Drifted since writing, harmlessly for this plan: `bootc container ukify` moved to `Containerfile.seal-uki` (#406) and the `sealed` stage gained `.auth` enrollment-file generation (#375). The `sbsign` of `systemd-bootx64.efi` this plan verifies is unchanged.
- [x] Create a worktree: `git worktree add -b 33-sign-bootloader-artifacts .worktrees/gh16/33-sign-bootloader-artifacts`
- [x] `mise trust` in the worktree
- [x] `files/boot-keys/{PK,KEK,db}.{key,crt}` present and valid (`mise run pull-keys` or `mise run generate-keys`)
- [x] `docs/superpowers/plans/2026-07-29-secure-boot-key-enrollment.md` (#309) merged, or its worktree's `mise run generate-ovmf-vars` / `mise run boot-test --secure` / `mise run generate-disk --image` available in this branch

---

## Task 1: Re-verify `systemd-boot` is signed with db.key/db.crt (AC 1)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "`systemd-boot` signed with `db.key` / `db.crt` (verifiable with `sbverify`)"

- [x] **Step 1: Build the sealed image fresh**

```bash
mise build
mise run seal-uki
```
Expected: both succeed, `localhost/krytis:sealed` produced.

**Result: PASS.** Both ran on a native x86_64 workstation. The `O_TMPFILE`/`ENOTSUP`
failure that blocked this step when the plan was written was specific to the nested
WSL2/podman sandbox, not to the pipeline — see `docs/skills/secure-boot.md`
§ `bootc container ukify`'s composefs digest needs `O_TMPFILE`.

- [x] **Step 2: Extract and verify the signed binary**

```bash
podman run --rm localhost/krytis:sealed cat /usr/lib/systemd/boot/efi/systemd-bootx64.efi > /tmp/systemd-bootx64.efi
sbverify --cert files/boot-keys/db.crt /tmp/systemd-bootx64.efi
```
Expected: `Signature verification OK`.

**Result: PASS.** `Signature verification OK`. The UKI itself verifies against the
same cert too (`Signature verification OK` for `/boot/EFI/Linux/krytis.efi`), which
covers both links of the systemd-boot → UKI chain at rest. Signing identity:
`subject=CN=Database Key`. Extracted with `podman create` + `podman cp` rather than
`podman run … cat` to avoid any chance of stdout mangling a binary.

Negative control on the verifier itself: a freshly generated throwaway cert gives
`Signature verification failed` against the same binary, so the OK above is a real
chain check rather than `sbverify` accepting anything.

- [x] **Step 3: Confirm the unsigned image's copy is NOT signed (sanity check on the gate)**

```bash
podman run --rm localhost/krytis:latest cat /usr/lib/systemd/boot/efi/systemd-bootx64.efi > /tmp/systemd-bootx64-unsigned.efi
sbverify --cert files/boot-keys/db.crt /tmp/systemd-bootx64-unsigned.efi 2>&1 || true
```
Expected: verification fails (no signature present) — confirms `SEAL_SECURE_BOOT=false` correctly skips signing, so `:latest` and `:sealed` are meaningfully different, not accidentally identical.

**Result: PASS.** `No signature table present` / `Signature verification failed`.
Sizes differ as expected — 139776 bytes unsigned vs 142000 signed — so the two tags
really do carry different binaries.

**AC 1: PASS** — Step 2 printed `Signature verification OK` and Step 3 failed as expected.

---

## Task 2: Verify `systemd-boot` boots under secure boot enforcement (AC 2)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "Signed `systemd-boot` boots under secure boot (systemd-boot → UKI chain verified)"
**Blocked by:** ~~#309 Task 5 (`generate-ovmf-vars`, `boot-vm --secure`) or Task 6 (`boot-test`)~~ — cleared: #375 and #407 merged.

- [x] **Step 1: Generate OVMF vars with enrolled keys and a sealed disk**

```bash
mise run generate-ovmf-vars
mise run generate-disk --image localhost/krytis:sealed --disk /tmp/test-33.raw --size 15G
```

**Result: PASS.** `generate-ovmf-vars` produced `.ovmf-vars-secure.fd` with krytis's
PK/KEK/db enrolled. The explicit `generate-disk` call was unnecessary — `boot-test`
installs its own scratch disk per run, so Steps 1 and 2 collapse into Step 2.

- [x] **Step 2: Boot under secure boot enforcement**

```bash
mise run boot-test --image localhost/krytis:sealed --secure
```
Expected: `boot-test PASSED` — this exercises the full `systemd-boot → UKI` chain: firmware verifies `systemd-boot`'s `sbsign` signature (this issue's scope) before executing it, `systemd-boot` then loads and verifies the signed UKI (#32's scope) before booting the kernel. A pass here is proof of the full chain, not just the bootloader link in isolation — there is no way to boot-test *only* the firmware→systemd-boot link without also exercising systemd-boot→UKI, since both must succeed for the VM to reach an OS at all.

**Result: PASS.** `==> boot-test PASSED` on a fresh install of `localhost/krytis:sealed`.
The serial log shows the firmware executing the signed loader —
`BdsDxe: loading Boot0004 "Linux Boot Manager" … \EFI\systemd\systemd-bootx64.efi` —
and the guest then reaching sshd and `systemctl is-system-running` = `degraded`,
so both links of the chain executed.

Note this only became testable after #403 (`fix(bootc): mount root rw and skip
firstboot prompt`): before it, the guest booted with `/etc` and `/var` read-only, so
`ssh-keygen -A` could not write host keys and sshd never started. That was an OS
bug, not a signing one, but it blocked this AC's evidence.

- [x] **Step 3: Negative-test confirmation — unsigned systemd-boot is rejected**

```bash
mise run boot-test --image localhost/krytis:latest --secure --expect-fail
```
Expected: `PASS (expected failure)` — proves the firmware is actually checking the signature (not just ignoring it), which is what makes Step 2's pass meaningful rather than coincidental.

**Result: PASS**, with stronger evidence than this step originally asked for. #407
changed `--expect-fail` so it no longer infers rejection from "SSH never answered" —
which any broken image also produces — but requires the firmware to say so:

```
==> PASS (expected failure): firmware/loader refused the image:
    BdsDxe: failed to load Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0):
            Access Denied -- rejected probably by Secure Boot
```

That is EDK2's BDS refusing the **unsigned** `systemd-bootx64.efi` before any kernel
is reached, which is exactly this AC's claim.

**AC 2: PASS** — Steps 2 and 3 both passed as expected.

---

## Task 3: Verify the signature chains to the enrolled db cert, not just "is signed" (AC 3)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "Signature chains to the enrolled db cert (not just 'is signed')"

- [x] **Step 1: Boot interactively and check `bootctl status` mode**

```bash
mise run boot-vm --disk /tmp/test-33.raw --secure
```
Once booted:
```bash
ssh -p 2222 root@localhost bootctl status
```
Expected: `Secure Boot: enabled (user)`.

**Result: PASS.** `bootctl status` reported exactly:

```
   Secure Boot: enabled (user)
  TPM2 Support: no
  System Token: set
```

Obtained via `boot-test --secure`, which runs the same assertion over its own SSH
probe, rather than an interactive `boot-vm` session — same evidence, no manual step,
and it is now a permanent regression gate instead of a one-off observation.

The distinction that proves this AC: "enabled (user)" specifically means the firmware is in **User Mode** with **PK enrolled** — i.e. it verified the boot chain against a key the firmware was told to trust via enrollment (krytis's own PK/KEK/db, baked into `.ovmf-vars-secure.fd` by `mise run generate-ovmf-vars`, matching what real hardware would get via the `loader/keys/auto/*.auth` → firmware enrollment path). Contrast with "Setup Mode" (no PK enrolled, firmware accepts anything unsigned) or a hypothetical world where `sbverify` passes locally but firmware enrollment never happened — in that case the boot would fail outright (Task 2's negative-test logic in reverse: signed-but-untrusted is exactly as rejected as unsigned, from the firmware's perspective). A successful boot in `(user)` mode is therefore direct proof the signature chains to a cert the firmware was explicitly told to trust, not merely that a signature blob is attached to the binary.

- [x] **Step 2: Cross-check the enrolled cert matches `db.crt`** — *treated as satisfied by an equivalent, stronger check*

```bash
ssh -p 2222 root@localhost cat /sys/firmware/efi/efivars/db-* 2>/dev/null | tail -c +5 > /tmp/enrolled-db.bin || true
openssl x509 -in files/boot-keys/db.crt -outform DER -out /tmp/expected-db.der
```
Since the QEMU firmware's live `db` EFI variable is DER-encoded within an EFI signature list wrapper (not a bare cert), exact byte comparison needs `efi-readvar`/`sig-list-to-certs`-style parsing rather than a raw diff. If those tools aren't available in the guest, the `(user)` mode check in Step 1 combined with the negative test in Task 2 Step 3 (unsigned images from the *same* build pipeline are rejected by the *same* firmware) is already sufficient evidence — Step 1 shows the specific key we enrolled is what's trusted, and Task 2 shows the firmware isn't simply permissive. Treat Step 2 as a nice-to-have confirmation, not a blocking gate, if the guest lacks the tooling to parse the live variable.

**Result: not run as written** — took this plan's own escape hatch, but with better
evidence than "(user) mode plus the negative test". Two independent facts pin the cert
identity directly:

1. `sbverify --cert files/boot-keys/db.crt` succeeds on both `systemd-bootx64.efi` and
   the UKI (Task 1), and fails with a throwaway cert. So the binaries are signed by
   **this specific** `db.crt` — `subject=CN=Database Key`,
   `sha256 Fingerprint=5C:D2:AA:08:…:CE:D1`.
2. Under a firmware whose `db` was populated from that same `db.crt` by
   `generate-ovmf-vars`, those binaries load, while a binary with **one byte flipped**
   inside the UKI is refused with `Access denied` (verified while hardening #407's
   `--expect-fail`). Signature validity — not mere presence — is what the firmware
   is gating on.

Together those cover what the byte comparison was meant to establish, without needing
`efi-readvar` in the guest.

**AC 3: PASS** — `bootctl status` shows `(user)` mode, and the signing cert is
identified positively rather than inferred.

---

## Task 4: Confirm no-shim is documented as deliberate (AC 4)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "No shim in the initial implementation (documented as deliberate)"

- [x] **Step 1: Confirm no shim in the image**

```bash
podman run --rm localhost/krytis:sealed find / -xdev -iname "*shim*.efi" 2>/dev/null
```
Expected: empty output.

**Result: PASS.** Empty. Also checked the wider pattern the issue's AC used —
`find /boot /usr/lib/systemd/boot /usr/share/EFI /boot/EFI -iname "*shim*"` — likewise
empty, so there is no shim under any name or extension.

- [x] **Step 2: Confirm the deliberate decision is documented**

```bash
grep -n "shim" docs/plan/secure-boot-uki.md
```
Expected: the "Architecture decision: no shim" section from the original issue is present in `docs/plan/secure-boot-uki.md` (§ "2. Bootloader signing: install-time, no shim (#33)"), stating the rationale (user enrolls db key directly via `loader/keys/`, shim only needed for MOK fallback / Microsoft-only firmware) and the explicit rejection of the "ship pre-signed shim" alternative.

**Result: PASS.** Present at `docs/plan/secure-boot-uki.md:164`
§ "2. Bootloader signing: install-time, no shim (#33)", with the rationale at :170 and
the explicit "Rejected alternative: Ship pre-signed shim + systemd-boot in the image"
at :172.

**AC 4: PASS** — Step 1 empty, Step 2 finds the documented decision.

---

## Task 5: Close #33

**Files:** No code changes.

**Blocked by:** Tasks 1-4 all PASS. — all four PASS as recorded above.

- [x] **Step 1: Confirm every AC has a checked box above**

Re-read Tasks 1-4's PASS conditions. If any failed, stop and investigate before closing — do not close on a partial result.

- [x] **Step 2: Close the issue with evidence**

**Deviation from the plan as written:** the issue is closed by merging this PR
(`Closes #33` in the PR body), not by an agent running `gh issue close`. Merging is a
human gate under AGENTS.md, and closing the issue out-of-band would decide the outcome
before the reviewer sees the evidence. The `gh issue close` command below is retained
for the record of what was originally intended.

```bash
gh issue close 33 --comment 'All four acceptance criteria verified:

- [x] systemd-boot signed with db.key/db.crt — sbverify --cert db.crt: Signature verification OK
- [x] Boots under secure boot (systemd-boot → UKI chain) — `mise run boot-test --image localhost/krytis:sealed --secure` PASSED; negative test (unsigned, --expect-fail) also PASSED
- [x] Signature chains to the enrolled db cert — `bootctl status` reports `Secure Boot: enabled (user)` against krytis own enrolled PK/KEK/db (baked via `mise run generate-ovmf-vars`, mirroring the real-hardware loader/keys/auto/*.auth enrollment path from #309)
- [x] No shim — confirmed absent from the image; decision documented in docs/plan/secure-boot-uki.md § "Bootloader signing: install-time, no shim (#33)"

The signing implementation itself shipped in #370 (which closed #32). This
verification was blocked on #309s enrollment + OVMF secure-boot testing
infrastructure landing first — see docs/superpowers/plans/2026-07-29-secure-boot-key-enrollment.md.

Assisted-by: Claude Sonnet 4.6'
```

No commit needed for this task — nothing in the tree changes. If any prior task surfaced a real gap (not just missing test infra), open a new issue for it instead of silently closing #33 with an unmet AC.

---

## Notes for the implementer

1. **There is no code to write here beyond what #309 already delivers.** If you find yourself writing a Containerfile diff, stop — re-read `docs/skills/secure-boot.md` and `Containerfile`, the signing step is already there.
2. **Do not run this plan before #309 has landed.** Tasks 2 and 3 will fail for infrastructure reasons (`mise run generate-ovmf-vars`/`boot-test` won't exist), not because signing is broken — don't misdiagnose a missing-dependency failure as a signing regression.
3. **If #309's plan changes the enrollment mechanism** (e.g. `bootc`'s `secureboot-keys` layout turns out to need adjustment during implementation), re-verify this plan's Task 2/3 commands still match the actual `mise run boot-test`/`generate-ovmf-vars` flag names before running them.
