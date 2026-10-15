# fisherman-cleanup: delete the plain-text LUKS passphrase that the installer
# leaves on the physical root of some installs (#1280).
#
# The installer's TPM2 switch (tuna-os/bootc-installer, on by default on TPM 2.0
# hardware until #1276) makes fisherman stage a first-boot enrollment unit plus a
# key file holding the passphrase. On a composefs install it writes them to the
# physical root (/sysroot), where systemd never sees the unit, so the key is never
# shredded. The unit here removes the key and the stray files once, logs a line
# asking for a passphrase change, and is skipped on every other machine
# (ConditionPathExists).
#
# Writes to the physical root during boot (Breakage Gate). The write is confined:
# PrivateMounts=yes plus `mount -o remount,bind,rw` flips only this unit's view of
# /sysroot, and the namespace is discarded when it exits.
#
# Remove once no supported install can carry the file. There is no reliable way
# to count those (the installer has no telemetry), so keep it until a release
# note has told affected users to change their passphrase and a few release
# cycles have passed. Cost while kept: one skipped unit per boot.
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
    install -Dm755 fisherman-cleanup.sh \
      "%{install-root}/usr/libexec/krytis/fisherman-cleanup.sh"

    install -Dm644 krytis-fisherman-cleanup.service \
      "%{install-root}%{indep-libdir}/systemd/system/krytis-fisherman-cleanup.service"

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/74-krytis-fisherman-cleanup.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/74-krytis-fisherman-cleanup.preset" <<'EOF'
    enable krytis-fisherman-cleanup.service
    EOF

sources:
- kind: local
  path: files/fisherman-cleanup
