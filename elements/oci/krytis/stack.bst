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
      - rm -rfv /boot /run
      - mkdir /boot
      - mkdir /run
      - mkdir /sysroot
      - mkdir /sysroot/ostree
      - ln -s sysroot/ostree ostree

      - rm --verbose --recursive --force /root /home /opt /mnt /var

      # These are also created by config/bootc.bst tmpfiles at runtime,
      # but must exist in the OCI image for container use.
      - mkdir -p /var/home
      - mkdir -p /var/roothome
      - mkdir -p /var/opt
      - mkdir -p /var/mnt
      - mkdir -p /var/srv

      - ln -s var/home /home
      - ln -s var/roothome /root
      - ln -s var/opt /opt
      - ln -s var/mnt /mnt
      - ln -s var/srv /srv
      # One `..`, not two: resolved from /usr it lands exactly on the root.
      # `../../var/usrlocal` resolves to the same place on a real filesystem
      # (because `/..` is `/`) but escapes the root under any sandboxed
      # traversal — bootc 1.16.11's new `runtime-deps` lint walks $PATH with
      # cap_std and died with "a path led outside of the filesystem" (#752).
      - ln -s ../var/usrlocal usr/local

      # "uninitialized" triggers ConditionFirstBoot=yes for systemd-firstboot.service.
      # An empty file does not.
      - printf 'uninitialized\n' > /etc/machine-id

      # Compile dconf system database from /etc/dconf/db/local.d/ keyfiles.
      # Must run after all elements are staged so the keyfiles exist.
      - dconf update
