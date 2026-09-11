kind: cmake

# ananicy-cpp: C++ rewrite of Ananicy — automatic nice/ionice/sched-class/oom_score_adj
# rules for known process classes (browsers, compilers, background daemons).
# Complementary to desktop/falcond.bst: falcond only acts during an active game session
# (org.scx.Loader scheduler swap, 3D VCache, DMEM GPU protection); ananicy-cpp is
# always-on, general process classification and has no daemon-level overlap. Closes #222.
#
# Process-detection backend is netlink, not BPF (USE_BPF_PROC_IMPL left unset —
# undefined CMake cache vars are falsy, this is upstream's own non-BPF default path).
# The BPF backend (libananicycpp_bpf/) needs its own libbpf CPM fetch, a per-arch
# vendored vmlinux.h, and clang -target bpf skeleton compilation — heavier than
# anything else in desktop/ for a feature-parity-only change (upstream's own "What
# works" checklist doesn't distinguish by backend). Netlink needs no extra deps beyond
# what the main binary already pulls in.
#
# Source: https://gitlab.com/ananicy-cpp/ananicy-cpp — not GitHub. The AUR
# `ananicy-cpp` package is stale/orphaned (pinned v1.1.1) now that the package
# graduated into Arch's official `extra` repo at 1.2.0-1 — krytis tracks v1.2.0+
# directly upstream, cross-checked against the `extra` PKGBUILD rather than AUR.
#
# Rules: https://github.com/CachyOS/ananicy-rules — CachyOS's community rule set,
# vendored the same way desktop/falcond.bst vendors PikaOS-Linux/falcond-profiles, but
# tracked with a plain tag glob (real GitHub releases, unlike falcond-profiles) so no
# bespoke mise task is needed for it.
#
# Upstream's own unit already ships real systemd hardening (verified directly by
# building this element and inspecting the installed unit — an earlier web-search-
# sourced claim in this element's history said otherwise and was wrong): a scoped
# CapabilityBoundingSet= (CAP_SYS_NICE CAP_SYS_RESOURCE CAP_DAC_READ_SEARCH
# CAP_SYS_ADMIN CAP_DAC_OVERRIDE, not full root), ProtectSystem=full, ProtectHome=,
# PrivateDevices=, NoNewPrivileges=, MemoryDenyWriteExecute=, and more. krytis adds
# nothing on top — no gap to close here.
#
# pcre2 is NOT vendored here (the original plan's desktop/pcre2.bst was a mistake —
# fdsdk already ships pcre2 via freedesktop-sdk.bst:bootstrap/pcre2.bst, pulled into
# every image transitively through runtime-gnu.bst's bootstrap/grep.bst dependency.
# A second vendored copy collides on every installed path (headers, .pc, libpcre2-*.so,
# man pages) — "not permitted to overlap" at build time, caught by actually building
# this element, not just `mise validate`. Depend on the existing bootstrap element
# directly instead, same pattern as core/openssh.bst's
# freedesktop-sdk.bst:bootstrap/libxcrypt.bst dependency. See issue #812
# for the separate finding this surfaced: fdsdk's bootstrap/pcre2.bst is pinned to
# pcre2-10.47, vulnerable to CVE-2026-89157/89158/89160/89161 (fixed in 10.48) —
# already present in krytis's image today, independent of ananicy-cpp.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- desktop/nlohmann-json.bst
# sed (used by install-commands below) is not part of runtime-gnu.bst's closure —
# same explicit dependency overrides/systemd-base.bst takes for the same reason.
- freedesktop-sdk.bst:bootstrap/sed.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/fmtlib.bst
- freedesktop-sdk.bst:bootstrap/pcre2.bst
- desktop/spdlog.bst

variables:
  cmake-local: >-
    -DUSE_EXTERNAL_JSON=ON
    -DUSE_EXTERNAL_FMTLIB=ON
    -DUSE_EXTERNAL_SPDLOG=ON
    -DENABLE_SYSTEMD=ON
    -DENABLE_REGEX_SUPPORT=ON
    -DSTATIC=OFF

sources:
- kind: git_repo
  url: gitlab:ananicy-cpp/ananicy-cpp.git
  track: v*
  ref: v1.2.0-0-gcf5ac2eb7b9660794f26f274975066f33359c63e

# GCC 16 (fdsdk's shipped compiler) rejects v1.2.0's missing <cstring>/<cstdint>/
# <unistd.h> includes across several files (std::memset, getpid(), etc.) —
# cherry-picked verbatim from upstream's own fix, not yet in a tagged release.
# See patches/ananicy-cpp/glibc-2.42-missing-headers.patch.
- kind: patch
  path: patches/ananicy-cpp/glibc-2.42-missing-headers.patch

# CachyOS's community rules. No GitHub Releases quirk here (unlike falcond-profiles) —
# real tags, so this element's own `bst source track` call keeps both sources current
# in one PR; no second mise task.
- kind: git_repo
  url: github:CachyOS/ananicy-rules.git
  track: '*.*.*'
  ref: 1.1.49-0-g03ef03fbf7e834385377432ccecaedd32e3414bb
  directory: ananicy-rules-src

config:
  # Overriding install-commands replaces the cmake plugin's default
  # (%{make-install} = `cmake --build --target install`) entirely — it does
  # NOT get re-added by `%{install-extra}` (that variable is fdsdk's license-
  # file harvester, see include/install-extra.yml; it's auto-appended after
  # this whole list by fdsdk's project-wide `elements: cmake:` override, so it
  # must NOT be listed here too). %{make-install} must run first since the
  # sed patch below needs the unit file it creates.
  install-commands:
  - |
    %{make-install}

  - |
    # Default confdir must be read-only /usr/share content (bootc), not /etc — override
    # the compiled-in /etc/ananicy.d default via the shipped unit's Environment=, same
    # split as desktop/falcond.bst's /usr/share (read-only) + /var/lib (writable) split.
    sed -i '/^\[Service\]/a Environment=ANANICY_CPP_CONFDIR=%{datadir}/ananicy.d\nEnvironment=ANANICY_CPP_CONF=/var/lib/ananicy-cpp/ananicy.conf' \
      "%{install-root}%{indep-libdir}/systemd/system/ananicy-cpp.service"

  - |
    # CachyOS rule set — rules.cpp only ever reads from CONFDIR (verified: no write
    # calls in src/rules.cpp), safe to bake in as read-only image content.
    install -d "%{install-root}%{datadir}/ananicy.d"
    install -Dm644 ananicy-rules-src/00-cgroups.cgroups ananicy-rules-src/00-types.types \
      "%{install-root}%{datadir}/ananicy.d/"
    cp -r ananicy-rules-src/00-default "%{install-root}%{datadir}/ananicy.d/"

  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-ananicy-cpp.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-ananicy-cpp.preset" <<'EOF'
    enable ananicy-cpp.service
    EOF

  - |
    # Writable state dir: config.cpp writes a generated default ananicy.conf here on
    # first boot if ANANICY_CPP_CONF doesn't exist yet.
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/tmpfiles.d/ananicy-cpp.conf"
    cat > "%{install-root}%{indep-libdir}/tmpfiles.d/ananicy-cpp.conf" <<'EOF'
    d /var/lib/ananicy-cpp 0755 root root -
    EOF
