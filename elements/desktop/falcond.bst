kind: manual

# falcond: PikaOS gaming performance daemon.
# Provides per-game profiles, SCX scheduler selection (replaces scx_loader),
# AMD 3D VCache management, DMEM cgroup GPU protection, and Proton/Wine support.
# Do NOT run alongside gamemode (conflicts). Requires power-profiles-daemon at runtime.
# Source: https://git.pika-os.com/general-packages/falcond

variables:
  strip-binaries: ""

build-depends:
  - desktop/zig.bst
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
  # falcond source archive (strips outer falcond/ dir; build root is then falcond/)
  - kind: tar
    url: pikaos_files:general-packages/falcond/archive/v2.0.9.tar.gz
    ref: aee3bf2a7e0f129e9e34e93f3d436535a11d1148a0ef2107cf739c48ca66fea2

  # Zig git deps (git+https:// — cannot use zig fetch, placed manually into Zig cache)
  # otter_conf v0.11.25 @ 8cf5df2117daba9b3af87cdedf3f92aa24a5f40e
  - kind: remote
    url: pikaos_files:otter-shell/otter-conf/archive/8cf5df2117daba9b3af87cdedf3f92aa24a5f40e.tar.gz
    ref: 1eb5375d85d631872f019b14bf95a3f4b2e42081cf80a966aed6cc6b9ab1669c
    directory: zig-deps-git

  # otter_desktop v0.11.25 @ c018c37f32873eb93603a93450e101064de1ded6
  - kind: remote
    url: pikaos_files:otter-shell/otter-desktop/archive/c018c37f32873eb93603a93450e101064de1ded6.tar.gz
    ref: 8a22ec953e1f20f8dc8429ec71f5f08b7347900bcf34a14b7397be12c0fee6e9
    directory: zig-deps-git

  # otter_utils v0.11.25 @ de2219f05c41a180bce304cf377a2983c303e870
  - kind: remote
    url: pikaos_files:otter-shell/otter-utils/archive/de2219f05c41a180bce304cf377a2983c303e870.tar.gz
    ref: 866b2a5ea57a1bc724b5c34405efa26457256e7d035912741edea0ebfb87a1c8
    directory: zig-deps-git

config:
  build-commands:
    # Stage 1: Set up Zig cache
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"

    # Stage 2: Place all pika-os git deps into Zig cache at their content-hash paths.
    # git+https:// deps cannot be fetched by zig fetch from a tarball; extract manually.
    # Hash values come from build.zig.zon .dependencies[*].hash fields.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"

      place_git_dep() {
        local tarball="$1" zig_hash="$2"
        local dest="$ZIG_GLOBAL_CACHE_DIR/p/$zig_hash"
        mkdir -p "$dest"
        tar xf "$tarball" --strip-components=1 -C "$dest"
      }

      place_git_dep \
        "zig-deps-git/8cf5df2117daba9b3af87cdedf3f92aa24a5f40e.tar.gz" \
        "otter_conf-1.11.25-d7vdxExeAgDhUBW5RuaeGgpYbxLTtsBTMmSI_1wMoZer"

      place_git_dep \
        "zig-deps-git/c018c37f32873eb93603a93450e101064de1ded6.tar.gz" \
        "otter_desktop-0.11.25-nwUfzR_gMAAgl_0gKsnjpPiOOkEfVxTP8eL4_3kow8uQ"

      place_git_dep \
        "zig-deps-git/de2219f05c41a180bce304cf377a2983c303e870.tar.gz" \
        "otter_utils-0.11.25-DYWsuzmFAQD_zzQrRwYPYvnchY1lLp8rJoUjZwtED1Wx"

  install-commands:
    # Build: source lives in the falcond/ subdir of the repo root
    - |
      cd falcond
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      DESTDIR="%{install-root}" \
      zig build \
        --prefix /usr \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dpie=true

    # Service file (zig build does not install it)
    - |
      install -Dm644 falcond/debian/falcond.service \
        "%{install-root}%{indep-libdir}/systemd/system/falcond.service"

    # Enable on graphical.target
    - |
      install -Dm644 /dev/stdin \
        "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-falcond.preset" <<'EOF'
      enable falcond.service
      EOF

    # State directories
    - |
      install -Dm644 /dev/stdin \
        "%{install-root}%{indep-libdir}/tmpfiles.d/falcond.conf" <<'EOF'
      d /var/lib/falcond 0755 root root -
      d /etc/falcond 0755 root root -
      EOF
