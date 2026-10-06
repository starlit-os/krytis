kind: junction

sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  track: gnome-51
  ref: 51.0-9-g0b400781f20a940a007855351b29e4810fdc78d8

config:
  options:
    arch: '%{arch}'
    # gnome-build-meta defaults recc to "remote-execution", which makes every
    # compile a REAPI action submitted to buildbox-casd over the sandbox's
    # /tmp/casd.sock. krytis configures no remote execution service, so casd
    # executes each action itself, forking a FUSE stager per compile — and on
    # an 8-vCPU runner that exhausts the process/thread budget mid-build:
    #
    #   FAILED: [code=102] .../Source/MediaInfo/Audio/File_Dat.cpp.o
    #   [ERROR] Error while calling `Execute()` on "unix:/tmp/casd.sock":
    #   … [buildboxcommon_fusestager.cpp:116] [system:11],
    #   errMsg = "error in fork()", errno : Resource temporarily unavailable
    #
    # (core-deps/libmediainfo.bst, 526 ninja edges, killed the publish build.)
    # The mode buys krytis nothing either way: recc's action digest covers
    # RECC_REMOTE_PLATFORM_chrootRootDigest and the compiler binary, both of
    # which differ from upstream's because of x86_64_v3 — so gnome-build-meta's
    # action cache can never hit here, and nothing writes results back
    # (action-cache-enable-update is set only for recc == upload-local-build).
    # passthrough execs the compiler directly, like every fdsdk element.
    # All RECC_* vars are in gnome-build-meta's environment-nocache list, so
    # this does not move any artifact cache key. See docs/skills/bst.md.
    recc: passthrough
    (?):
    - x86_64_v3:
        x86_64_v3: true

  overrides:
    # Make gnome-build-meta use our local fdsdk junction
    freedesktop-sdk.bst: freedesktop-sdk.bst
    # Drop xdg-user-dirs-gtk (#1032) by redirecting it to the package it wraps. It ships
    # but never runs on krytis: its autostart entry is `OnlyShowIn=GNOME;LXDE;Unity;` +
    # `X-systemd-skip=true`, and `user-dirs-update-gtk.service` is static and wanted by
    # nothing. Nautilus's only link to it is gnome-build-meta's `runtime-depends:`. The
    # directories come from `xdg-user-dirs.service` (fdsdk components/xdg-user-dirs.bst).
    # Remove when gnome-build-meta drops that `runtime-depends:`. If upstream renames the
    # path, this entry silently matches nothing; `mise run gtk3-audit` catches that (the
    # element reappears in its graph half).
    core-deps/xdg-user-dirs-gtk.bst: freedesktop-sdk.bst:components/xdg-user-dirs.bst
    # GTK3-free builds of two gnome-build-meta libraries (#1074, #641 step 4). Mirrors,
    # not redirects: each drops sdk/gtk+-3.bst and turns its GTK3 variant off
    # (libportal-gtk3, libgnome-desktop-3), which nothing in the image links. Drift
    # and exit condition: `mise run gtk3-mirror-check`.
    sdk/libportal.bst: overrides/libportal.bst
    core/gnome-desktop.bst: overrides/gnome-desktop.bst
