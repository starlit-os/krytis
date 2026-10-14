kind: stack

depends:
  - stacks/base-system.bst
  - stacks/bootc.bst
  - stacks/codecs.bst
  - stacks/desktop.bst
  - stacks/dev-tools.bst
  - core/linux-cachyos.bst
  - core/initramfs.bst

public:
  bst:
    integration-commands:
      - mkdir /var/tmp
      # Every path below that becomes a symlink is removed first, and every link
      # is made with `ln -sT`. Plain `ln -s target dest` with `dest` already a
      # directory creates `dest/<basename>` inside it and exits 0 — an element
      # that staged anything under /ostree, /srv or /usr/local would ship a real
      # directory there with a stray link nested in it (dakota hit exactly this
      # with /usr/local, dakota 1a1a7f4). The `rm` makes the normal case work;
      # `-T` makes a link path missing from the `rm` fail the build instead of
      # nesting (uutils ln: "File exists"). Anything removed here was unreachable
      # on a booted system anyway — each path is a link into /var or /sysroot.
      # docs/skills/bst.md § Rootfs symlinks: remove the path first, then `ln -sT`.
      - rm -rfv /boot /run /ostree
      - mkdir /boot
      - mkdir /run
      - mkdir /sysroot
      - mkdir /sysroot/ostree
      - ln -sT sysroot/ostree ostree

      - rm --verbose --recursive --force /root /home /opt /mnt /srv /usr/local /var

      # These are also created by config/bootc.bst tmpfiles at runtime,
      # but must exist in the OCI image for container use.
      - mkdir -p /var/home
      - mkdir -p /var/roothome
      - mkdir -p /var/opt
      - mkdir -p /var/mnt
      - mkdir -p /var/srv

      - ln -sT var/home /home
      - ln -sT var/roothome /root
      - ln -sT var/opt /opt
      - ln -sT var/mnt /mnt
      - ln -sT var/srv /srv
      # One `..`, not two: resolved from /usr it lands exactly on the root.
      # `../../var/usrlocal` resolves to the same place on a real filesystem
      # (because `/..` is `/`) but escapes the root under any sandboxed
      # traversal — bootc 1.16.11's new `runtime-deps` lint walks $PATH with
      # cap_std and died with "a path led outside of the filesystem" (#752).
      - ln -sT ../var/usrlocal usr/local

      # "uninitialized" triggers ConditionFirstBoot=yes for systemd-firstboot.service.
      # An empty file does not.
      - printf 'uninitialized\n' > /etc/machine-id

      # Compile dconf system database from /etc/dconf/db/local.d/ keyfiles.
      # Must run after all elements are staged so the keyfiles exist.
      - dconf update
