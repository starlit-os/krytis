# container-sigpolicy: the containers/image signature policy that makes
# `bootc upgrade` refuse a krytis image without the static-key signature
# publish.yml adds (#418). Every other image and transport stays accepted.
#
# Three placement rules, all from docs/skills/signing.md § Where a
# `policy.json` has to live, and why the sketched path is wrong:
#
#   - Vendor files go under %{datadir}/containers (/usr/share): /etc is host
#     state, and the image's skopeo 1.24.1 reads /usr/share/containers/policy.json
#     and /usr/share/containers/registries.d/ (measured, signing.md).
#   - freedesktop-sdk's components/containers-common.bst ships an accept-all
#     /etc/containers/policy.json, and /etc is searched first. The integration
#     command below deletes it, or this policy is silently never read.
#   - "default" is reject, with every transport listed explicitly. bootc's
#     ostree path refuses an insecureAcceptAnything default; listing each
#     transport keeps local ones (containers-storage for installs and
#     `bootc switch --transport containers-storage`, oci, dir...) open.
#
# bootc on the composefs backend consults this policy on every pull with no
# opt-in flag (signing.md § Host enforcement (#418), observed in a VM), so a
# broken policy blocks every host's next upgrade. `mise run sigpolicy-check`
# gates the build on it; `mise run sigpolicy-test` watches a real refusal.
kind: manual

sources:
- kind: local
  path: files/container-sigpolicy
- kind: local
  path: cosign.pub
  directory: key

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
# Owns the /etc/containers/policy.json the integration command removes, so
# wherever this element is integrated that file has been staged.
- freedesktop-sdk.bst:components/containers-common.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - install -Dm644 policy.json "%{install-root}%{datadir}/containers/policy.json"
  - install -Dm644 krytis.yaml "%{install-root}%{datadir}/containers/registries.d/krytis.yaml"
  # The public half of the key in Proton Pass. The repo's cosign.pub is the
  # single source; sigpolicy-check fails if the image's copy drifts from it.
  - install -Dm644 key/cosign.pub "%{install-root}%{datadir}/pki/containers/krytis.pub"

public:
  bst:
    integration-commands:
    # Plain `rm`, not `rm -f`: if containers-common stops shipping the file,
    # the build should say so rather than keep a no-op.
    - rm /etc/containers/policy.json
