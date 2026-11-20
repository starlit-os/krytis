# Masks systemd-pcrlock-make-policy.service (#1584).
#
# systemd enables the unit through its own preset, and it runs on every boot whose
# UKI systemd-stub measured (ConditionSecurity=measured-uki): any real machine with
# a TPM. Its first run allocates a TPM2 NV index and writes
# /var/lib/systemd/pcrlock.json. Every later run has to satisfy the policy already
# stored in that NV index before it may rewrite it. The automatic access PIN is
# sealed under a policy bound to the same NV index, so it can't help either.
#
# Once a firmware update changes PCR 0 (or a firmware setting changes PCR 1), the
# old policy can never be satisfied again. The unit then fails on every boot and
# leaves `systemctl is-system-running` at `degraded`. Seen on adora (the #535
# ThinkPad): its persistent journal has the failure on every boot from 2026-08-19,
# first on PCR 1 and on PCR 0 since 2026-09-01. On 2026-11-20, pcrlock.json and the
# firmware lock directories under /var/lib/pcrlock.d still dated from 2026-08-07,
# when the unit first ran, and image 26.08.202611201237 failed with:
#
#   Esys_PolicyOR() Esys Finish ErrorCode (0x000001c4)
#   None of the alternative values for PCR 0 encoded in policy match the current
#   TPM state.
#
# Nothing consumes the policy. krytis enrolls FIDO2 and passphrase LUKS slots,
# never TPM2 (docs/skills/secure-boot.md § Signed UKI PCR changes do not affect
# FIDO2 or passphrase LUKS unlock), and ships no sysupdate.d transfers, so
# systemd-sysupdate-notify-pcrlock.socket never fires. The unit is pure liability:
# it bricks its own NV index on the first firmware update.
#
# Only make-policy is masked. The other systemd-pcrlock-*.service units only write
# .pcrlock files under /var/lib/pcrlock.d, succeed, and are what a future
# make-policy would read. systemd-pcrphase*, systemd-pcrextend and
# systemd-tpm2-setup* keep running: the measured-boot chain is unchanged.
#
# The mask lives in /etc, the same pattern as config/networkd-mask.bst. bootc's
# three-way /etc merge adds it to installed machines, which already carry
# systemd's sysinit.target.wants symlink in /etc. A wants symlink to a masked unit
# pulls in nothing.
#
# Removal condition: TPM-bound LUKS (#368) designs a PCR policy with a recovery
# story for firmware updates. That work decides whether make-policy comes back.
# Machines that ran the unit before this mask keep a stale NV index and
# pcrlock.json. They're harmless while nothing reads them, and
# `systemd-pcrlock remove-policy` frees both.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -d "%{install-root}%{sysconfdir}/systemd/system"
    ln -sf /dev/null "%{install-root}%{sysconfdir}/systemd/system/systemd-pcrlock-make-policy.service"
