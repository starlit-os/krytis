kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
- freedesktop-sdk.bst:components/libfido2.bst
- freedesktop-sdk.bst:components/linux-pam.bst
- freedesktop-sdk.bst:components/openssl.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/systemd-libs.bst # libfido2 ≥1.10 hard libudev dep

variables:
  conf-local: --with-pam-dir=%{libdir}/security --disable-man

sources:
- kind: git_repo
  url: github:Yubico/pam-u2f.git
  track: pam_u2f-*
  ref: pam_u2f-1.4.0-0-g1d85db26b590c191a508d06eddc86fbff6b5009e
