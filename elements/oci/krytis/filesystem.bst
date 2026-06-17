kind: compose

build-depends:
  - oci/krytis/manifest.bst
  - oci/krytis/runtime.bst
  - freedesktop-sdk.bst:components/gcc.bst

config:
  exclude:
    - debug
    - extra
    - static-blocklist
