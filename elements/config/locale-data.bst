kind: script

# Generates only the locales Krytis needs instead of the full glibc SUPPORTED
# list (~400+ locales) that freedesktop-sdk.bst:components/locales.bst produces.
#
# en_SE: added in glibc 2.43; blocked until fdsdk bumps past 2.42.x.
# Uncomment and add sv_SE.UTF-8 → en_SE.UTF-8 alias once available.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/gzip.bst

config:
  commands:
  - mkdir -p %{install-root}/usr/lib/locale
  - localedef --prefix=%{install-root} --no-archive -i en_US -f UTF-8 en_US.UTF-8
  - localedef --prefix=%{install-root} --no-archive -i sv_SE -f UTF-8 sv_SE.UTF-8

public:
  bst:
    split-rules:
      locale:
        (>):
        - "%{indep-libdir}/locale"
        - "%{indep-libdir}/locale/**"
