kind: autotools

# libsodium (jedisct1/libsodium): modern cryptography library. Required by
# noctalia since v5.0.0-beta.4 (src/security/secret_store.cpp,
# encrypted_file_store.cpp — credential/secret encryption); not shipped by
# the freedesktop-sdk or gnome-build-meta junctions. No build-system deps
# beyond autotools itself — self-contained C library, no external linkage.
# Release tarball (not a bare git checkout) ships a pre-generated configure,
# so no autogen.sh step is needed. Tracked via mise run libsodium-update
# (kind: tar is a no-op for `bst source track`).

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
- kind: tar
  url: github_files:jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz
  ref: adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349
