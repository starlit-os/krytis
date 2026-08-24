kind: junction

sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  track: gnome-50
  ref: 50.4-1-gec28a45a6fcd99195ebc39c1aeda78fd6fe27b8f

config:
  options:
    arch: '%{arch}'
    (?):
    - x86_64_v3:
        x86_64_v3: true

  overrides:
    # Make gnome-build-meta use our local fdsdk junction
    freedesktop-sdk.bst: freedesktop-sdk.bst
