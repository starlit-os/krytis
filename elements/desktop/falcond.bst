kind: manual

# falcond: PikaOS gaming performance daemon.
# Provides per-game profiles (full PikaOS-Linux/falcond-profiles set vendored — see #258),
# SCX scheduler selection (D-Bus client of scx_loader — falcond has no scheduler-loading
# code of its own; verified via `ldd`/`strings`, no libbpf link, all scx_loader.zig symbols
# are calls to org.scx.Loader), AMD 3D VCache management, DMEM cgroup GPU protection, and
# Proton/Wine support.
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
    url: pikaos_files:general-packages/falcond/archive/v2.0.11.tar.gz
    ref: 35d94db89bf681708a2224d730acddd55d0c45cb856e8968a128ed13b8c5d166

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

  # Transitive deps of otter_desktop/vendor/pipewire Zig binding:
  #
  # valgrind.h@3.23.0 — C header-only, no build.zig.zon, hash format: N-V-__8AAMV2...
  - kind: remote
    url: github_files:allyourcodebase/valgrind.h/archive/refs/tags/3.23.0.tar.gz
    ref: 30bcb1ad585faa189b084b8338bde149425b5c93048b48cbc433b8e97b7a20be
    directory: zig-deps-git

  # pipewire C source@1.6.3 (upstream dep for header extraction by vendor/pipewire)
  - kind: remote
    url: freedesktop_files:pipewire/pipewire/-/archive/1.6.3/pipewire-1.6.3.tar.gz
    ref: 93db72dc06768db548d48ae2b8e96e7c299c89a47f5c4426f152221aa90b0f2d
    directory: zig-deps-git

  # translate-c@46b5609b5ac4c0a896217d1d984f3ae50e4810b5 — Zig C-to-Zig translator
  - kind: remote
    url: codeberg_files:ziglang/translate-c/archive/46b5609b5ac4c0a896217d1d984f3ae50e4810b5.tar.gz
    ref: 4f50eeaa6bfd68fad382a94b6693de5eb86f42474b496b725fab923f9c0eaf1a
    directory: zig-deps-git

  # aro (arocc) @5f5a050569a95ecc40a426f0c3666ae7ef987ede — C compiler frontend, dep of translate-c
  - kind: remote
    url: github_files:Vexu/arocc/archive/5f5a050569a95ecc40a426f0c3666ae7ef987ede.tar.gz
    ref: e20b49a13049e8ef5aa1d798a70d8fc02b691fe44c7c78928aae3d363a1deb7e
    directory: zig-deps-git

  # falcond-profiles: PikaOS's community game-profile set (see #258), supersedes the
  # single-file proton.conf vendored by fix/falcond-user-profiles-dir — this tarball
  # already contains it. No GitHub Releases upstream — pinned to a commit archive,
  # tracked via mise run falcond-profiles-update (kind: tar is a no-op for
  # `bst source track`).
  - kind: tar
    url: github_files:PikaOS-Linux/falcond-profiles/archive/2c521cbe01a3fb092ef3ddf61b111a600ef9f673.tar.gz
    ref: fd8d321e5c7626892a198ee6c40ed107b577ed450bed441f6c6a3121a81671ff
    directory: falcond-profiles-src

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
        -Dcpu=baseline

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

    # Profiles (/usr/share is read-only in bootc; install at image build time).
    # BST's tar source auto-strips the single leading falcond-profiles-<sha>/
    # component, so falcond-profiles-src/usr/share/falcond/ contains profiles/,
    # profiles/handheld/, profiles/htpc/, and system.conf directly — copy the whole tree.
    - |
      install -d "%{install-root}%{datadir}/falcond"
      cp -r falcond-profiles-src/usr/share/falcond/. \
        "%{install-root}%{datadir}/falcond/"

    # user/ is falcond's compiled-in -Duser-profiles-dir default (writable override
    # dir, not part of the falcond-profiles tree above; confirmed via literal path
    # strings in the built binary, not just the config.user_profiles_dir symbol name
    # — that symbol alone is misleading, it's just the struct field, not the resolved
    # path). Without it, falcond's inotify watch fails at startup (error.FileNotFound)
    # and LOADED_PROFILES stays 0 regardless of daemon health.
    - install -d "%{install-root}%{datadir}/falcond/profiles/user"

    # State directories
    - |
      install -Dm644 /dev/stdin \
        "%{install-root}%{indep-libdir}/tmpfiles.d/falcond.conf" <<'EOF'
      d /var/lib/falcond 0755 root root -
      d /etc/falcond 0755 root root -
      EOF
