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
- This plan is **blocked by `docs/superpowers/plans/2026-07-29-secure-boot-key-enrollment.md` (#309)** for Tasks 2 and 3 below — those criteria need enrolled keys + OVMF secure boot testing infrastructure that doesn't exist until #309 ships.

## Prerequisites

- [ ] Read `docs/skills/secure-boot.md` (current signing state + all learnings from #32/#33/#309)
- [ ] Read `Containerfile` (confirm the `sealed` stage still matches this plan's assumptions — re-read before touching anything if it's drifted)
- [ ] Create a worktree: `git worktree add -b 33-sign-bootloader-artifacts .worktrees/gh16/33-sign-bootloader-artifacts`
- [ ] `mise trust` in the worktree
- [ ] `files/boot-keys/{PK,KEK,db}.{key,crt}` present and valid (`mise run pull-keys` or `mise run generate-keys`)
- [ ] `docs/superpowers/plans/2026-07-29-secure-boot-key-enrollment.md` (#309) merged, or its worktree's `mise run generate-ovmf-vars` / `mise run boot-test --secure` / `mise run generate-disk --image` available in this branch

---

## Task 1: Re-verify `systemd-boot` is signed with db.key/db.crt (AC 1)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "`systemd-boot` signed with `db.key` / `db.crt` (verifiable with `sbverify`)"

- [ ] **Step 1: Build the sealed image fresh**

```bash
mise build
mise run seal-uki
```
Expected: both succeed, `localhost/krytis:sealed` produced.

- [ ] **Step 2: Extract and verify the signed binary**

```bash
podman run --rm localhost/krytis:sealed cat /usr/lib/systemd/boot/efi/systemd-bootx64.efi > /tmp/systemd-bootx64.efi
sbverify --cert files/boot-keys/db.crt /tmp/systemd-bootx64.efi
```
Expected: `Signature verification OK`.

- [ ] **Step 3: Confirm the unsigned image's copy is NOT signed (sanity check on the gate)**

```bash
podman run --rm localhost/krytis:latest cat /usr/lib/systemd/boot/efi/systemd-bootx64.efi > /tmp/systemd-bootx64-unsigned.efi
sbverify --cert files/boot-keys/db.crt /tmp/systemd-bootx64-unsigned.efi 2>&1 || true
```
Expected: verification fails (no signature present) — confirms `SEAL_SECURE_BOOT=false` correctly skips signing, so `:latest` and `:sealed` are meaningfully different, not accidentally identical.

**AC 1: PASS if Step 2 printed `Signature verification OK` and Step 3 failed as expected.**

---

## Task 2: Verify `systemd-boot` boots under secure boot enforcement (AC 2)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "Signed `systemd-boot` boots under secure boot (systemd-boot → UKI chain verified)"
**Blocked by:** #309 Task 5 (`generate-ovmf-vars`, `boot-vm --secure`) or Task 6 (`boot-test`)

- [ ] **Step 1: Generate OVMF vars with enrolled keys and a sealed disk**

```bash
mise run generate-ovmf-vars
mise run generate-disk --image localhost/krytis:sealed --disk /tmp/test-33.raw --size 15G
```

- [ ] **Step 2: Boot under secure boot enforcement**

```bash
mise run boot-test --image localhost/krytis:sealed --secure
```
Expected: `boot-test PASSED` — this exercises the full `systemd-boot → UKI` chain: firmware verifies `systemd-boot`'s `sbsign` signature (this issue's scope) before executing it, `systemd-boot` then loads and verifies the signed UKI (#32's scope) before booting the kernel. A pass here is proof of the full chain, not just the bootloader link in isolation — there is no way to boot-test *only* the firmware→systemd-boot link without also exercising systemd-boot→UKI, since both must succeed for the VM to reach an OS at all.

- [ ] **Step 3: Negative-test confirmation — unsigned systemd-boot is rejected**

```bash
mise run boot-test --image localhost/krytis:latest --secure --expect-fail
```
Expected: `PASS (expected failure)` — proves the firmware is actually checking the signature (not just ignoring it), which is what makes Step 2's pass meaningful rather than coincidental.

**AC 2: PASS if Step 2 and Step 3 both pass as expected.**

---

## Task 3: Verify the signature chains to the enrolled db cert, not just "is signed" (AC 3)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "Signature chains to the enrolled db cert (not just 'is signed')"

- [ ] **Step 1: Boot interactively and check `bootctl status` mode**

```bash
mise run boot-vm --disk /tmp/test-33.raw --secure
```
Once booted:
```bash
ssh -p 2222 root@localhost bootctl status
```
Expected: `Secure Boot: enabled (user)`.

The distinction that proves this AC: "enabled (user)" specifically means the firmware is in **User Mode** with **PK enrolled** — i.e. it verified the boot chain against a key the firmware was told to trust via enrollment (krytis's own PK/KEK/db, baked into `.ovmf-vars-secure.fd` by `mise run generate-ovmf-vars`, matching what real hardware would get via the `loader/keys/auto/*.auth` → firmware enrollment path). Contrast with "Setup Mode" (no PK enrolled, firmware accepts anything unsigned) or a hypothetical world where `sbverify` passes locally but firmware enrollment never happened — in that case the boot would fail outright (Task 2's negative-test logic in reverse: signed-but-untrusted is exactly as rejected as unsigned, from the firmware's perspective). A successful boot in `(user)` mode is therefore direct proof the signature chains to a cert the firmware was explicitly told to trust, not merely that a signature blob is attached to the binary.

- [ ] **Step 2: Cross-check the enrolled cert matches `db.crt`**

```bash
ssh -p 2222 root@localhost cat /sys/firmware/efi/efivars/db-* 2>/dev/null | tail -c +5 > /tmp/enrolled-db.bin || true
openssl x509 -in files/boot-keys/db.crt -outform DER -out /tmp/expected-db.der
```
Since the QEMU firmware's live `db` EFI variable is DER-encoded within an EFI signature list wrapper (not a bare cert), exact byte comparison needs `efi-readvar`/`sig-list-to-certs`-style parsing rather than a raw diff. If those tools aren't available in the guest, the `(user)` mode check in Step 1 combined with the negative test in Task 2 Step 3 (unsigned images from the *same* build pipeline are rejected by the *same* firmware) is already sufficient evidence — Step 1 shows the specific key we enrolled is what's trusted, and Task 2 shows the firmware isn't simply permissive. Treat Step 2 as a nice-to-have confirmation, not a blocking gate, if the guest lacks the tooling to parse the live variable.

**AC 3: PASS if Task 1's `bootctl status` shows `(user)` mode.**

---

## Task 4: Confirm no-shim is documented as deliberate (AC 4)

**Files:** No changes — verification only.

**Issue:** #33 acceptance criterion: "No shim in the initial implementation (documented as deliberate)"

- [ ] **Step 1: Confirm no shim in the image**

```bash
podman run --rm localhost/krytis:sealed find / -xdev -iname "*shim*.efi" 2>/dev/null
```
Expected: empty output.

- [ ] **Step 2: Confirm the deliberate decision is documented**

```bash
grep -n "shim" docs/plan/secure-boot-uki.md
```
Expected: the "Architecture decision: no shim" section from the original issue is present in `docs/plan/secure-boot-uki.md` (§ "2. Bootloader signing: install-time, no shim (#33)"), stating the rationale (user enrolls db key directly via `loader/keys/`, shim only needed for MOK fallback / Microsoft-only firmware) and the explicit rejection of the "ship pre-signed shim" alternative.

**AC 4: PASS if Step 1 is empty and Step 2 finds the documented decision** — both already true as of this plan's writing (verified during research; no action needed beyond confirming they still hold).

---

## Task 5: Close #33

**Files:** No code changes.

**Blocked by:** Tasks 1-4 all PASS.

- [ ] **Step 1: Confirm every AC has a checked box above**

Re-read Tasks 1-4's PASS conditions. If any failed, stop and investigate before closing — do not close on a partial result.

- [ ] **Step 2: Close the issue with evidence**

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
