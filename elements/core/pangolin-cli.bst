kind: manual

# Prebuilt pangolin-cli binary (https://github.com/fosrl/cli).
# Pangolin is a reverse proxy / VPN client (newt-compatible).
# Ships binary only — no systemd service or preset. Users configure and
# run pangolin manually or via their own units with /etc/pangolin/credentials.
#
# Credentials file format (/etc/pangolin/credentials — not in OCI image):
#   PANGOLIN_CLIENT_ID=<id>
#   PANGOLIN_CLIENT_SECRET=<secret>
#   PANGOLIN_ENDPOINT=https://<host>
#
# Update path: kind: remote, bst source track is a no-op.
# Use: mise run pangolin-update / track-pangolin CI job.
# Closes #190.

sources:
- kind: remote
  filename: pangolin-cli
  (?):
  - arch == "x86_64":
      url: github_files:fosrl/cli/releases/download/0.12.0/pangolin-cli_linux_amd64
      ref: 650e6d2521b54fcbb0668b16476f06be7bf6c0d99d73ad9c247f29489c95d67f
  - arch == "aarch64":
      url: github_files:fosrl/cli/releases/download/0.12.0/pangolin-cli_linux_arm64
      ref: a9934b4cba0335a5d67d0df5bbeecb073153be9947bc2271b402b8dd671db7e2

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - install -Dm755 pangolin-cli "%{install-root}%{bindir}/pangolin"
