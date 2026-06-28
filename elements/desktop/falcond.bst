kind: manual

# falcond: PikaOS gaming performance daemon.
# Provides per-game profiles, SCX scheduler selection (replaces scx_loader),
# AMD 3D VCache management, DMEM cgroup GPU protection, and Proton/Wine support.
# Do NOT run alongside gamemode (conflicts). Requires power-profiles-daemon at runtime.
# Source: https://git.pika-os.com/general-packages/falcond

variables:
  strip-binaries: ""

build-depends:
  - desktop/zig-0.16.bst
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
  # falcond source archive (strips outer falcond/ dir; build root is then falcond/)
  - kind: tar
    url: pikaos_files:general-packages/falcond/archive/v2.0.9.tar.gz
    ref: aee3bf2a7e0f129e9e34e93f3d436535a11d1148a0ef2107cf739c48ca66fea2

  # Zig git deps — staged as Gitea commit archives; populated into the Zig cache via
  # `zig fetch <local-tarball>` (see build-commands). zig fetch handles the 0.16.0 cache
  # format correctly; manual place_git_dep does not work in 0.16.0 for git+https:// deps.
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
    # Populate Zig global cache from local Gitea commit archives using `zig fetch`.
    # In Zig 0.16.0, git+https:// deps are always re-fetched via network regardless of
    # what is placed in p/<hash>/ manually. Only `zig fetch <tarball>` produces a cache
    # entry that zig build recognises as satisfying a git dep.
    #
    # `zig fetch` requires a build.zig in the current directory (or a parent). Build
    # commands run from the source staging root, which is one level above falcond/. Use
    # a throwaway sandbox so zig fetch has a project context without touching falcond's
    # own build.zig.zon.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      SOURCE_DIR="$(pwd)"
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR" /tmp/zig-fetch-sandbox
      touch /tmp/zig-fetch-sandbox/build.zig
      cd /tmp/zig-fetch-sandbox
      for dep in "$SOURCE_DIR"/zig-deps-git/*.tar.gz; do
        echo "zig fetch: $dep"
        zig fetch --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" "$dep"
      done

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
