kind: manual

# Repackages freedesktop-sdk's OVMF build (components/ovmf-maybe.bst) under
# the /usr/share/edk2/ovmf/ paths krytis's mise/tasks/{boot-vm,boot-test,
# generate-ovmf-vars} search for. No sources of our own — this is pure
# repackaging of an already-tracked upstream component, so the Update Path
# Gate doesn't apply (nothing here to track independently of fdsdk).
#
# fdsdk's ovmf.bst always builds with `-D SECURE_BOOT_ENABLE` (see its
# `opts` variable) regardless of output filename — there is no separate
# "secboot" vs. non-secboot OVMF_CODE build the way Fedora's edk2-ovmf
# package splits them. One build serves both the plain-boot and
# secure-boot-capable paths the mise tasks probe for; only the vars file
# baked by `mise run generate-ovmf-vars` (via virt-fw-vars) determines
# whether Secure Boot is actually enrolled/enforced at runtime.
build-depends:
- freedesktop-sdk.bst:components/ovmf-maybe.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  # .fd firmware volumes aren't ELF binaries — nothing to strip, and
  # freedesktop-sdk-stripper isn't staged here anyway.
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -d "%{install-root}%{datadir}/edk2/ovmf"
    install -Dm644 "%{datadir}/ovmf/OVMF_CODE.fd" "%{install-root}%{datadir}/edk2/ovmf/OVMF_CODE.fd"
    install -Dm644 "%{datadir}/ovmf/OVMF_CODE.fd" "%{install-root}%{datadir}/edk2/ovmf/OVMF_CODE_4M.secboot.fd"
    install -Dm644 "%{datadir}/ovmf/OVMF_VARS.fd" "%{install-root}%{datadir}/edk2/ovmf/OVMF_VARS.fd"
    install -Dm644 "%{datadir}/ovmf/OVMF_VARS.fd" "%{install-root}%{datadir}/edk2/ovmf/OVMF_VARS_4M.secboot.fd"
