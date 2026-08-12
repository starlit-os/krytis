kind: junction

sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  track: master
  ref: 49-branchpoint-863-g93b6ade7f600930c2dd427702284f26165e52225

config:
  options:
    arch: '%{arch}'
    (?):
    - x86_64_v3:
        x86_64_v3: true

  overrides:
    # Make gnome-build-meta use our local fdsdk junction
    freedesktop-sdk.bst: freedesktop-sdk.bst
