kind: autotools

build-depends:
- public-stacks/buildsystem-autotools.bst
- components/libfido2.bst
- components/linux-pam.bst
- components/openssl.bst

depends:
- public-stacks/runtime-minimal.bst
- components/systemd-libs.bst # libfido2 ≥1.10 hard libudev dep

variables:
  conf-local: --with-pam-dir=%{libdir}/security

sources:
- kind: git_repo
  url: github:Yubico/pam-u2f.git
  track: pam_u2f-*
  ref: pam_u2f-1.4.0-0-g1d85db26b590c191a508d06eddc86fbff6b5009e
