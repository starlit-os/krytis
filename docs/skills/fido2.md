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

## systemd-cryptenroll and FIDO2 PIN

`systemd-cryptenroll --fido2-device=auto` prompts for the existing LUKS passphrase, then for a FIDO2 PIN if the key requires user verification. The key blink prompt appears after the PIN prompt, not before. Telling users "touch when it blinks" is correct but the PIN step may precede it on UV-required keys.
