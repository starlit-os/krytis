kind: junction

sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  track: gnome-50
  ref: 50.3-6-g941b83247fec95877533afb3803f7bc15e755c2f

config:
  options:
    arch: '%{arch}'
    (?):
    - x86_64_v3:
        x86_64_v3: true

  overrides:
    # Make gnome-build-meta use our local fdsdk junction
    freedesktop-sdk.bst: freedesktop-sdk.bst
