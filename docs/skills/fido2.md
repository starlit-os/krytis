# FIDO2 Skills

## enroll-luks task: /etc/crypttab uses UUID= syntax

`/etc/crypttab` field 2 (the block device) is written as `UUID=<uuid>` by anaconda/bootc-install, not as a raw `/dev/sdXY` path. `cryptsetup isLuks UUID=xxx` fails with a "not a block device" error, silently filtered by `|| true`, leaving the device array empty.

**Fix:** resolve `UUID=` prefix to `/dev/disk/by-uuid/<uuid>` before calling `cryptsetup isLuks`:

```bash
if [[ "$DEVICE" =~ ^UUID= ]]; then
  DEVICE="/dev/disk/by-uuid/${DEVICE#UUID=}"
fi
```

`/dev/disk/by-uuid/` symlinks are always present on a live system. `systemd-cryptenroll` also accepts this path form.

## systemd-cryptenroll and FIDO2 PIN

`systemd-cryptenroll --fido2-device=auto` prompts for the existing LUKS passphrase, then for a FIDO2 PIN if the key requires user verification. The key blink prompt appears after the PIN prompt, not before. Telling users "touch when it blinks" is correct but the PIN step may precede it on UV-required keys.
