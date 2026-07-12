kind: stack

# Core bootable system — no desktop, no greeter.
# Desktop stack is layered on top (stacks/desktop.bst, added in B4/B5).
depends:
  # ── Runtime base ────────────────────────────────────────────────────
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
  - freedesktop-sdk.bst:vm/base-filesystem.bst
  - freedesktop-sdk.bst:components/util-linux-full.bst
  - config/locale-data.bst

  # ── Init / service manager ──────────────────────────────────────────
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/dbus.bst
  - freedesktop-sdk.bst:components/polkit.bst

  # ── User / auth ────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/shadow.bst
  - freedesktop-sdk.bst:components/sudo.bst
  - freedesktop-sdk.bst:vm/config/sudo.bst
  - freedesktop-sdk.bst:vm/config/systemd-homed-firstboot.bst
  - config/systemd-firstboot.bst

  # ── Networking ─────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/iproute2.bst
  - freedesktop-sdk.bst:components/iputils.bst
  - freedesktop-sdk.bst:components/openssh.bst
  - freedesktop-sdk.bst:components/openssh-systemd.bst
  - freedesktop-sdk.bst:components/wpa-supplicant.bst
  - core/pangolin-cli.bst

  # ── Network config ─────────────────────────────────────────────────
  - freedesktop-sdk.bst:vm/config/networkd.bst
  - freedesktop-sdk.bst:vm/config/resolved.bst

  # ── Storage / filesystem ───────────────────────────────────────────
  - freedesktop-sdk.bst:components/lvm2.bst
  - freedesktop-sdk.bst:components/dracut.bst
  - freedesktop-sdk.bst:components/btrfs-progs.bst
  - freedesktop-sdk.bst:components/xfsprogs.bst
  - freedesktop-sdk.bst:components/erofs-utils.bst
  - freedesktop-sdk.bst:components/dosfstools.bst
  # composefs loop device filter: hides erofs loop mounts from UDisks/Nautilus.
  - core/composefs-loop-udisks-ignore.bst

  # ── Security / TPM / FIDO2 ─────────────────────────────────────────
  - freedesktop-sdk.bst:components/tpm2-tss.bst
  - freedesktop-sdk.bst:components/tpm2-tools.bst
  - freedesktop-sdk.bst:components/tpm2-pkcs11.bst
  - freedesktop-sdk.bst:components/libfido2.bst
  - freedesktop-sdk.bst:components/ccid.bst
  - freedesktop-sdk.bst:components/pcsc-lite.bst
  # pam_u2f.so module + PAM config wiring password-auth for sudo/login/screensaver.
  # Depends on #69 (core/pam-u2f.bst) — ensure that PR merges before this one.
  - config/u2f-config.bst

  # ── Firmware ───────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/fwupd.bst
  - freedesktop-sdk.bst:components/linux-firmware.bst
  - freedesktop-sdk.bst:components/sof-firmware.bst
  - freedesktop-sdk.bst:components/wireless-regdb-bin.bst

  # ── Hardware info ──────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/pciutils.bst
  - freedesktop-sdk.bst:components/usbutils.bst
  - freedesktop-sdk.bst:components/dmidecode.bst

  # ── Dev tooling ───────────────────────────────────────────
  - freedesktop-sdk.bst:components/git.bst
  - core/mise.bst
  - config/mise-aliases.bst
  - config/fido2-tasks.bst

  # ── Core utilities ─────────────────────────────────────────────────
  - core/uutils-coreutils.bst
  - freedesktop-sdk.bst:components/procps.bst
  - freedesktop-sdk.bst:components/tzdata.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/diffutils.bst
  - freedesktop-sdk.bst:components/sed.bst
  - freedesktop-sdk.bst:components/less.bst
  - freedesktop-sdk.bst:components/which.bst
  - freedesktop-sdk.bst:components/unzip.bst
  - freedesktop-sdk.bst:components/rsync.bst
  - freedesktop-sdk.bst:components/jq.bst
  - freedesktop-sdk.bst:components/wget2.bst
  - freedesktop-sdk.bst:components/vim.bst

  # ── Shell ──────────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/bash-config.bst
  - freedesktop-sdk.bst:components/bash-completion.bst

  # ── Man pages ──────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/man-db.bst
  - freedesktop-sdk.bst:components/man-pages.bst

  # ── System config ──────────────────────────────────────────────────
  - freedesktop-sdk.bst:vm/config/journald.bst
  - freedesktop-sdk.bst:components/hosts.bst

  # ── Container / toolbox (from gnome-build-meta) ────────────────────
  - gnome-build-meta.bst:gnomeos-deps/distrobox.bst
  - gnome-build-meta.bst:gnomeos-deps/toolbox.bst
  - gnome-build-meta.bst:gnomeos-deps/zram-generator.bst
  - gnome-build-meta.bst:gnomeos-deps/ld-config.bst
  - gnome-build-meta.bst:gnomeos-deps/android-udev-rules.bst
  - gnome-build-meta.bst:gnomeos-deps/hidraw-udev.bst
  - gnome-build-meta.bst:gnomeos-deps/udev-hide-usr.bst
  - gnome-build-meta.bst:gnomeos/reload-sysext.bst

  # ── Memory / OOM protection ────────────────────────────────────────
  # zram-generator is already included above (gnomeos-deps).
  # oomd: enables systemd-oomd.service (compiled into systemd) with tuning.
  # Prevents OOM kills by acting on swap pressure before the kernel OOM fires. Closes #219.
  - config/oomd.bst
