kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
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
  conf-local: >-
    --without-readline
