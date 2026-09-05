kind: junction

sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  track: gnome-51
  ref: 51.beta-29-g884873afcd673867ce1fa72f53d83a16aa2c40bf

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
