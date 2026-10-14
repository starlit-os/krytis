kind: pyproject

# python-evdev: input-device bindings. Solaar's logitech_receiver/diversion.py
# imports it at load, and settings_templates pulls diversion in, so Solaar's
# device/receiver modules fail without it (desktop/solaar.bst, #1220).
# C extension: setup.py generates ecodes.c from /usr/include/linux/input*.h,
# which glibc's runtime dep on bootstrap/linux-headers.bst stages.
build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst

depends:
- freedesktop-sdk.bst:components/python3.bst

sources:
- kind: git_repo
  url: github:gvalkov/python-evdev.git
  track: v*
  ref: v2.0.0-0-g9508e5239ac50cd2ea9099519b3f17c9e3fc154d
