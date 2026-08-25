kind: manual

# efitools' sign-efi-sig-list, vendored.
#
# freedesktop-sdk deleted its whole EFI element family in 26.08 (commit
# b39e7194, "Remove EFI elements": components/efitools.bst, efitools-bin.bst,
# efitools-bin-maybe.bst, efitools-efi.bst and include/efitools.yml, plus
# components/perl-slurp.bst which existed only to build efitools' man pages).
# No rename, no replacement — upstream simply dropped the dependency from its
# own vm/boot/efi-secure/deps.bst. Confirmed absent from the full
# components/ and components/_private/ trees at 26.08rc.1.
#
# krytis cannot follow them, because the Containerfile's SEAL_SECURE_BOOT
# stage signs PK.auth / KEK.auth / db.auth / dbx.auth with
# `sign-efi-sig-list`, and the only in-image alternative is broken:
# sbsigntools' `sbvarsign` writes the EFI_TIME month from a 0-based tm_mon,
# and UEFI compares those timestamps for authenticated-variable rollback
# protection. See Containerfile and docs/skills/secure-boot.md.
#
# Deliberately NOT a faithful mirror of the element fdsdk carried. Theirs
# built the whole `all` target — nine signed EFI images, PK/KEK/DB key
# material, man pages — and then deleted the EFI half again in
# install-commands. That pulled in help2man, generated boot keys, and perl
# File::Slurp (via xxdi.pl, needed for HashTool's hashlist.h), the last of
# which no longer exists at 26.08rc.1. krytis uses exactly one binary, so
# this builds exactly that one: `make sign-efi-sig-list` compiles
# sign-efi-sig-list.o and lib/lib.a and links -lcrypto. Nothing else.
#
# gnu-efi stays a build-dep even though nothing here produces an EFI image:
# sign-efi-sig-list.c includes <efi.h> for the EFI_SIGNATURE_LIST and
# EFI_TIME layouts it writes, so the headers are needed even for the host
# binary. Found the hard way — without it the compile dies at
# `fatal error: efi.h: No such file or directory`.
#
# The other binaries are not shipped on purpose. cert-to-efi-sig-list in
# particular is a footgun krytis already removed from the seal stage: given
# DER input it writes a well-formed but EMPTY signature list and exits 0,
# which is how every .auth shipped before #438 enrolled an allow-list with no
# certificates in it. sbsigntools' `sbsiglist` does that half now.
#
# Patches: fdsdk carried four. c99.patch (-D_GNU_SOURCE, plus a missing
# strings.h) and gcc15.patch (lib/asn1 typedefs vs C23 bool) are host-build
# correctness fixes and are kept. gnu-efi.patch (aarch64 EFI link flags) and
# binutils_2_46.patch (objcopy --output-target for EFI images) touch only the
# %.efi image path this element never runs, so they are dropped rather than
# carried as dead weight.
#
# Update path: kind: git_repo with a track glob, registered in the
# `track` matrix of .github/workflows/track-bst-sources.yml per AGENTS.md's
# update path gate. Upstream is effectively dormant (v1.9.2 plus four
# commits since 2018), so expect this to sit still.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/_private/gnu-efi.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/openssl.bst

config:
  build-commands:
  - make sign-efi-sig-list

  install-commands:
  - install -Dm755 -t "%{install-root}%{bindir}" sign-efi-sig-list

sources:
- kind: git_repo
  url: kernel:linux/kernel/git/jejb/efitools.git
  track: master
  ref: v1.9.2-4-gb988d20a7f8373cf19c30d5c9c459f3e87f28da2
- kind: patch
  path: patches/efitools/c99.patch
- kind: patch
  path: patches/efitools/gcc15.patch
