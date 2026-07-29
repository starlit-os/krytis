kind: pyproject

# Provides virt-fw-vars, used by mise/tasks/generate-ovmf-vars to bake
# PK/KEK/db certs into an OVMF vars template for QEMU secure boot testing.
# All of virt-firmware's install_requires (cryptography, pefile, pyyaml,
# requests) are already packaged as freedesktop-sdk components — no new
# Rust/C-extension build needed here, just wiring up the pure-Python
# console_scripts entry points against them.
build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst

depends:
- freedesktop-sdk.bst:components/python3.bst
- freedesktop-sdk.bst:components/python3-cryptography.bst
- freedesktop-sdk.bst:components/python3-pefile.bst
- freedesktop-sdk.bst:components/python3-pyyaml.bst
- freedesktop-sdk.bst:components/python3-requests.bst

sources:
- kind: git_repo
  url: gitlab:kraxel/virt-firmware.git
  track: v*
  ref: v26.7.4-0-g2974ca36bb14026224f153d6e5ec39f100bfbb24
