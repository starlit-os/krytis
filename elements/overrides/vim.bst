kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  command-subdir: src
  # FIXME: vim bundles configure script which is broken with
  # build-dir. We would need to generate our own to fix things.
  build-dir: ''

sources:
- kind: git_repo
  url: github:vim/vim.git
  # we track only major releases because there are several new minor tags every day
  track: v*.0
  ref: v9.2.0-0-ge7e21018fc0b60c153c8e668f696d95e574cc5a4
- kind: patch
  path: patches/vim/vim-not-show-in-gnome.patch
- kind: patch
  path: patches/vim/gvim-not-show-in-gnome.patch
