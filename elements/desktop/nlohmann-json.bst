kind: cmake

# nlohmann/json: header-only JSON library. Previously provided by
# freedesktop-sdk.bst:components/nlohmann-json.bst; dropped upstream in
# fdsdk 26.08 ("Drop nlohmann-json", freedesktop-sdk-26.08beta.1 changelog)
# — not renamed or moved to _private, genuinely removed. Required by
# noctalia and noctalia-greeter (desktop/noctalia.bst,
# desktop/noctalia-greeter.bst) as a build-time-only header dependency.
# Vendored here with the same source/build config fdsdk carried, so the
# installed headers/cmake-config are equivalent to what noctalia was
# already building against. Same pattern as desktop/stb.bst (another
# header-only lib fdsdk doesn't ship).

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  cmake-local: >-
    -DBUILD_TESTING=OFF
    -DJSON_BuildTests=OFF

sources:
- kind: git_repo
  url: github:nlohmann/json.git
  track: v*
  ref: v3.12.0-0-g55f93686c01528224f448c19128836e7df245f72
