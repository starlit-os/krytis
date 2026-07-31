kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
- freedesktop-sdk.bst:components/libfido2.bst
- freedesktop-sdk.bst:components/linux-pam.bst
- freedesktop-sdk.bst:components/openssl.bst

depends:
- freedesktop-sdk.bst:bootstrap/libxcrypt.bst
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/systemd-libs.bst # libfido2 depends on udev

runtime-depends:
- freedesktop-sdk.bst:components/grep.bst
- freedesktop-sdk.bst:components/sed.bst

variables:
  # freedesktop-sdk's own openssh.bst leaves sysconfdir at autotools'
  # default (/etc). Every compiled-in openssh path derives from it, so the
  # whole of sshd's configuration and key material lands directly in /etc:
  # /etc/sshd_config, /etc/moduli, /etc/ssh_host_{rsa,ecdsa,ed25519}_key —
  # instead of under /etc/ssh/ where admins, `ssh-keygen -A`, backup
  # tooling and every distro convention expect them. `sshd` itself still
  # works that way (it looks where it was built to look), so this is a
  # correctness/expectation bug, NOT a service outage: a user editing
  # /etc/ssh/sshd_config would silently have no effect.
  #
  # NOTE: this was originally committed with the claim that it fixed
  # "kex_exchange_identification: read: Connection reset by peer" under
  # socket activation. That was wrong on both counts and the claim has been
  # retracted — the image ships no sshd.socket/sshd@.service at all (only
  # sshd.service with ExecStart=sshd -D), and that reset was QEMU SLIRP
  # hostfwd reporting a closed guest port, caused by the read-only /etc in
  # #396. See docs/skills/bootc-vm.md § `kex_exchange_identification:
  # Connection reset` means nothing is listening.
  #
  # gnome-build-meta carries an upstream patch for exactly this
  # (0003-openssh-Use-etc-ssh-as-sysconfdir.patch) but it's applied to
  # gnome-build-meta's own freedesktop-sdk checkout, not exposed as a
  # reusable override element krytis's junction can point at — so this
  # element duplicates freedesktop-sdk's openssh.bst with the one variable
  # gnome-build-meta's patch adds, rather than reimplementing openssh from
  # scratch (contrast with core/sudo-rs.bst, which replaces sudo outright).
  # See docs/skills/bst.md.
  #
  # KNOWN GAP, deliberately not changed here: the shipped sshd_config has no
  # `Include /etc/ssh/sshd_config.d/*.conf` line, so the drop-in that
  # /usr/lib/tmpfiles.d/20-systemd-userdb.conf symlinks into
  # /etc/ssh/sshd_config.d/ is inert — `sshd -T` reports
  # `authorizedkeyscommand none`. Adding the Include would switch on
  # systemd-userdb key lookup, i.e. change authentication behaviour, which
  # is a Security Gate decision rather than a packaging fix.
  sysconfdir: '/etc/ssh'
  # linux-pam provides /etc/pam.d/sshd, so this is the pam service name
  #
  # freedesktop-sdk's own openssh.bst has a ppc64le-specific --without-hardening
  # arch_options branch (keyed on the junction-internal target_arch option,
  # which isn't defined in krytis's own project scope). krytis only ships
  # x86_64, so it's dropped here rather than reproduced.
  conf-local: >-
    --with-mantype=man
    --with-pam
    --with-pam-service=sshd
    --without-zlib-version-check
    --with-security-key-builtin

config:
  install-commands:
    (>):
    - |
      sed 's/#UsePAM.*/UsePAM yes/' -i "%{install-root}%{sysconfdir}/sshd_config"
      install -Dm755 contrib/ssh-copy-id -t "%{install-root}%{bindir}"
      install -Dm644 contrib/ssh-copy-id.1 -t "%{install-root}%{mandir}/man1"

public:
  bst:
    split-rules:
      vm-only:
      - "%{bindir}/sshd"
      - "%{bindir}/ssh-copy-id"
      - "%{sysconfdir}/sshd_config"
      - "%{libexecdir}/sftp-server"
      - "%{libexecdir}/sshd-*"
      - "%{libexecdir}/ssh-sk-helper"
      - "%{mandir}/man5/sshd_config.5"
      - "%{mandir}/man8/sftp-server.8"
      - "%{mandir}/man8/sshd.8"
      - "%{mandir}/man1/ssh-copy-id.1"

  cpe:
    vendor: 'openbsd'
    # We ignore the patch version because this is set in a different component in CPE
    version-match: '(\d+)_(\d+)'
    ignored:
    - CVE-2007-2768
    - CVE-2023-51767
    - CVE-2025-26465
    - CVE-2025-26466

sources:
- kind: git_repo
  url: github:openssh/openssh-portable.git
  track: V_*
  ref: V_10_3_P1-0-g2d98db98331803cbb820211b2fb0d31a6e71e58e
  # We ignore the patch version because this is set in a different component in CPE
  version-guess-pattern: '(\d+)_(\d+)'
