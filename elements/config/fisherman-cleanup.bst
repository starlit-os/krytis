# fisherman-cleanup: delete what the installer (fisherman, inside
# tuna-os/bootc-installer) leaves on the physical root (/sysroot). Two units, each
# skipped on machines without its leftover (ConditionPathExists):
#
# krytis-fisherman-cleanup.service (#1280): the plain-text LUKS passphrase. The
#   installer's TPM2 switch (on by default on TPM 2.0 hardware until #1276) makes
#   fisherman stage a first-boot enrollment unit plus a key file holding the
#   passphrase. On a composefs install they land on the physical root, where
#   systemd never sees the unit, so the key is never shredded. Removed once at
#   boot, with a log line asking for a passphrase change.
#
# krytis-fisherman-scratch-cleanup.service (#1282): ~11G of install-time scratch
#   (a container store and an OCI export of the OS image) at
#   /sysroot/.fisherman-scratch, left by every live-ISO install because fisherman
#   deletes it only after unmounting the target. Runs after multi-user.target at
#   idle I/O priority, so the minutes it takes don't delay boot.
#
# Both write to the physical root (Breakage Gate). The write is confined:
# PrivateMounts=yes plus `mount -o remount,bind,rw` flips only the unit's view of
# /sysroot, and the namespace is discarded when it exits. boot-test asserts both
# leftovers are gone once the system settles, so iso-install-test and
# luks-install-test check the units end to end.
#
# Remove a unit once no supported install can carry its leftover. There is no
# reliable way to count those (the installer has no telemetry), so keep it until
# fisherman stops producing the leftover and a few release cycles have passed.
# Cost while kept: one skipped unit per boot each.
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
    for f in fisherman-cleanup.sh fisherman-scratch-cleanup.sh; do
      install -Dm755 "$f" "%{install-root}/usr/libexec/krytis/$f"
    done

    for u in krytis-fisherman-cleanup.service krytis-fisherman-scratch-cleanup.service; do
      install -Dm644 "$u" "%{install-root}%{indep-libdir}/systemd/system/$u"
    done

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/74-krytis-fisherman-cleanup.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/74-krytis-fisherman-cleanup.preset" <<'EOF'
    enable krytis-fisherman-cleanup.service
    enable krytis-fisherman-scratch-cleanup.service
    EOF

sources:
- kind: local
  path: files/fisherman-cleanup
