kind: pyproject

# pyudev: libudev binding. Solaar imports it at load (hidapi/udev_impl.py)
# for desktop/solaar.bst (#1220). Pure Python: it loads libudev.so.1 with
# ctypes at runtime, so systemd-libs is a runtime dep, not a build one.
build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst

depends:
- freedesktop-sdk.bst:components/python3.bst
- freedesktop-sdk.bst:components/systemd-libs.bst

sources:
- kind: git_repo
  url: github:pyudev/pyudev.git
  track: v*
  ref: v0.24.5-0-g65f292d491ea9e3edbb372365b8ed098b1735214
