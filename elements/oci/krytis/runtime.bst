kind: compose

public:
  bst:
    overlap-whitelist:
      - "**/*"

build-depends:
  - oci/krytis/stack.bst

config:
  exclude:
    - devel
    - debug
    - static-blocklist
