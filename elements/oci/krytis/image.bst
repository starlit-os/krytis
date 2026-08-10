kind: script

build-depends:
  - freedesktop-sdk.bst:components/fakecap.bst
  - freedesktop-sdk.bst:components/oci-builder.bst
  - freedesktop-sdk.bst:components/glib.bst
  - freedesktop-sdk.bst:components/fontconfig.bst
  - freedesktop-sdk.bst:vm/prepare-image.bst
  - oci/krytis/init-scripts.bst
  - filename: oci/krytis/filesystem.bst
    config:
      location: /layer
  - filename: oci/os-release.bst
    config:
      location: /layer

environment:
  LD_PRELOAD: /usr/libexec/fakecap/fakecap.so
  FAKECAP_DB: /fakecap

variables:
  sysroot-seed: 042dab3d-c024-448b-a70e-927daef22a59

config:
  commands:
    - mkdir /fakecap

    - |
      prepare-image.sh \
         --sysroot /layer \
         --initscripts /initial_scripts \
         --seed "%{sysroot-seed}" \
         --noroot --noboot >/dev/null

    - systemd-sysusers --root /layer

    - |
      # Use our issue file from core/os-release.bst, not the fdsdk default
      rm /layer/usr/share/factory/etc/issue
      cp /layer/etc/issue /layer/usr/share/factory/etc/issue

    - |
      # Remove pam factory files that conflict with our PAM config
      rm -f /layer/usr/share/factory/etc/pam.d/other
      rm -f /layer/usr/share/factory/etc/pam.d/system-auth

    - |
      # Prevent users from changing their login shell — see
      # https://tim.siosm.fr/blog/2023/12/22/dont-change-defaut-login-shell/
      rm /layer/usr/bin/chsh

    - |
      # glibc ships a Makefile into /var/db for regenerating database files;
      # it has no runtime purpose and bootc flags non-dir files in /var.
      rm -f /layer/var/db/Makefile

    - glib-compile-schemas /layer/usr/share/glib-2.0/schemas

    - |
      # Rebuild the shared library linker cache for the sysroot.
      # Mesa installs libgbm, libEGL, and DRI drivers under
      # %{libdir}/GL/default/lib — a non-standard path that ldconfig
      # does not search by default. Without this, any binary linking
      # against mesa libs (niri, future noctalia-greeter, etc.) fails
      # at runtime with "cannot open shared object file". The same
      # applies to config/codecs-extra-ldconfig.bst, which drops an
      # /etc/ld.so.conf.d entry for codecs-extra's H.264-enabled ffmpeg.
      #
      # Two glibc -r quirks make the obvious invocation a silent no-op
      # (see docs/skills/bst.md § ldconfig -r):
      #
      #   1. ldconfig only keeps opt_chroot set when the real chroot()
      #      syscall fails — which it does in the unprivileged BST
      #      sandbox. So every path, including -f, is resolved INSIDE
      #      /layer. The old `-f /layer/etc/ld.so.conf` therefore looked
      #      for /layer/layer/etc/ld.so.conf, missed, and exited 0 with a
      #      cache holding only the default trusted dirs.
      #   2. With opt_chroot set, parse_conf_include() rejects a relative
      #      `include` pattern outright. fdsdk's /etc/ld.so.conf ships
      #      `include ld.so.conf.d/*.conf`, so pointing -f at it fails
      #      with "need absolute file name for configuration file".
      #
      # Hence a build-only config carrying the absolute include. The
      # shipped /etc/ld.so.conf is left untouched (it is correct for the
      # unchrooted ldconfig that runs on a booted system).
      printf 'include /etc/ld.so.conf.d/*.conf\n' > /layer/etc/ld.so.conf.build
      ldconfig -r /layer -f /etc/ld.so.conf.build
      rm /layer/etc/ld.so.conf.build

    - |
      # Bake fontconfig cache into image so fc-list and font selectors work
      # on first boot without requiring manual fc-cache.
      # FONTCONFIG_SYSROOT makes fc-cache read /layer/etc/fonts/fonts.conf,
      # scan /layer/usr/share/fonts/, and write to /layer/usr/lib/fontconfig/cache/.
      # Running here (not in stack.bst integration commands) ensures all font
      # files are present in the assembled sysroot before the cache is built.
      FONTCONFIG_SYSROOT=/layer fc-cache -f

    - |
      cd "%{install-root}"
      build-oci <<EOF
      mode: oci
      gzip: disabled
      images:
      - os: linux
        architecture: "%{go-arch}"
        layer: /layer
        comment: "Import Krytis layer"
        config:
          Labels:
            'com.github.containers.toolbox': 'true'
            'org.opencontainers.image.source': 'https://github.com/starlit-os/krytis'
            'org.opencontainers.image.url': 'https://github.com/starlit-os/krytis'
            'containers.bootc': '1'
        index-annotations:
          'org.opencontainers.image.ref.name': 'localhost/krytis-input:latest'
      EOF
