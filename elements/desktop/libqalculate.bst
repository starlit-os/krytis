kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/curl.bst
- freedesktop-sdk.bst:components/gmp.bst
- freedesktop-sdk.bst:components/icu.bst
- freedesktop-sdk.bst:components/libxml2.bst
- freedesktop-sdk.bst:components/mpfr.bst

sources:
- kind: tar
  url: github_files:Qalculate/libqalculate/releases/download/v5.10.0/libqalculate-5.10.0.tar.gz
  ref: 904592d33a98ed4a26a59fa34c855578e096144fb91965b8afc90e06797dba8e

variables:
  # CXX carries the standard, rather than CXXFLAGS, on purpose. The release
  # tarball's pre-generated configure probes "g++ option to enable C++11
  # features" and answers -std=gnu++11, appending it to CXX ahead of every
  # CXXFLAGS entry. Naming a newer standard in CXX makes that same probe answer
  # "none needed" instead, so nothing has to rely on GCC's last--std-wins
  # ordering, and fdsdk's hardening CXXFLAGS are left untouched.
  #
  # Needed since fdsdk 26.08, which moved ICU 77.1 -> 78.3 (#305). ICU 78's
  # unicode/localpointer.h declares `template <typename Type, auto
  # closeFunction>` — an auto non-type template parameter, C++17 — and any
  # translation unit reaching it under gnu++11 dies with "parameter declared
  # 'auto'". libqalculate includes it via unicode/ucasemap.h in Calculator.cc.
  #
  # Not fixable by updating: libqalculate's configure.ac sets no C++ standard
  # at all, on 5.10.0 or on master, so 5.12.0 fails identically. Drop this only
  # once upstream adopts AX_CXX_COMPILE_STDCXX(17) or equivalent.
  conf-local: >-
    --without-readline
    CXX="g++ -std=gnu++17"
