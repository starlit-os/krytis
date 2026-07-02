# FIDO2 Skills

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

## FIDO2 boot unlock race: LUKS2-token-plugin path has no retry

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
