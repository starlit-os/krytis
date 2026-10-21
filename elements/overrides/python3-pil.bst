kind: pyproject

# freedesktop-sdk's components/python3-pil.bst, bumped from 12.3.0 to 13.0.0
# ahead of the junction. It overrides components/python3-pil.bst in the
# freedesktop-sdk junction (see elements/freedesktop-sdk.bst overrides).
#
# Why: GHSA-8g5g-8vmr-9782 (CVE-2026-112403, Critical, published 2026-10-20) is
# a heap buffer overflow in Pillow's JPEG decoder, affecting <= 12.3.0 and fixed
# in 13.0.0. Pillow ships in the image (/usr/lib/python3.14/site-packages/PIL)
# as a runtime dependency of components/fwupd.bst, its only consumer. The
# publish gate (`mise run vuln-scan --fail-on critical`) blocks on it.
#
# This is freedesktop-sdk's own bump, taken verbatim from its autoupdater MR
# for release/26.08 (freedesktop-sdk!35059, open and unapproved as of
# 2026-10-21; master already merged the same change as !35018). The element and
# patches/python3-pil/drop-pybind.patch match that MR's head 90b7b26a byte for
# byte apart from the `freedesktop-sdk.bst:` prefixes and these comments.
#
# Update path: tied to the freedesktop-sdk.bst junction ref, with no separate
# tracking. It is deliberately not in the track-bst-sources.yml matrix:
# `bst source track` would follow Pillow's newest tag past the junction.
# `mise run python3-pil-check` checks this copy for drift against the junction
# and fails once the junction reaches 13.0.0 itself.
#
# Delete this element, the patch, the check task and the overrides entry once
# the junction ships Pillow >= 13.0.0.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst

depends:
- freedesktop-sdk.bst:components/jpeg.bst
- freedesktop-sdk.bst:components/python3-setuptools.bst

sources:
- kind: git_repo
  url: github:python-pillow/Pillow.git
  track: "*.*.*"
  ref: 13.0.0-0-g293218ad059d994baf1777d882911bed6a49704a
- kind: patch
  path: patches/python3-pil/drop-pybind.patch
