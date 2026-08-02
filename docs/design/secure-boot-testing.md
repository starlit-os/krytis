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
| `mise run upgrade-test` | ~3 min + pull | `bootc upgrade` on an installed sealed system, then a reboot into the result, still enforcing and healthy | anything about a *newer* image — it follows whatever the configured stream holds, which today is broken (G-2) |
| `mise run selfenroll-test` | **66 s** | the full chain on a real installed disk against a pristine firmware — see T3 below, where it belongs in the sequence | the manual enrollment prompt (a VM auto-enrols) |

The last two need an installed disk, which T3's `iso-install-test` leaves behind at
`/var/tmp/dakota-sealed-install.img`. Both boot a *copy* of it, so the disk stays a
first-boot disk and can be reused (trap T-4).

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

**Self-enrollment on the real artifact** is the strongest single check that exists,
and it is `mise run selfenroll-test` — **66 s**, no root. Run it after
`iso-install-test`, which leaves the installed disk behind for it:

```
mise run iso-install-test --secure     # ~4 min, leaves /var/tmp/dakota-sealed-install.img
mise run selfenroll-test               # 66 s
```

It boots a *copy* of that disk against a **pristine** varstore — setup mode, no keys,
i.e. a machine that has never seen krytis. `.ovmf-vars-secure.fd` would defeat the
point: the keys are already in it, so nothing would need enrolling and
`boot-test --secure` covers that case already.

A pass looks like this, and every line of it is load-bearing:

```
BdsDxe: starting Boot0002 …                     <- setup mode, nothing enforced yet
systemd-boot@0x101300000 260.2
Enrolling secure boot keys from directory: \loader\keys\auto
Custom Secure Boot keys successfully enrolled, rebooting the system now!
BdsDxe: starting Boot0002 …                     <- enforcing now, and it still starts
systemd-boot@0x101300000 260.2
systemd-stub@0x14df91000 260.2                  <- UKI signature verified too
state: running
sb: Secure Boot: enabled (user)
image: ghcr.io/starlit-os/krytis:sealed
failed-units:
```

The task distinguishes four failure modes rather than reporting one "it broke":
never enrolled, enrolled-then-refused (#438's shape), enrolled and enforcing but not
healthy, and reached `running` without Secure Boot actually on. The last one matters —
a boot that comes up fine with enforcement silently off proves nothing.

| Proves | Cannot prove |
|---|---|
| the whole chain on a real install: ESP layout, `.auth` files, UKI, composefs, first-boot units, all of it | the **manual** enrollment prompt — a VM is "safe" to systemd-boot, so `if-safe` enrols without asking (trap T-4, #444). The prompt path is T4 only |

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
9. `mise run selfenroll-test` — the scenario a user actually hits: a machine with no
   keys, enrolling krytis's own, then booting enforcing.
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
`build-iso` or any QEMU test — PR #445 adds the static gates, but every boot gate above
is still a thing a human remembers to run.

**Resolved (#448, option A): `publish.yml` now builds and publishes the sealed image**
after the unsigned one is pushed, signed and verified — deliberately last, because the
sealed path is newer and a failure in it must not cost the primary artifact. Opt out
per-run with `publish_sealed=false`.

Key custody took the variant, not the letter, of option A. The six UEFI keys are **not**
GitHub secrets: they stay in the Proton Pass vault `fnox.toml` already points at, and CI
holds one credential — a Proton Pass PAT — to reach them. That leaves raw private key
material out of the repository's secret store, makes rotation a vault operation rather
than six secret edits, and means a leaked CI secret exposes a revocable token instead of
the keys. Keys touch the runner's disk only inside that job and are shredded on the way
out, `always()`.

The gap this closed was live, not theoretical: before it, no automation ever produced a
sealed image, so `ghcr.io/starlit-os/krytis:sealed` existed only because someone ran
`mise run push --sealed` by hand — and a sealed ISO bakes that tag as `targetImgref`, so
installed systems tracked a manually refreshed tag.

That is not hypothetical drift. The published tag as of 2026-08-02, pulled and
inspected:

```
$ podman inspect ghcr.io/starlit-os/krytis:sealed --format '{{.Created}}'
2026-07-28 20:29:15 +0000 UTC
$ podman run --rm --entrypoint="" ghcr.io/starlit-os/krytis:sealed \
      sh -c 'ls /boot/EFI/Linux/; ls /usr/lib/bootc/install/'
krytis.efi          <- signed UKI present
                    <- /usr/lib/bootc/install/ is EMPTY: no secureboot-keys at all
```

So the sealed image users can actually pull is five days old and predates #309
entirely: it boots signed but enrols nothing, leaving a machine to have keys placed
by hand. Anyone installing from a sealed ISO built against that tag inherits it as
their upgrade target. Automating sealed publishing is therefore not a tidiness
question — the manual tag is already behind the feature work by two issues.

What could move to CI today, in order of value per minute:

| Candidate | Feasible on a GitHub runner? |
|---|---|
| T0 static gates + `parse-efi-auth.py` | yes — seconds, no privileges |
| `mise run lint` | **no** — it builds the Containerfile `FROM localhost/krytis-input`, which only exists after `mise run build`. That is publish.yml's 420-minute BST job, not a PR gate |
| `mise run seal-uki` + `assert_esl` | yes, but needs the signing keys as secrets — a Security Gate decision |
| `mise run enroll-test` | **KVM confirmed available**, see below. Blocked instead on having a sealed image worth testing |
| `boot-test --secure` | needs KVM (available) **and** root for `generate-disk` |
| T3 ISO E2E | needs KVM (available) + ~60 GB scratch + ~40 min |

**KVM is usable on both runner types — measured, not assumed** (PR #445, since deleted
from the workflow). On `ubuntu-24.04` and `blacksmith-8vcpu-ubuntu-2404` alike:
`/dev/kvm` exists as `crw-rw---- root:kvm`, the runner user is **not** in the `kvm`
group, and `qemu-system-x86_64 -enable-kvm` works **under sudo**. A
`sudo chmod 0666 /dev/kvm` (or an ACL) in a setup step is enough, after which the
mise tasks run unprivileged exactly as they do locally. Note the distinction that
made this worth probing: "Permission denied" means the device is there and reachable
with a permission fix, where "No such file" would have meant no KVM at all.

`enroll-test` remains the standout candidate — 8 seconds, no root, and it guards the
failure mode that actually shipped — but it needs a sealed image, and that is where
it is stuck. `podman pull ghcr.io/starlit-os/krytis:sealed` avoids both the BST build
and the signing keys, and tests the artifact users actually receive, which is the
better gate. Except the published tag is **stale**: built 2026-07-28, it carries the
UKI but an *empty* `/usr/lib/bootc/install/` — no enrollment keys at all, predating
#309. Pointing CI at it today would report a real problem for the wrong reason.
Publishing a current sealed image is therefore a prerequisite for this gate, and is
the same decision as G-1's "should CI build sealed images at all".

### G-2 · `bootc upgrade` — now tested, and it found the stream broken

`mise run upgrade-test` exists (T2, no root). It boots an installed sealed disk under
enforcement with the enrolled varstore, lets the guest run `bootc upgrade` against its
own `targetImgref`, reboots into the result and asserts enforcing + healthy. It
self-sequences across the reboot: SMBIOS credentials are re-supplied each boot, so the
same probe upgrades on the first pass and reports on the second.

**First real run failed, correctly.** `bootc upgrade` against the published sealed
stream:

```
error: Upgrading composefs: … Writing krytis.efi to ESP:
  The UKI has the wrong composefs= parameter
  (is 'sha512:69b1f9e6…', should be 'sha512:6b7180ec…')
```

The published image's baked digest does not match its own rootfs, so bootc refuses to
deploy it — which means **every machine installed from a sealed ISO is on a stream it
cannot upgrade from**. Locally built sealed images are fine (`iso-install-test
--secure` installs one and install runs the same verification), so this is specific to
the published artifact. Tracked in #448 along with that tag's two other problems.

**Still unverified: the pass path.** There is currently no good sealed image to
upgrade *to*, so the test has only ever been observed failing — against a real defect,
which is meaningful evidence but not the same as watching it go green. Publishing a
sealed image from #443 unblocks it, the same blocker as the `enroll-test` CI job. Until
then treat a green `upgrade-test` as unproven.

A second sealed build differing only in `include/image-version.yml` would let the test
run entirely locally, but that version stamp comes from the BST build, so producing one
costs a `mise run build` rather than a re-seal.

### G-3 · ~~Self-enrollment is a manual recipe, not a task~~ — closed

Now `mise run selfenroll-test` (§3 T3): 66 s, no root, four distinguishable failure
modes. The remaining piece of this scenario is the **manual enrollment prompt**,
which no VM can exercise — systemd-boot treats a VM as "safe" and enrols without
asking. That is T4, and #444 tracks the first-boot policy question behind it.

### G-4 · There is no key rotation *mechanism* to test — #447

Investigated rather than assumed. `loader/keys/auto` is a one-shot bootstrap:
systemd-boot only offers enrollment while the firmware is in Setup Mode. Measured by
booting the same ESP twice against the same varstore:

```
boot 1: pristine varstore (setup mode)      enrolled-this-boot=1
boot 2: same varstore, keys now enrolled    enrolled-this-boot=0   (no enrollment line at all)
```

So shipping new `.auth` files in a future image does nothing for existing installs —
they keep trusting the old `db` forever, and a leaked `db.key` has no remedy short of
a per-machine trip through firmware setup. Rotation would need the OS to write
authenticated variable updates signed by the *current* KEK/PK; krytis ships no such
tooling and bootc does not do it either.

A test needs a mechanism, so #447 asks the prior question: does krytis support
rotation at all? "No, a compromise means reinstall" is a legitimate answer for a
desktop OS — it just needs writing down. Whoever does build it inherits the
`sbvarsign` `tm_mon` trap (§ the fix in `docs/skills/secure-boot.md`), which is
cosmetic today and becomes silent update rejection under rollback protection.

### G-5 · `dbx` is empty while the Microsoft CAs are trusted — #446

This got sharper as a direct result of fixing #438. Post-enrollment varstore on a
machine that came from Setup Mode:

```
PK  1254   KEK 1263   db 4353 (krytis + both Microsoft CAs)   SecureBootEnable ON
                      dbx — absent
```

krytis ships `PK.auth`, `KEK.auth`, `db.auth` and no `dbx.auth`. Before #443 every one
of those lists was empty, so trusting the Microsoft CAs was theoretical; now it is
real, with **no revocations loaded** — every Microsoft-signed binary ever revoked
still verifies. Worst for exactly the users who follow #309's instructions, since
clearing firmware keys to reach Setup Mode typically clears `dbx` too.

#446 carries the options. Shipping a `dbx.auth` from Microsoft's published DBX
update, signed by our KEK, reuses the machinery that already exists — but it is a
Security Gate call.

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
