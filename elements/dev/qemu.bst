kind: autotools

# QEMU: headless x86_64 system emulator for mise's boot-vm/boot-test tasks
# (native KVM+UEFI VM boot testing). Not the GNOME-facing GTK/SDL desktop
# virt machinery — this is CI-style headless testing tooling for krytis
# itself, hence elements/dev/ not elements/desktop/. See docs/skills/bst.md
# § Never install payload content under /opt for the related secure-boot
# testing context this unblocks.
#
# Deliberately does not depend on gnome-build-meta.bst:core-deps/qemu.bst
# (GNOME's own qemu recipe) — that build enables GTK+SDL+spice+virglrenderer
# +usbredir+smartcard+pipewire for an interactive desktop VM viewer, none of
# which mise's boot-test/boot-vm tasks use (`-nographic`, virtio-net user
# networking, a monitor socket). Building against freedesktop-sdk's own
# components directly avoids pulling that entire GUI stack into the image
# for a headless testing tool.
build-depends:
- freedesktop-sdk.bst:components/perl.bst          # configure/build scripts
- freedesktop-sdk.bst:components/python3.bst        # meson invoked via configure
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst

depends:
- freedesktop-sdk.bst:components/dtc.bst             # meson subproject check, unconditional on target-list
- freedesktop-sdk.bst:components/glib.bst
- freedesktop-sdk.bst:components/libslirp.bst       # -netdev user (boot-test's SSH port-forward)
- freedesktop-sdk.bst:components/liburing.bst
- freedesktop-sdk.bst:components/pixman.bst
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  # The autotools plugin's default `MAKEFLAGS: -j%{max-jobs}` doesn't reach
  # QEMU's build: `make` just invokes `ninja -C build` as a single recipe,
  # and ninja doesn't participate in GNU make's jobserver protocol, so it
  # fell back to serial. Force it explicitly.
  make-args: -j$(nproc)

  targets: --target-list=x86_64-softmmu

  conf-local: >-
    --disable-werror
    --enable-system
    --disable-user
    --enable-kvm
    --enable-slirp
    --enable-linux-io-uring
    --disable-gtk
    --disable-sdl
    --disable-vnc
    --disable-spice
    --disable-curses
    --disable-usb-redir
    --disable-smartcard
    --disable-virglrenderer
    --disable-brlapi
    --audio-drv-list=

  # --exec-prefix --disable-static are not accepted
  conf-args: >-
    %{targets}
    --prefix="%{prefix}"
    --bindir="%{bindir}"
    --sbindir="%{sbindir}"
    --sysconfdir="%{sysconfdir}"
    --datadir="%{datadir}"
    --includedir="%{includedir}"
    --libdir="%{libdir}"
    --libexecdir="%{libexecdir}"
    --localstatedir="%{localstatedir}"
    --sharedstatedir="%{sharedstatedir}"
    --mandir="%{mandir}"
    --infodir="%{infodir}"
    --localstatedir=/
    --host=%{triplet}
    --build=%{triplet}
    %{conf-local}

config:
  install-commands:
    (>):
    # hppa-firmware*.img cause errors with freedesktop-sdk-stripper, same
    # exclusion gnome-build-meta's core-deps/qemu.bst applies. We don't even
    # build the hppa target, but the shared firmware blobs still land here.
    - rm -f '%{install-root}'/usr/share/qemu/hppa-firmware*.img

sources:
- kind: tar
  # Pinned to 10.1.3, not the newest release: QEMU 11.x's configure/meson
  # step requires the `qemu.qmp` PyPI package for QAPI codegen and tries to
  # fetch it over the network, which fails in BST's offline build sandbox
  # ("Could not provide build dependency 'qemu.qmp==0.0.5'"). 10.1.3 is the
  # exact version gnome-build-meta.bst:core-deps/qemu.bst already builds
  # cleanly in this same freedesktop-sdk ecosystem — predates the qemu.qmp
  # requirement. Revisit once freedesktop-sdk ships a python3-qemu-qmp
  # component (none exists as of this writing).
  url: qemu:qemu-10.1.3.tar.xz
  ref: fbaa7a0d7a9a1deb5695b125916746ec28fe0de6275d4454f3e3bbaf8b339b53
