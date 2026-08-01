kind: meson

# gnome-build-meta core-deps/systemd-base.bst, mirrored here so one patch can be
# applied on top of it — used to override components/systemd-base.bst in the
# freedesktop-sdk junction (see elements/freedesktop-sdk.bst overrides).
#
# The patch backports systemd b8968c49 ("update-utmp: shorten comm on
# boot/shutdown"), which landed after v260 was cut. Without it,
# systemd-update-utmp.service fails on every boot with "Failed to send audit
# message: Invalid argument" and the system reports `degraded` (#417): libaudit
# rejects any comm argument of 16 bytes or more, and v260 passes the 19-byte
# "systemd-update-utmp".
#
# Everything except the extra source mirrors gnome-build-meta exactly, so BST
# reuses the remote-cached artifacts of the shared dependency graph; only
# systemd itself rebuilds.
#
# Update path: tied to the gnome-build-meta.bst junction ref — no separate
# tracking. When the junction bumps, resync this file against
# elements/core-deps/systemd-base.bst in gnome-build-meta; `mise run
# systemd-base-check` diffs the two and fails on drift.
#
# Delete this element, its patch and the override entry once the junction
# carries systemd v261 or newer, which contains b8968c49 upstream.

sources:
- kind: git_repo
  url: github:systemd/systemd.git
  track: v*
  exclude:
  - '*-rc*'
  ref: v260.2-0-gf1d0952a125b96b7ab2f1ff29a87448ade8ac29b
- kind: patch
  path: patches/systemd/update-utmp-shorten-comm.patch

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:bootstrap/sed.bst
- freedesktop-sdk.bst:bootstrap/gawk.bst
- freedesktop-sdk.bst:bootstrap/grep.bst
- freedesktop-sdk.bst:bootstrap/diffutils.bst
- freedesktop-sdk.bst:components/audit.bst
- freedesktop-sdk.bst:components/gperf.bst
- freedesktop-sdk.bst:components/m4.bst
- freedesktop-sdk.bst:components/libapparmor.bst
- freedesktop-sdk.bst:components/libcap.bst
- freedesktop-sdk.bst:components/libgcrypt.bst
- freedesktop-sdk.bst:components/libgpg-error.bst
- freedesktop-sdk.bst:components/libseccomp.bst
- freedesktop-sdk.bst:components/lz4.bst
- freedesktop-sdk.bst:components/zstd.bst
- freedesktop-sdk.bst:components/util-linux-full.bst
- freedesktop-sdk.bst:components/libarchive.bst
- freedesktop-sdk.bst:components/linux-pam.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/pyelftools.bst
- freedesktop-sdk.bst:components/libxslt.bst
- freedesktop-sdk.bst:components/docbook-xsl.bst
- freedesktop-sdk.bst:components/cryptsetup-lvm2-stage1.bst
- freedesktop-sdk.bst:components/p11-kit.bst
- freedesktop-sdk.bst:components/libfido2.bst
- freedesktop-sdk.bst:components/libidn2.bst
- freedesktop-sdk.bst:components/openssl.bst
- freedesktop-sdk.bst:components/python3-pefile.bst
- freedesktop-sdk.bst:components/python3-jinja2.bst
- freedesktop-sdk.bst:components/apparmor.bst
- freedesktop-sdk.bst:components/tpm2-tss.bst
- freedesktop-sdk.bst:components/curl.bst
- freedesktop-sdk.bst:components/libqrencode.bst
- freedesktop-sdk.bst:components/iptables.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/libmicrohttpd.bst
- freedesktop-sdk.bst:components/bpf-maybe.bst
- freedesktop-sdk.bst:components/libbpf.bst
- freedesktop-sdk.bst:components/llvm.bst

config:
  install-commands:
    (>):
    - |
      shopt -s nullglob
      for name in %{install-root}%{indep-libdir}/systemd/boot/efi/*.elf.stub
      do
      chmod a-x ${name}
      done
      shopt -u nullglob

variables:
  efi: 'false'
  bpf-framework: 'disabled'
  fallback-ntp-servers: "gnome.pool.ntp.org"
  fallback-dns-servers: >-
    1.1.1.1#one.one.one.one
    1.0.0.1#one.one.one.one
    2606:4700:4700::1111#one.one.one.one
    2606:4700:4700::1001#one.one.one.one
  (?):
  - arch in ["x86_64", "aarch64", "riscv64"]:
      efi: 'true'
  - arch in ["x86_64", "aarch64"]:
      bpf-framework: 'enabled'

  meson-local: >-
    -Dsysvinit-path=%{sysconfdir}/init.d
    -Dsystem-uid-max=999
    -Dsystem-gid-max=999
    -Dusers-gid=100
    -Dbootloader=%{efi}
    -Defi=%{efi}
    -Dfirstboot=true
    -Dntp-servers="%{fallback-ntp-servers}"
    -Ddns-servers="%{fallback-dns-servers}"
    -Ddefault-dnssec=no
    -Didn=true
    -Dman=enabled
    -Dhtml=enabled
    -Dtpm=true
    -Dsbat-distro=gnome-os
    -Dsbat-distro-generation=1
    -Dsbat-distro-summary="GNOME OS"
    -Dsbat-distro-url=https://gitlab.gnome.org/GNOME/gnome-build-meta
    -Dversion-tag="$(git describe --abbrev=7 | sed "s/^v//")"
    -Dxenctrl=disabled
    -Dbpf-framework=%{bpf-framework}
    -Dgnutls=disabled
    -Dglib=disabled
    -Ddbus=disabled
    -Dstatus-unit-format-default=combined
    -Dselinux=disabled
    -Dukify=%{efi}
    -Dkernel-install=true
    -Dvmlinux-h=provided
    -Dvmlinux-h-path='%{includedir}/%{gcc_triplet}/linux/vmlinux.h'

public:
  cpe:
    vendor: 'freedesktop'
    product: 'systemd'
    version-match: '\d+'

  bst:
    split-rules:
      kernel-install:
      - '%{bindir}/kernel-install'
      - '%{datadir}/bash-completion/completions/kernel-install'
      - '%{datadir}/zsh/site-functions/_kernel-install'
      - '%{indep-libdir}/kernel'
      - '%{indep-libdir}/kernel/**'
      - '%{mandir}/man8/kernel-install.8'
      - '%{docdir}/systemd/html/kernel-install.html'
      - '%{debugdir}%{bindir}/kernel-install.debug'
      - '%{sysconfdir}/kernel'
      - '%{sysconfdir}/kernel/**'
      ukify:
      - '%{bindir}/ukify'
      - '%{indep-libdir}/systemd/ukify'
      - '%{mandir}/man1/ukify.1'
      - '%{docdir}/systemd/html/ukify.html'
      systemd-libs:
      - '%{libdir}'
      - '%{libdir}/libsystemd*.so*'
      - '%{libdir}/libudev*.so*'
      - '%{libdir}/libnss_resolve.so*'
      - '%{libdir}/pkgconfig'
      - '%{libdir}/pkgconfig/libsystemd.pc'
      - '%{libdir}/pkgconfig/libudev.pc'
      - '%{includedir}'
      - '%{includedir}/libudev.h'
      - '%{includedir}/systemd'
      - '%{includedir}/systemd/**'
      - '%{debugdir}/dwz/%{stripdir-suffix}/*'
      - '%{debugdir}%{libdir}/libsystemd*.so*'
      - '%{debugdir}%{libdir}/libudev*.so*'
      - '%{debugdir}%{libdir}/libnss_resolve.so*'
      - '%{sourcedir}'
      - '%{sourcedir}/**'
      systemd-license:
      - "%{project_licensedir}"
      - "%{project_licensedir}/**"
