# Change your disk passphrase if the installer left a copy behind

**Who this affects:** machines installed from the krytis live ISO, with a TPM 2.0, where
the installer's TPM switch on the encryption page was left on (its default on TPM
hardware). Installs made with `bootc install`, installs on machines without a TPM 2.0, and
installs where the switch was turned off are not affected. (#1280)

## What happened

With the TPM switch on, the installer saved your disk passphrase to a file so a first-boot
service could set up TPM unlock. On krytis that service never runs, so nothing deleted
the file. It sat on the root partition, readable by root, at
`/sysroot/etc/fisherman/tpm2-enroll.key`.

Your disk was never decrypted by it: the file is inside the encrypted volume. But it is a
plain-text copy of a passphrase you chose, and any snapshot or backup of the root
partition taken since the install has it too.

## Check

```shell
journalctl -b -1 -u krytis-fisherman-cleanup.service; journalctl -b -u krytis-fisherman-cleanup.service
```

`Removed a plain-text copy of the disk passphrase` means your machine was affected and
the file is now gone. `skipped, unmet condition check` on the first boot of the updated
image means it never had the file.

To check directly at any time:

```shell
sudo test -e /sysroot/etc/fisherman/tpm2-enroll.key && echo "still present" || echo "not present"
```

## Fix

The image deletes the file on the first boot after the update, through
`krytis-fisherman-cleanup.service`. Deleting it is not enough on its own: btrfs keeps the
old blocks until they are reused, and snapshots or backups keep their copy. **Change the
passphrase** so every copy is worthless:

```shell
lsblk -o NAME,FSTYPE,MOUNTPOINTS          # the crypto_LUKS partition, usually nvme0n1p2 or sda2
sudo cryptsetup luksChangeKey /dev/<that partition>
```

It asks for the current passphrase, then the new one twice. FIDO2 and any other enrolled
keyslots are untouched. If you reused the old passphrase anywhere else, change it there
too.
