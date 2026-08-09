# FIDO2 Skills

## One key, three enrollments — know which consumer you are talking to

A single security key has to be enrolled separately for each consumer, because each uses its own relying-party ID and its own credential store. Enrolling one does nothing for the others:

| Consumer | Enrolled by | rp_id / origin | Stored in |
|---|---|---|---|
| LUKS boot unlock | `mise fido2:enroll-luks` → `systemd-cryptenroll --fido2-device=auto` | `io.systemd.cryptsetup` | LUKS2 header token slot |
| systemd-homed login | `mise fido2:enroll` → `homectl update <user> --fido2-device=auto` | `io.systemd.home` | user record: public `fido2HmacCredential`, privileged `fido2HmacSalt[]` |
| sudo / polkit / non-homed login | `mise fido2:enroll` → `pamu2fcfg` | `pam://$(hostname)` | `~/.config/Yubico/u2f_keys` |

`mise fido2:enroll` detects a homed user and does both of the last two rows in one run; a classic `/etc/passwd` user only gets the last row. Detection is auth-free — `homectl list` maps to the `ListHomes` D-Bus method, which has no polkit action, so it never prompts:

```bash
homectl list --json=short 2>/dev/null | jq -e --arg u "$1" 'any(.[]; .name == $u)' >/dev/null
```

`homectl list`'s JSON keys come from `table_new("name", "uid", "gid", "state", "realname", "home", "shell")` in `homectl.c:list_homes` — `.name`, not `.userName`. `homectl inspect --json=short <user>` dumps one record at top level, so the enrollment count is `(.fido2HmacCredential // []) | length`.

Why the split is architectural, not a packaging accident: homed derives the home area's LUKS/fscrypt passphrase from the token's `hmac-secret` output, so only homed can consume that credential — and the pam_u2f authfile lives inside the home it would have to unlock. See `docs/skills/pam.md` § systemd-homed users.

**`homectl update --fido2-device=` needs no admin auth for your own account** (`org.freedesktop.home1.update-home-by-owner` is `allow_active=yes`), but it *does* imply `--and-change-password`, so it prompts for the existing account password before the key PIN and touch — it has to re-key the underlying LUKS/fscrypt slots. It also **replaces** any existing FIDO2 enrollment: `ARG_FIDO2_DEVICE` drops `fido2HmacCredential`/`fido2HmacSalt` first, so there is no "add a second key" mode. Warn before overwriting.

Mirror the detected key capabilities into homed's flags (`--fido2-with-client-pin=`, `--fido2-with-user-presence=`, `--fido2-with-user-verification=`) so both enrollments demand the same factors; homed's own defaults are `PIN|UP` only, which silently diverges from a pam_u2f credential enrolled with `-V` on a biometric key.

**Do not tell users to run `ykman` — it is not in the image.** Set a PIN with `fido2-token -S <device>` (libfido2, which is present).

## enroll-luks task: fresh bootc installs have no /etc/crypttab

A freshly installed bootc system with encrypted root has **no `/etc/crypttab`**. The encrypted block device is configured via the bootloader/initrd, not crypttab. The task must fall back to a `blkid` scan when crypttab is absent or yields nothing:

```bash
blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | sort
```

`/etc/crypttab` is a secondary source — only present after the user or installer populates it explicitly. Don't rely on it as the sole discovery path.

## enroll-luks task: /etc/crypttab may use UUID= syntax

When `/etc/crypttab` does exist, field 2 may be `UUID=<uuid>` rather than a raw device path. `cryptsetup isLuks UUID=xxx` fails silently. Resolve before use:

```bash
if [[ "$DEVICE" =~ ^UUID= ]]; then
  DEVICE="/dev/disk/by-uuid/${DEVICE#UUID=}"
fi
```

## LUKS header enrollment alone does not enable FIDO2 unlock at boot

> **CORRECTION (2026-08-08, measured on hardware): none of this applies to krytis's
> ROOT volume.** `rd.luks.options=` is consumed by `systemd-cryptsetup-generator`, which
> owns `/etc/crypttab`-style entries. Our root is discovered by
> `systemd-gpt-auto-generator`, which builds its own option string and **never reads that
> karg**. Read § `gpt-auto-generator` owns the root's crypt options below before acting
> on anything in this section. What follows is correct for *non-root* volumes, which do
> go through `systemd-cryptsetup-generator`.

`systemd-cryptenroll --fido2-device=auto` only writes a token slot into the LUKS2 header. It does **not** make the initrd try FIDO2 at boot. The initrd's `systemd-cryptsetup-generator` needs `rd.luks.options=fido2-device=auto` on the kernel cmdline — without it, boot falls back to passphrase prompt even though the token slot exists and `mise fido2:status` shows it enrolled.

**Bake this in at build time**, don't try to set it per-host at runtime. Ship it as `/usr/lib/bootc/kargs.d/*.toml` (see `files/bootc-config/30-fido2-luks.toml`, installed by `elements/config/bootc.bst`):

```toml
kargs = ["rd.luks.options=fido2-device=auto"]
```

This is safe to apply unconditionally to every build — it's a no-op for any LUKS volume without a `systemd-fido2` token enrolled (they fall straight through to their existing unlock method, e.g. passphrase or swap with no auth). No UUID-scoping needed. Applies automatically to every deployment, including future `bootc upgrade`s, with zero per-host or per-enrollment action required.

**Decision rule:** before reaching for a per-host runtime persistence mechanism, check whether the karg is actually host-independent. `fido2-device=auto` doesn't encode a specific credential — it's a generic "try FIDO2 if a token is enrolled" hint, safe on every machine whether or not a key is ever enrolled there. That makes it build-time (`kargs.d`) material, not runtime material, even though FIDO2 enrollment itself is a per-host action. Don't conflate "the feature is configured per-host" with "the karg must be set per-host" — they're independent. Getting this wrong here cost a full build+push cycle on a runtime approach that was never going to work.

### `bootc loader-entries` does not work on this project's composefs-native backend

Tried first, doesn't work here — kept as a documented dead end so it isn't retried. `bootc loader-entries set-options-for-source --source <name> --options "<kargs>"` is the general mechanism for *runtime*, per-host karg persistence across deployments (tracks kargs per-source via `x-options-source-<name>` BLS keys, used for things like TuneD). It fails on this image with `error: OSTree storage not initialized`, even on ostree >= 2026.1 (rules out the version requirement documented in `bootc-loader-entries-set-options-for-source(8)`).

Root cause: `bootc upgrade`/`bootc status` work fine and use their own code path for this backend. `loader-entries` is a separate code path that expects a classic ostree Sysroot deployment-tracking object (`/ostree/deploy/<stateroot>/deploy/<checksum>.0`), which this project's composefs-native layout (`state/deploy/<hash>/{etc,var}`, `composefs/<hash>` — see `bootc-vm.md`) doesn't populate, even though a plain content-addressed blob repo exists at `/sysroot/ostree`.

Confirmed the BLS entries themselves are real, editable Type #1 text files at `<ESP>/loader/entries/*.conf` with a normal `options=` line — this is not a UKI/Type #2 boot setup. `loader-entries` failing is specific to how it locates/tracks deployments internally, not a fact about the boot chain itself. **Known limitation:** since composefs-native writes a fresh BLS entry per deployment on each `bootc upgrade`, any *runtime* per-host karg (via direct `options=` edit or a future working `loader-entries` fix) would not carry forward automatically — reinforces why kargs.d (baked into the image, applied at every deployment) is the right mechanism for anything that should persist across upgrades.

## The karg is not enough either — `libfido2.so.1` has to be IN the initrd (#473)

Three things must line up for a boot-time FIDO2 unlock, and the third went missing
for months without any symptom:

1. a `systemd-fido2` token slot in the LUKS2 header (`mise fido2:enroll-luks`)
2. `rd.luks.options=fido2-device=auto` on the cmdline (baked, see above)
3. **`libfido2.so.1` inside the initrd**

`systemd-cryptsetup` reaches FIDO2 by `dlopen`, and **dracut cannot see a `dlopen`**,
so the library was simply omitted from every initrd we ever built. It is present in
the rootfs, which is what makes this so easy to miss: `ls /usr/lib/*/libfido2*` in the
running system says yes, and the initrd — the only place that matters for unlocking
root — says no.

Fixed by naming it in `install_items` in `elements/core/initramfs.bst`, with a
build-time assertion so it cannot silently vanish again. Its ELF dependencies
(`libcbor`, `libcrypto`, `libudev`, `libz`) resolve automatically; only the `dlopen`ed
entry point needs naming. Identical mechanism and identical fix to #466's
`libtss2-tcti-device.so.0` — see `docs/design/secure-boot-testing.md` § G-8 for the
audit of the whole `dlopen` set, including why systemd's `.note.dlopen` metadata finds
this one but *not* #466's.

**Why nothing broke visibly.** Unlike the TPM case, this one is not fatal:
`src/cryptsetup/cryptsetup.c:1584` returns `EAGAIN` with *"Automatic FIDO2 metadata
discovery was not possible … falling back to traditional unlocking"*, and on error the
FIDO2 arguments are cleared so the attempt loop continues to a passphrase (2736-2739).
So the only consequence was that a documented, shipped feature could not work, and
every unlock quietly used the passphrase instead. Worth knowing when diagnosing "my
key is enrolled but it always asks for the passphrase" — check the initrd before the
token.

```bash
# What the initrd actually contains, from a sealed image:
cid=$(podman create localhost/krytis:sealed true)
podman cp "$cid":/boot/EFI/Linux/krytis.efi /var/tmp/uki.efi && podman rm "$cid"
objcopy -O binary --only-section=.initrd /var/tmp/uki.efi /var/tmp/i.zstd

# .initrd is early-microcode cpio PLUS the real zstd archive, concatenated. Piping
# it straight to zstdcat silently decompresses only the microcode segment — 6 files
# instead of 7881 — and grepping that reports every library as missing. Seek to the
# zstd magic (28 b5 2f fd) first:
python3 -c 'd=open("/var/tmp/i.zstd","rb").read(); o=d.index(bytes([0x28,0xB5,0x2F,0xFD])); open("/var/tmp/main.zstd","wb").write(d[o:])'
zstdcat /var/tmp/main.zstd 2>/dev/null | cpio -t 2>/dev/null | grep -E 'libfido2|libtss2-tcti-device'
```

## `gpt-auto-generator` owns the root's crypt options, and only ever adds TPM2

**This is why FIDO2 unlock of krytis's root has never worked, and it is not a missing
file.** `rd.luks.options=` is parsed by `systemd-cryptsetup-generator`, which builds units
from `/etc/crypttab`-style input. krytis's root is not in anyone's crypttab: the sealed
UKI's cmdline carries no `rd.luks.uuid=`, and `hostonly=no` means the initrd has no
`/etc/crypttab` (see `docs/skills/secure-boot.md`). So the root's unit is created by
**`systemd-gpt-auto-generator`** instead — the device even names itself
`/dev/gpt-auto-root-luks` in the journal.

That generator constructs the option string itself, from `src/gpt-auto-generator/gpt-auto-generator.c`:

```c
r = efi_measured_os(LOG_WARNING);
if (r > 0) {
        /* Enable TPM2 based unlocking automatically, if we have a TPM. See #30176. */
        if (!strextend_with_separator(&options, ",", "tpm2-device=auto"))
                return log_oom();
}
```

`tpm2-device=auto` when the OS was measured, `read-only` when not RW, and **nothing
else**. It never reads `rd.luks.options=`. So on a measured UKI the root's unit asks for
TPM2 and only TPM2, which is exactly what the hardware journal shows:

```
systemd-cryptsetup[401]: No valid TPM2 token data found.
```

`rd.luks.options=fido2-device=auto` — baked by `files/bootc-config/30-fido2-luks.toml` —
has therefore been **decorative on the root volume** since it was introduced. It is not
wrong for other volumes; it simply never reaches this one.

### Consequences for the three obvious fixes

1. **TPM2 instead of FIDO2.** The one mechanism gpt-auto enables unprompted. `No valid
   TPM2 token data found` means it is already *trying*, so enrolling a TPM2 token
   (`systemd-cryptenroll --tpm2-device=auto`) plausibly just works with no image change.
   Read `docs/design/secure-boot-testing.md` on PCR choice first — PCR 15's file-system
   identity is empty on a composefs root (#368), so it is weaker than it looks.
2. **A drop-in on the generated unit.** `systemd-cryptsetup@root.service` is
   generator-created, so anything targeting it must be forced into the initrd with
   `install_items+=`; a drop-in that only exists in the build root is invisible to dracut.
   That plumbing was proven to work during #253's second attempt — the plumbing
   succeeded, only its ordering theory failed. **This is the route krytis took, but NOT
   by overriding `ExecStart` to append `fido2-device=auto` — that breaks every machine
   without an enrolled key. See the FATAL-without-a-token section below for the shape
   that works.**
3. **Generate an `/etc/crypttab` at install time** so `systemd-cryptsetup-generator` owns
   the volume, which also unlocks the retry-capable manual `fido2-cid=` path. Conflicts
   with `hostonly=no` and needs installer support, so it is the most invasive.

**Whatever is tried, verify against the journal rather than the karg.** `/proc/cmdline`
showing `rd.luks.options=fido2-device=auto` proves nothing about the root — the unit's
actual `Options=` is what matters, and the honest check is whether the boot log mentions
FIDO2 at all.

## `fido2-device=auto` is FATAL without an enrolled token — never put it in a shared option string

**Measured 2026-08-08 by `mise run luks-boot-test`, which caught this before it shipped
(#543 fixed by #544).** Route 2 above was implemented as an `ExecStart` override adding
`fido2-device=auto` to the root's options. On a volume with no `systemd-fido2` token in
its header, that turns a working passphrase prompt into instant emergency mode.

The asymmetry with TPM2 is deliberate upstream, and it is the whole trap:

| token | no token in header | source |
|---|---|---|
| TPM2 | `-EAGAIN` → falls through to passphrase | `cryptsetup.c`: *"Mangle error code: let's make any form of TPM2 failure non-fatal."* |
| FIDO2 | **`-ENXIO`** → hard exit, no fallback | `cryptsetup-fido2.c`: `find_fido2_auto_data()` → `"No valid FIDO2 token data found."` |

So `tpm2-device=auto` is safe to ship to every machine — which is exactly why gpt-auto
adds it unprompted — and `fido2-device=auto` is not. A fresh krytis install has no
enrolled key, so shipping it in the root's options breaks the default case.

### The shape that works: add a unit, do not override the generated one

`elements/config/fido2-root-unlock.bst` ships two files instead:

- `krytis-fido2-root-unlock.service` — attempts FIDO2 *before* the generated unit, with
  an `ExecStart=-` prefix so failure is ignored. `token-timeout=20s` and `TimeoutSec=60`
  bound it, because anything stalling here delays the passphrase prompt that follows.
- `50-krytis-fido2-root.conf` — a drop-in carrying only `Wants=` and
  `ConditionPathExists=!/dev/mapper/root`.

Three non-obvious details, each of which was a bug in an earlier draft:

1. **`Before=` does not start anything.** It only orders. `Wants=` in the drop-in is what
   pulls the attempt in, riding on whatever activates the root unlock.
2. **The condition is required, not cosmetic.** Without it the generated unit runs a
   second `attach` against a name already in use, failing the boot *after* a successful
   unlock.
3. **Do not copy `BindsTo=` from gpt-auto.** It exists to tear the unlock down with the
   device; on a one-shot pre-attempt it is only a way to stall ahead of the prompt.

Verified both arms with real systemd before building, using a throwaway systemd
container with a stub unit in `/run/systemd/system` (note: `/run/systemd/generator` is
wiped on `daemon-reload`, so a hand-placed unit there vanishes):

| arm | attempt runs | attempt wins | generated unit runs |
|---|---|---|---|
| no enrolled token | yes | no | **yes** — passphrase prompt, unchanged |
| token unlocks | yes | yes | **no** — skipped by the condition |

**`mise run luks-boot-test` is the gate for this class**, and its synthetic root is
passphrase-only, which is what makes it catch exactly this. Run it against any change to
the root's unlock path; a green `mise run build` proves only that files landed.

### The pre-attempt MUST be `headless=yes`, or it prompts and stalls the boot

`systemd-cryptsetup attach … fido2-device=auto` is not a FIDO2-only operation. When the
token path comes up empty it falls through to **asking for a passphrase itself**. In a
pre-attempt unit that is a boot stall, not a fallback, and with plymouth up it is an
*invisible* one. Measured on 2026-08-08 with the journal forwarded to console:

```
[ 3.442] systemd-cryptsetup[291]: Set cipher aes ... /dev/gpt-auto-root-luks
[ 3.452] Started systemd-ask-password-plymouth.service   <- the pre-attempt prompting
[63.497] krytis-fido2-root-unlock.service: start operation timed out
```

The gate still passed — the real prompt appeared after the unit was killed — so **a green
`luks-boot-test` does not prove the attempt behaved**. Read the timings.

`headless=yes` makes password and PIN querying return `-ENOPKG` immediately, so the unit
can only ever succeed via the token and never competes for the password agent. The
consequence is that a credential enrolled **with** a client PIN cannot unlock at boot
here: enroll touch-only (`--fido2-with-client-pin=no`).

### No prior art: peer projects do TPM2, not FIDO2

Checked `travier/fedora-atomic-desktops-sealed` and krytis's fork of it in full (every
text file in both trees, 2026-08-08). **Zero** occurrences of `fido2`, `crypttab`,
`rd.luks`, or `gpt-auto`. Their encrypted root is `Encrypt=key-file` via `repart.d/`, and
the only unlock guidance is one README line:

```console
systemd-cryptenroll --tpm2-device=/dev/tpmrm0 --tpm2-pcrs=7:sha256 /dev/nvme0n1p2
```

So the absence of a working FIDO2 example elsewhere is not an oversight to copy from — it
is the same asymmetry from the other side. TPM2 needs no unit, no drop-in and no
`install_items` entry precisely because gpt-auto enables it natively and upstream makes
its failures non-fatal. Note also `--tpm2-pcrs=7:sha256` — policy PCR only, deliberately
not PCR 11, so enrollment survives image updates. Relevant to #368.

## ~~FIDO2 boot unlock race: LUKS2-token-plugin path has no retry~~ — DISPROVEN on hardware

> **CORRECTION (2026-08-08).** The upstream code reading below is accurate and worth
> keeping. The *diagnosis* — that krytis's root fails to unlock because the key loses a
> udev enumeration race — is **wrong**, and was measured wrong on a Lenovo ThinkPad
> (#535, #250):
>
> ```
> [ 2.021042] hid-generic 0003:1050:0402.0001: hiddev96,hidraw0 … [Yubico YubiKey FIDO]
> [ 2.605844] Starting systemd-cryptsetup@root.service …        <- 584 ms LATER
> [ 2.625046] systemd-cryptsetup[401]: No valid TPM2 token data found.
> ```
>
> The key was enumerated and had a `hidraw` node **584 ms before** cryptsetup started, so
> there was no race to lose. And the only token systemd looked for was **TPM2** — FIDO2
> was never attempted, because the root's unit never carried a FIDO2 option. See
> § `gpt-auto-generator` owns the root's crypt options.
>
> Two fix attempts were spent on this theory (#253), both boot-tested on initrds that
> also lacked `libfido2` and the token plugin, so their "no change" results were
> uninformative twice over. **Do not spend a third on timing without first measuring
> `hidraw` versus the cryptsetup start in `journalctl -o short-monotonic`.**

`rd.luks.options=fido2-device=auto` alone isn't sufficient in practice — even with the karg and an enrolled token both present and correct, unlock can still silently fall back to passphrase if the security key isn't enumerated by udev yet. Verified against upstream systemd `src/cryptsetup/cryptsetup.c` source directly (not guessed):

- systemd's FIDO2 unlock *does* have a retry/wait mechanism (`make_security_device_monitor`/`run_security_device_monitor`, default `token-timeout=30s` watching for a udev `security-device` tag). But it only fires on the **legacy manual crypttab path** (`acquire_fido2_key`/`acquire_fido2_key_auto`), used when `fido2-cid=` is set explicitly.
- `systemd-cryptenroll --fido2-device=auto` (what `mise fido2:enroll-luks` uses) writes a **LUKS2 JSON token** instead. At boot, `determine_token_type()` auto-detects `TOKEN_FIDO2` from the header and (since `use_token_plugins()` is true by default) unlock goes through `attach_luks2_by_fido2_via_plugin()` — one single libfido2 scan via the dlopen'd `libcryptsetup-token-systemd-fido2.so` plugin, no wait.
- On a failed scan (`-ENOENT`/`-ENXIO`/`-ENOTUNIQ`, device not enumerated yet), `verb_attach()`'s `tries` loop does `arg_fido2_device_auto = false; continue` — **permanently disabling FIDO2 for the rest of that boot's unlock attempts**, falling straight to passphrase.

So the LUKS2-token-plugin enrollment style (the one `systemd-cryptenroll` produces) gets exactly one instantaneous shot per boot. This is a genuine upstream systemd limitation, not a config bug — don't re-derive this by reading crypttab(5)/systemd-cryptsetup(8) man pages alone, they don't document the plugin-vs-manual-path split. Full narrative in issue #250.

**Fix attempt 1 (rejected, confirmed no effect on real hardware):** `rd.driver.pre=xhci_pci,xhci_hcd,ehci_pci,ehci_hcd,usbhid,hid_generic` — theory was that forcing USB/HID modules to load synchronously and early would shrink the enumeration window ahead of cryptsetup's single scan. Boot-tested: karg was confirmed present on `/proc/cmdline`, zero change in boot behavior. Root cause of the failure: `elements/core/initramfs.bst` builds with `hostonly=no` (generic initrd) — dracut already includes and autoloads essentially the full USB/HID driver set via udev coldplug at initrd start regardless of `rd.driver.pre=`. Module *load* timing was never the bottleneck; only USB device negotiation + `fido_id` udev-rule *execution* timing was. Don't retry this direction — driver preloading has no lever on this race in a generic (non-hostonly) initrd.

**Fix attempt 2 (rejected, confirmed no effect on real hardware):** a `systemd-cryptsetup@root.service.d/50-wait-for-udev-settle.conf` drop-in (`.d/` on the generator-created unit) with `After=`/`Wants=systemd-udev-settle.service`, delaying the unit's single FIDO2 scan until udev's event queue has drained — so the scan runs after `fido_id` has tagged the key, not racing it. Verified this time (unlike attempt 1) that the drop-in, the `systemd-udev-settle.service` unit, and `udevadm` were all actually present in the built initrd (`lsinitrd`) before boot-testing — still no change in boot behavior on real hardware.

Because `systemd-cryptsetup@root.service` is generator-created (not a static unit shipped by any package), a drop-in `.d/` directory for it isn't picked up by dracut's normal module-based file inclusion — it must be forced into the initrd explicitly via `install_items+=` in a dracut.conf.d snippet (e.g. in `elements/core/initramfs.bst`). A drop-in placed only in the build root's `%{indep-libdir}/systemd/system/` is invisible to the initrd unless something tells dracut to copy it. (This plumbing mechanism worked as designed and is a reusable pattern for future generator-unit drop-ins — the *ordering theory*, not the plumbing, is what failed.)

**Why attempt 2 likely failed:** `udevadm settle` only blocks until udev's *currently known* event queue is empty — it does not wait for events that haven't been submitted to the kernel/udevd yet. If USB device negotiation itself (electrical/protocol handshake before any uevent fires) takes longer than the queue-drain check, `systemd-udev-settle.service` can return successfully before the security key's `add` uevent — let alone `fido_id`'s tagging — has even happened. This is exactly why upstream systemd's own docs discourage relying on `-settle` for this class of problem (see the unit's own `[Unit]` comment: "This service can dynamically be pulled-in by legacy services which cannot reliably cope with dynamic device configurations, and wrongfully expect a populated /dev during bootup"). Both attempts targeted *software* timing (driver load, event-queue drain); neither addresses genuine hardware-level USB negotiation latency, which needs either a real wait-with-timeout loop (not a one-shot settle check) or a working retry path.

Considered and rejected: writing a per-host `fido2-cid=` into `/etc/crypttab` to force the legacy retry-capable path. Doesn't work here — root's LUKS unlock is driven entirely by `rd.luks.*` kernel cmdline options (`cryptsetup-generator.c` parsing), not `/etc/crypttab` (root's crypttab entry can't exist pre-unlock; see the "fresh bootc installs have no /etc/crypttab" section above, which is about post-boot volumes, not root). A per-host `fido2-cid=` would need per-host runtime karg persistence, which hits the same `bootc loader-entries` dead end documented above (`error: OSTree storage not initialized`) — this project's composefs-native backend has no working mechanism for that at all, build-time-only kargs are the only thing that works.

**State as of 2026-07-02:** two fix attempts tried and rejected on real hardware (neither's code is in the tree — both branches were deleted after failing boot-test). Per systematic-debugging practice, 2 failures isn't yet the 3-strikes architecture-question threshold, but both share a pattern: they treat this as a *software scheduling* problem when the evidence increasingly points to genuine *hardware enumeration latency* that no boot-ordering trick shrinks. Before a third attempt, consider: (a) actually measuring, via a custom debug initrd hook, how long after `fido_id` tags the device the `security-device` udev tag becomes visible, vs. how long a real wait-with-polling-timeout would need to reliably win; (b) whether the manual `fido2-cid=` + explicit keyfile path (which does get the real 30s retry) could work despite the crypttab/kargs.d limitations above via some other karg-injection point not yet explored; (c) whether this is simply not winnable within `systemd-cryptsetup`'s generator-unit model and needs a custom dracut module implementing its own poll-with-timeout before invoking cryptsetup, rather than reusing systemd's existing (structurally single-shot) codepath. Full narrative in issue #250.

## systemd-cryptenroll and FIDO2 PIN

`systemd-cryptenroll --fido2-device=auto` prompts for the existing LUKS passphrase, then for a FIDO2 PIN if the key requires user verification. The key blink prompt appears after the PIN prompt, not before. Telling users "touch when it blinks" is correct but the PIN step may precede it on UV-required keys.
