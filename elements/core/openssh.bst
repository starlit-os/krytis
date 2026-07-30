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
  # default (/etc), so the installed sshd_config lands at /etc/sshd_config
  # instead of /etc/ssh/sshd_config, where the compiled-in sshd default
  # (and systemd's own sshd_config.d/ drop-ins) actually look. sshd then
  # fails "No such file or directory" on every connection, which under
  # socket activation (sshd@.service) manifests as the accepted connection
  # being torn down immediately after the client's version banner
  # ("kex_exchange_identification: read: Connection reset by peer") rather
  # than a clean startup failure. gnome-build-meta carries an upstream
  # patch for exactly this (0003-openssh-Use-etc-ssh-as-sysconfdir.patch)
  # but it's applied to gnome-build-meta's own freedesktop-sdk checkout,
  # not exposed as a reusable override element krytis's junction can point
  # at — so this element duplicates freedesktop-sdk's openssh.bst with the
  # one variable gnome-build-meta's patch adds, rather than reimplementing
  # openssh from scratch (contrast with core/sudo-rs.bst, which replaces
  # sudo outright). See docs/skills/bst.md.
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
