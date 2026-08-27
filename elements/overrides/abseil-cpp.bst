kind: cmake

# freedesktop-sdk's components/abseil-cpp.bst, mirrored here so one patch can
# be applied on top of it — used to override components/abseil-cpp.bst in the
# freedesktop-sdk junction (see elements/freedesktop-sdk.bst overrides).
#
# abseil 20260526.0 (what fdsdk 26.08rc.1 pins) does this in
# absl/container/internal/raw_hash_set.h:
#
#     #ifdef __BMI2__
#     #include <bmi2intrin.h>
#     #endif  // __BMI2__
#
# GCC refuses that outright — its bmi2intrin.h opens with
# `#error "Never use <bmi2intrin.h> directly; include <x86gprintrin.h>
# instead."`, guarded on _X86GPRINTRIN_H_INCLUDED. The patch swaps the include
# for <immintrin.h>, the portable umbrella that provides the same _bzhi_u32 /
# _bzhi_u64 the header goes on to use at lines 537-545. Deleting the include
# instead does not work: the BMI2 path is live code, not a leftover.
#
# Why krytis hits this and freedesktop-sdk does not: the include is gated on
# __BMI2__, which the compiler only defines when BMI2 is enabled. krytis builds
# the whole graph with `-o x86_64_v3 true`, and x86-64-v3 implies BMI2. fdsdk's
# own CI builds baseline x86_64, never defines __BMI2__, and never compiles the
# offending line. Nothing is wrong with their pin from where they are standing.
#
# Upstream already fixed it, by deletion rather than by include: abseil commit
# 09a054bc6 (2026-06-08, "Type erase clear function in order to move more code
# to cpp file and speed up compilation") removed the __BMI2__ block and the
# _bzhi calls together. The defect exists only in the 20260526.* series —
# 20260107.* predates it, 20260817.0 ships without it. So this override is a
# window, not a permanent fork.
#
# Not fixed here by bumping to 20260817.0 on purpose. That would drag three
# months of unvalidated abseil into a graph where a lot of things link it,
# to solve a one-line include problem. Patch the version fdsdk validated.
#
# Everything except the extra patch source mirrors freedesktop-sdk exactly, so
# BST reuses the remote-cached artifacts of the shared dependency graph.
#
# Update path: tied to the freedesktop-sdk.bst junction ref — no separate
# tracking (deliberately not in the track-bst-sources.yml matrix; `bst source
# track` here would fetch abseil's latest tag and blow away the pinned ref
# fdsdk expects). Drift-checked by `mise run abseil-cpp-check`.
#
# Delete this element, its patch, the check task and the override entry in
# elements/freedesktop-sdk.bst once the junction pins abseil 20260817.0 or
# newer. `mise run abseil-cpp-check` fails the moment that happens.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst

depends:
# runtime-minimal, NOT runtime-gnu — deliberate, and the one line in this repo
# that the 26.08 global rename must not touch. This element is diffed against
# freedesktop-sdk's copy by `mise run abseil-cpp-check`, and upstream uses the
# new stripped-down runtime-minimal here. A cmake build needs no shell.
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  cmake-local: >-
    -DBUILD_SHARED_LIBS=ON
    -DCMAKE_SKIP_INSTALL_RPATH=ON

public:
  bst:
    split-rules:
      devel:
        (>):
        - '%{libdir}/libabsl_*.so'

sources:
- kind: git_repo
  url: github:abseil/abseil-cpp.git
  track: '[0-9]*.[0-9]'
  ref: 20260526.0-0-g5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a
- kind: patch
  path: patches/abseil-cpp/bmi2intrin-via-immintrin.patch
