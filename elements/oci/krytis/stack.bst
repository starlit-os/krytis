kind: stack

depends:
  - stacks/base-system.bst
  - stacks/bootc.bst
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
      - ln -s ../../var/usrlocal usr/local

      # "uninitialized" triggers ConditionFirstBoot=yes for systemd-firstboot.service.
      # An empty file does not.
      - printf 'uninitialized\n' > /etc/machine-id
