kind: junction

sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  track: gnome-50
  ref: 50.3-5-g4b25046df8a03b6341db7aa8956c55fbbc0c1365

config:
  options:
    arch: '%{arch}'
    (?):
    - x86_64_v3:
        x86_64_v3: true

  overrides:
    # Make gnome-build-meta use our local fdsdk junction
    freedesktop-sdk.bst: freedesktop-sdk.bst
