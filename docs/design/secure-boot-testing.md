# Secure Boot & Sealed Image — End-to-End Testing Plan

How to convince yourself a boot-chain change actually works, what each gate can and
cannot prove, and what is still untested. Written after #371 and #438, where two
separate gates were green while the thing they appeared to test was broken.

**The governing lesson:** every gate here has a blind spot, and the blind spots are
not obvious from the command name. `boot-test --secure` passed for months against an
image whose own key files enrolled nothing, because it never used them. Read the
"cannot prove" column before trusting a pass.

---

## 1. Change → what to run

Find the row that describes your change and run everything in it. Tiers are defined
in §2.

| You changed | Run | Why |
|---|---|---|
| Docs only | T0 | `docs-links` catches dead `docs/…` references |
| A `mise` task, `scripts/` | T0 + whatever that task gates | Task flags are silently ignorable — see trap T-6 |
| An element that is not kernel/systemd/bootc | T1 | Composition and lint |
| `elements/core/systemd*`, `elements/stacks/bootc.bst`, the kernel | T1 + T2 + T3 | systemd-boot and systemd-stub change, so the whole signed chain changes |
| `Containerfile` (the `sealed` stage), `files/boot-keys/`, `files/microsoft-uefi-certs/` | T1 + **T2 in full** | This is the `.auth`/signing surface. #438 lived here |
| `Containerfile.seal-uki`, anything affecting the composefs digest | T1 + T2 + T3 | The digest is verified at install time, not build time |
| `elements/config/secureboot-loader-conf.bst`, `loader.conf` handling | T2 (`enroll-test`) + T4 | Enrollment policy is firmware-visible; the VM answer differs from hardware |
| `mise/tasks/build-iso`, `verify-iso-payload`, dakota-iso payload path | T3 | The ISO is the only artifact that exercises the offline store |
| Kernel cmdline / `files/bootc-config/*.toml` | T1 + T2 + T4 | A UKI freezes the cmdline; FIDO2 unlock depends on it (trap T-9) |
| Publishing (`push`, `publish.yml`) | T1 + a manual `--sealed` push review | CI never builds sealed images (§6, gap G-1) |
| Nothing — periodic confidence check | T0 + T1 + T2 | ~10 minutes, catches drift from dependency bumps |

---

## 2. Tiers

Runtimes are measured on the dev box (8-core Zen 3, KVM, btrfs), not estimated.

| Tier | Scope | Cost | Root? |
|---|---|---|---|
| **T0** | Static checks | seconds | no |
| **T1** | Build gates | ~6 min | no |
| **T2** | VM boot gates | ~1–10 min | mostly no |
| **T3** | Full ISO install E2E | ~20–40 min | no |
| **T4** | Real hardware | manual | physical access |

Prerequisites for T2/T3: `/dev/kvm` readable and writable, `qemu-system-x86_64`,
`edk2-ovmf` **secboot** variant, `virt-fw-vars`, `mtools`, `unsquashfs`, `python3`.
On a Krytis host `sshpass`, `socat`, `xorriso` and `mksquashfs` are absent by design —
the tooling already routes around all four. T3 needs ~60 GB free on `/var/tmp`
(4.5 GB ISO, 7 GB payload archive, a 64 GB sparse install disk, a 16 GB scratch disk).

---

## 3. The gates

### T0 — static (seconds, no VM)

| Gate | Proves | Cannot prove |
|---|---|---|
| `mise run docs-links` | every `docs/…` reference resolves | nothing about behaviour |
| `scripts/parse-efi-auth.py <f.auth>` | each signature list carries a parseable certificate, and prints its subject | that the firmware will *accept* the file (signature, timestamp ordering, variable name) |
| `mise run generate-ovmf-vars` | the test varstore's db matches the sealed image's `db.auth` byte count, and refuses to finish when it does not | that either one is *correct* — only that they agree |
| `mise run verify-iso-payload` | the ISO's embedded store holds the exact image ID expected | that the image boots |

`parse-efi-auth.py` is the cheapest gate that would have caught #438: the shipped
files reported `SignatureSize=16` on all five entries.

### T1 — build gates (~6 min, no VM)

| Gate | Time | Proves | Cannot prove |
|---|---|---|---|
| `mise run lint` | ~2 min | the Containerfile builds; `bootc container lint` passes | anything about the sealed stage (`SEAL_SECURE_BOOT=false` there) |
| `mise run seal-uki` | ~3.5 min | the two-phase sealed build succeeds; `sbsign` signs the loader; `assert_esl` confirms every signature list is non-empty; `bootc container ukify` computes a digest | that the digest *matches at install time* — only T3 checks that |

`assert_esl` is a build-time gate, so a regression of #438 fails here rather than in
firmware. It reads each list's `SignatureSize` field; 16 means no certificate.

### T2 — VM boot gates (no root except where noted)

| Gate | Time | Proves | Cannot prove |
|---|---|---|---|
| `mise run enroll-test` | **8 s** | the image's **own** `.auth` files enrol into a setup-mode firmware, and the firmware then verifies the signed loader | anything about the OS, the UKI, composefs, or the installer — it boots an ESP with three files on it |
| `mise run boot-test` | ~3 min ⚠ root | image → disk install, boots, reaches `running`, SSH health assertions | nothing about the ISO path or enrollment |
| `mise run boot-test --secure` | ~3 min ⚠ root | the signed image boots against a **pre-enrolled** varstore | **it never touches `loader/keys/auto`** — this is exactly the blind spot that hid #438 |
| `mise run boot-test --secure --expect-fail` | ~8 min ⚠ root | enforcement refuses the unsigned image, asserted on the firmware's own rejection line | that the *signature* is what was refused (any failure in that image looks the same) — the byte-flip variant isolates it |
| `mise run boot-test --reuse-disk <disk> [--secure]` | 20 s–4 min | boot + health on an already-installed disk, unprivileged | any first-boot behaviour: host keys, `systemd-firstboot`, `/etc` writability, and enrollment policy (trap T-4) |

⚠ = `generate-disk` needs `CAP_SYS_ADMIN` for loop devices and a real mount; no
rootless path exists. On a host without passwordless sudo, use T3 instead — it
installs inside a VM and needs no host root at all.

`enroll-test` and `boot-test --secure` answer *different questions* and neither
substitutes for the other. Run both.

### T3 — full ISO install E2E (no root)

```bash
mise run build-iso --sealed --debug        # ~6-8 min, runs verify-iso-payload itself
mise run iso-install-test --secure         # ~4 min, install + enforced boot
mise run build-iso --debug                 # ~11 min, the unsigned control
mise run iso-install-test --secure --expect-fail   # ~11 min, negative
```

| Gate | Proves | Cannot prove |
|---|---|---|
| `build-iso --sealed` | the payload is embedded byte-identically (store image ID equals `:sealed`'s) | that the composefs digest survives — inferred from byte identity, confirmed at install |
| `iso-install-test --secure` | ISO → live session → fisherman → `bootc install` → boot under enforcement, plus `recipe.json`/offline-store/`targetImgref` all working | first-boot **self**-enrollment (the varstore is pre-enrolled here) |
| `iso-install-test --secure --expect-fail` | an unsigned install is refused under enforcement | same signature-isolation caveat as T2 |

`--debug` is mandatory for both install tests: the installer is driven over SSH and
krytis is pubkey-only without the debug drop-in. The task refuses a non-debug ISO in
0.2 s rather than timing out (trap T-7).

**Self-enrollment on the real artifact** is not yet a task, and is the strongest
single check that exists. After `iso-install-test`, boot the disk it left behind
against a *pristine* varstore:

```bash
cp --reflink=auto /var/tmp/dakota-sealed-install.img disk.raw
cp /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.fd vars.fd
qemu-system-x86_64 -enable-kvm -m 4096 -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive file=disk.raw,format=raw,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -display none -serial file:serial.log -daemonize -pidfile qemu.pid
```

Expect, in `serial.log`: `BdsDxe: starting` → `Enrolling secure boot keys` →
`successfully enrolled` → **`BdsDxe: starting` again** → `systemd-boot@` →
`systemd-stub@`. Inject an SMBIOS-credential probe (see trap T-1) to read
`bootctl status` → `Secure Boot: enabled (user)` and `systemctl is-system-running`
→ `running`. ~66 s. Promoting this to `mise run selfenroll-test` is proposed gap G-3.

### T4 — real hardware (manual, per release)

Nothing below has ever been executed. It is the honest edge of our coverage.

- [ ] Firmware in Setup Mode, `secure-boot-enroll manual`: the systemd-boot menu
      offers the key set, the user selects it, enrollment succeeds, the machine boots
      enforcing. (In a VM `if-safe` auto-enrols and never shows the prompt, so the
      prompt path is untested.)
- [ ] OEM keys are replaced, not merged — confirm the documented limitation is what
      users actually see, and that the machine still boots.
- [ ] A Microsoft-signed EFI binary still runs (Option ROM, UEFI shell, or a Windows
      dual-boot entry) — this is the *only* real test of bundling the MS CAs into
      `db.auth`. No offline MS-signed binary is available for the VM path.
- [ ] FIDO2 LUKS unlock under a sealed UKI: `mise fido2:enroll-luks`, reboot, expect a
      key-touch unlock with no passphrase prompt. The `rd.luks.options=` bake is
      verified statically; the unlock is not.
- [ ] `bootc upgrade` to a newer sealed image, then reboot, still enforcing.
- [ ] `bootc rollback` under enforcement.

---

## 4. Release sequence for a sealed image

Ordered so each step's failure is cheap and unambiguous.

1. `mise run lint` — Containerfile sane.
2. `mise run seal-uki` — sealed build, `assert_esl` passes.
3. `scripts/parse-efi-auth.py` on the image's three `.auth` files — expect
   `CN=Database Key` + both Microsoft CAs, `CN=Key Exchange Key`, `CN=Platform Key`.
4. `mise run generate-ovmf-vars` — must report `Matches …db.auth (4353 bytes)`.
5. `mise run enroll-test` — 8 s, the image's own keys work.
6. `mise run boot-test --secure` (or T3 if no root) — the signed image boots enforcing.
7. `mise run build-iso --sealed --debug` — embed gate passes.
8. `mise run iso-install-test --secure` — real install path.
9. Self-enrollment boot (§3 T3) — the scenario a user actually hits.
10. `mise run iso-install-test --secure --expect-fail` — the negative still fires.
11. T4 checklist on at least one physical machine before calling a sealed image
    releasable.

**Order matters at step 2 vs 6:** `mise run lint` rebuilds `:latest`, which makes
`:sealed` look stale to `scripts/ensure-sealed-image.sh` and triggers a re-seal on the
next `--sealed` build. Run lint first, or accept the extra 3.5 minutes.

---

## 5. Traps that have already produced wrong conclusions

Each of these cost real debugging time. They are ranked by how convincingly they lie.

- **T-1 · A sealed system cannot be judged from the serial console.** `console=ttyS0`
  is a kernel argument and a UKI freezes those, so a sealed guest prints nothing after
  `systemd-stub@`. A serial grep for `Reached target Graphical Interface` reports a
  timeout for a perfectly healthy boot. Use SMBIOS type-11 systemd credentials, which
  need no cmdline. *"Nothing after `systemd-stub@`" means the harness went blind, not
  that the boot failed.*
- **T-2 · `boot-test --secure` says nothing about the image's own keys.** It boots a
  varstore `virt-fw-vars` pre-enrolled, bypassing `loader/keys/auto` entirely. Pair it
  with `enroll-test`, always.
- **T-3 · A silent guest is INCONCLUSIVE, never a rejection.** Negative tests must
  assert the firmware's `Access Denied`/`Security Violation` line. "SSH never answered"
  is true of every broken image.
- **T-4 · An install disk stays a first-boot disk forever.** `boot-test` always boots a
  *copy*, so the source is never mutated. Reading `/boot/loader/loader.conf` inside such
  a guest shows `secure-boot-enroll manual` written seconds earlier by the first-boot
  oneshot — long after the firmware already chose. That is how "manual doesn't work"
  got into the skill file, wrongly.
- **T-5 · Header counts are not contents.** `sig-list-to-certs` reported three X509
  headers in a `db.esl` that contained three *empty* lists, and the zero-byte
  extractions were written off as a tool quirk. Arithmetic is the check: one entry is
  `28 + 16 + len(DER)` bytes, so anything near 44 is empty.
- **T-6 · A `just` recipe's `VAR={{var}}` prefix shadows the environment.** Every
  `build-iso` flag (`--output-dir`, `--workdir`, `--compression`, `--debug`) was a
  silent no-op for months. Grep the build log for the assignment; do not trust that a
  flag arrived.
- **T-7 · An ISO without `--debug` is not drivable.** krytis is pubkey-only, so the
  installer's password login is refused and the readiness probe times out looking like
  a network fault.
- **T-8 · "Keys enrolled, Secure Boot off" is not representable in OVMF.** It derives
  Secure Boot from PK presence and `virt-fw-vars` has no disable switch. To test an
  unenforced boot, delete `loader/keys` from the *fixture's* ESP with `mtools`.
- **T-9 · The UKI cmdline is a signing-time decision.** `bootc kargs` and `kargs.d`
  edits do nothing on a sealed system. Anything a test needs to inject must arrive as
  a credential, not a karg.
- **T-10 · A stale sibling `dakota-iso` checkout silently builds a broken sealed ISO.**
  `iso-sd-boot.sh` ignores env vars it does not know. `build-iso --sealed` now greps
  the sibling for `PAYLOAD_SEALED`/`PAYLOAD_REF` and refuses up front.

---

## 6. Coverage gaps, ranked

### G-1 · No CI runs any of this (highest risk)

`.github/workflows/` contains `publish.yml`, `track-bst-sources.yml` and
`cache-warm.yml`. **Nothing** runs `lint`, `seal-uki`, `boot-test`, `enroll-test`,
`build-iso` or any QEMU test. Every gate above is a thing a human remembers to run.

Worse, `publish.yml` runs `mise run build` + `mise run push` — **unsigned only**. No
automation ever produces a sealed image, so `ghcr.io/starlit-os/krytis:sealed` exists
only because someone ran `mise run push --sealed` by hand. A sealed ISO bakes that tag
as `targetImgref`, which means installed sealed systems track a manually refreshed tag.

What could move to CI today, in order of value per minute:

| Candidate | Feasible on a GitHub runner? |
|---|---|
| T0 static gates + `parse-efi-auth.py` | yes — seconds, no privileges |
| `mise run lint` | yes — already how the image is built in `publish.yml` |
| `mise run seal-uki` + `assert_esl` | yes, but needs the signing keys as secrets — a Security Gate decision |
| `mise run enroll-test` | needs nested KVM. Blacksmith runners are used already; whether they expose `/dev/kvm` is unverified — check before designing around it |
| `boot-test --secure` | needs KVM **and** root for `generate-disk` |
| T3 ISO E2E | needs KVM + ~60 GB scratch + ~40 min |

`enroll-test` is the standout: 8 seconds, no root, and it guards the failure mode that
actually shipped. If KVM is available it should be the first boot gate in CI.

### G-2 · `bootc upgrade` on a sealed system is untested

The sealed ISO points installed systems at `…/krytis:sealed`. Nobody has ever upgraded
one. Both directions are unproven: that a newer sealed image installs over an older
one, and that the result still boots enforcing (a new systemd means a new
systemd-boot/stub, hence a new signature and a new composefs digest).

Proposed `mise run upgrade-test`: run a local registry container, push two sealed
builds, install the older from an ISO, `bootc upgrade`, reboot, assert enforcing and
healthy. Cost is roughly two seal-uki runs plus a T3 cycle.

### G-3 · Self-enrollment is a manual recipe, not a task

§3's strongest check is copy-paste shell. It should be `mise run selfenroll-test`,
sharing `enroll-test`'s verdict logic and `boot-test`'s credential-probe plumbing.

### G-4 · Key rotation is untested

Enrolling a *second* generation of keys over the first exercises UEFI's
authenticated-variable rollback protection, which compares the `EFI_TIME` in the
`.auth`. This is not academic: `sbvarsign` writes the month from a 0-based `tm_mon`
(#438), which is why signing stayed with `sign-efi-sig-list`. A rotation test would
have caught that class of bug directly. Proposed: enrol set A, then set B built later,
assert the firmware accepts B and boots a B-signed loader.

### G-5 · `dbx` is never touched

The varstore carries a 76-byte `dbx` from the OVMF template. We neither ship
revocations nor test that a revoked binary is refused. Fine while krytis signs only its
own artifacts; revisit if the MS CAs' `dbx` updates ever matter.

### G-6 · One firmware, one architecture

Everything is OVMF on x86_64. No aarch64 (krytis is x86_64-only today) and no real
firmware variety, which is where enrollment quirks live.

---

## 7. Cross-references

- `docs/skills/secure-boot.md` — the failure modes and their evidence, including the
  `.auth` root cause, the digest rules and the negative-test discipline
- `docs/skills/bootc-vm.md` § Two install paths, two tests — `boot-test` vs
  `iso-install-test`
- `docs/skills/pam.md` § Key-only SSH — why a debug ISO is required
- `docs/design/secure-boot-uki.md` — the original design and its rejected alternatives
- `docs/plans/done/2026-08-01-add-sealed-payload-to-iso.md` — the ISO work and its
  verification record
