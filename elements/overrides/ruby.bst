# SPDX-FileCopyrightText: Freedesktop-SDK Developers
# SPDX-License-Identifier: MIT

# freedesktop-sdk's components/ruby.bst, bumped from 4.0.6 to 4.0.10 ahead of
# the junction. It overrides components/ruby.bst in the freedesktop-sdk
# junction (see elements/freedesktop-sdk.bst overrides).
#
# Why: BIT-ruby-2026-97229 (Critical, in CISA KEV) affects ruby 4.0.6 and is
# fixed in 4.0.8. It blocked the scheduled publish from 2026-11-18. 4.0.10
# (released 2026-11-18) also carries the fixes for ruby-lang's 2026-11-18
# "multiple vulnerabilities in Regexp and String case conversion" advisory, so
# stopping at 4.0.8 would just trade this match for the next one. Ruby ships
# in the image as a runtime dependency of components/opencl.bst (pulled in by
# desktop/mesa-all-codecs.bst); components/asciidoctor.bst also uses it.
#
# Neither the fdsdk 26.08.4 tag nor release/26.08 has a newer ruby, and no
# fdsdk MR bumps it, as of 2026-11-19. This copy is the junction's element
# (freedesktop-sdk 114ae909) byte for byte apart from these comments, the
# `freedesktop-sdk.bst:` prefixes and the source url/ref. The url uses krytis's
# `ruby_lang:` alias (include/aliases.yml) for the same host: fdsdk's
# `tar_https:` alias only resolves inside fdsdk's own project.
# The sha256 matches the one published in ruby-lang's 4.0.10 release notes.
#
# Update path: tied to the freedesktop-sdk.bst junction ref, with no separate
# tracking. `kind: tar` is a no-op for `bst source track`, and the element is
# deliberately not in the track-bst-sources.yml matrix. `mise run ruby-check`
# checks this copy for drift against the junction and fails once the junction
# ships ruby >= 4.0.10 itself.
#
# Delete this element, the check task and the overrides entry once the
# junction ships ruby >= 4.0.10.

kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:bootstrap/zlib-ng.bst
- freedesktop-sdk.bst:bootstrap/libxcrypt.bst
- freedesktop-sdk.bst:components/libffi.bst
- freedesktop-sdk.bst:components/gdbm.bst
- freedesktop-sdk.bst:components/libyaml.bst
- freedesktop-sdk.bst:components/openssl.bst

# Set '--with-compress-debug-sections=no' because of
# https://bugs.ruby-lang.org/issues/12934
variables:
  conf-local: >-
    --enable-pthread
    --enable-ipv6
    --with-compress-debug-sections=no
    --disable-rpath

sources:
- kind: tar
  url: ruby_lang:pub/ruby/4.0/ruby-4.0.10.tar.xz
  ref: 1537f7a6003c436546ecab6b48b6e7725a9af2328f45a8af7f42f41c5df90ab8
