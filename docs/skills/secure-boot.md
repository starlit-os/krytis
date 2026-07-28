# Secure Boot Skills

## Signed UKI PCR changes do not affect FIDO2 or passphrase LUKS unlock

TPM PCR measurements (PCR 4 = boot manager, PCR 7 = secure boot policy, PCR 11 = UKI sections) are only consumed by **TPM-bound unseal operations**. krytis's two actual unlock paths ignore them entirely:

- **FIDO2** — LUKS2-token-plugin path (`attach_luks2_by_fido2_via_plugin()`, see `docs/skills/fido2.md`): challenge-response with the security key. No TPM involvement at any point.
- **Passphrase** — plain KDF against the LUKS header. Cryptographically independent of PCR state.

So enabling secure boot / switching to a signed UKI (which flips PCR 7 and changes PCR 4's extension sequence) cannot lock out a fleet that has **no TPM-bound enrollments**. Verified for krytis as of #312: zero TPM-bound volumes, no TPM kargs shipped, no TPM enrollment tooling in the image. The `tpm2-tss`/`tpm2-tools`/`tpm2-pkcs11` packages in `base-system.bst` are libraries, not enrollment paths — the population stays empty unless a user hand-runs `systemd-cryptenroll --tpm2-device`.

**Decision rule:** when a boot-chain change "breaks TPM PCRs," first enumerate which enrolled unlock mechanisms actually read those PCRs. If the answer is none, the PCR delta is a non-issue — don't build mitigations for a population of zero.

## Under a UKI, the LUKS regression risk is the cmdline bake, not PCRs

With a UKI the kernel cmdline is **frozen inside the signed PE** — `bootc kargs` and post-install `kargs.d` edits have no effect. `rd.luks.options=fido2-device=auto` (`files/bootc-config/30-fido2-luks.toml`) must be baked into `.cmdline` at seal time by `bootc container ukify`'s `get_kargs_in_root()`, or FIDO2 unlock silently regresses to passphrase fallback. Verify on every sealed build:

```bash
ukify inspect /boot/EFI/Linux/krytis.efi    # or: objdump -s -j .cmdline <uki>
```

…then confirm on real hardware: enroll via `mise fido2:enroll-luks`, reboot, expect key-touch unlock with no passphrase prompt.

## Don't cargo-cult travier's `systemd-tpm2-*` masks or `ukify --measure`

travier's `fedora-atomic-desktops-sealed` `uki.sh` uses `ukify --measure` and masks `systemd-tpm2-setup-early.service`, `systemd-tpm2-setup.service`, `systemd-pcrphase.service`, `systemd-pcrproduct.service`. Both are workload-specific, not defaults:

- `--measure` populates PCR 11 for TPM attestation/unlock flows. With no TPM-bound volumes it buys nothing and makes PCR 11 part of the boot contract a future TPM design must inherit. Re-evaluate inside a TPM-LUKS feature, where PCR selection (7+11 vs others) is designed as a whole.
- The masks work around specific hardware TPM hangs across a large Fedora Atomic fleet. Masking four units "just in case" — with no observed failures — is debt a future TPM feature has to unmask and debug.

**Escalation rule:** only mask if sealed-boot verification or real hardware shows a `systemd-tpm2-*`/`systemd-pcr*` unit failing or hanging (`systemctl --failed`, `journalctl -b -p err`). Then mask per travier's list and record the finding in the TPM-LUKS issue.
