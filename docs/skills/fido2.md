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

### `bootc loader-entries` does not work on this project's composefs-native backend

Tried first, doesn't work here — kept as a documented dead end so it isn't retried. `bootc loader-entries set-options-for-source --source <name> --options "<kargs>"` is the general mechanism for *runtime*, per-host karg persistence across deployments (tracks kargs per-source via `x-options-source-<name>` BLS keys, used for things like TuneD). It fails on this image with `error: OSTree storage not initialized`, even on ostree >= 2026.1 (rules out the version requirement documented in `bootc-loader-entries-set-options-for-source(8)`).

Root cause: `bootc upgrade`/`bootc status` work fine and use their own code path for this backend. `loader-entries` is a separate code path that expects a classic ostree Sysroot deployment-tracking object (`/ostree/deploy/<stateroot>/deploy/<checksum>.0`), which this project's composefs-native layout (`state/deploy/<hash>/{etc,var}`, `composefs/<hash>` — see `bootc-vm.md`) doesn't populate, even though a plain content-addressed blob repo exists at `/sysroot/ostree`.

Confirmed the BLS entries themselves are real, editable Type #1 text files at `<ESP>/loader/entries/*.conf` with a normal `options=` line — this is not a UKI/Type #2 boot setup. `loader-entries` failing is specific to how it locates/tracks deployments internally, not a fact about the boot chain itself. **Known limitation:** since composefs-native writes a fresh BLS entry per deployment on each `bootc upgrade`, any *runtime* per-host karg (via direct `options=` edit or a future working `loader-entries` fix) would not carry forward automatically — reinforces why kargs.d (baked into the image, applied at every deployment) is the right mechanism for anything that should persist across upgrades.

## systemd-cryptenroll and FIDO2 PIN

`systemd-cryptenroll --fido2-device=auto` prompts for the existing LUKS passphrase, then for a FIDO2 PIN if the key requires user verification. The key blink prompt appears after the PIN prompt, not before. Telling users "touch when it blinks" is correct but the PIN step may precede it on UV-required keys.
