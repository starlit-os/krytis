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

`systemd-cryptenroll --fido2-device=auto` only writes a token slot into the LUKS2 header. It does **not** make the initrd try FIDO2 at boot. The initrd's `systemd-cryptsetup-generator` needs `rd.luks.options=<uuid>=fido2-device=auto` on the kernel cmdline — without it, boot falls back to passphrase prompt even though the token slot exists and `mise fido2:status` shows it enrolled.

On this bootc/composefs image there is no `rpm-ostree` (composefs backend is replacing it) and no `bootc kargs` subcommand. The correct persistent-karg mechanism is:

```bash
bootc loader-entries set-options-for-source --source <name> --options "<kargs>"
```

This tracks kargs per-source via `x-options-source-<name>` keys in the BLS entry and stages a new deployment. Scope the option to the specific device UUID (`rd.luks.options=<uuid>=fido2-device=auto`), not the blanket `rd.luks.options=fido2-device=auto` form — the blanket form applies to every LUKS volume on the system (e.g. swap), which may not have a FIDO2 token enrolled and will otherwise stall boot.

Requires a reboot to take effect — kargs are staged, not live.

## systemd-cryptenroll and FIDO2 PIN

`systemd-cryptenroll --fido2-device=auto` prompts for the existing LUKS passphrase, then for a FIDO2 PIN if the key requires user verification. The key blink prompt appears after the PIN prompt, not before. Telling users "touch when it blinks" is correct but the PIN step may precede it on UV-required keys.
