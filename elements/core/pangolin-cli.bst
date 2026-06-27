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
      url: github_files:fosrl/cli/releases/download/0.10.2/pangolin-cli_linux_amd64
      ref: 9f97e4922ee24e1ae4d7dffbcd537e701abc8219826b419ab232f078ce3fa1af
  - arch == "aarch64":
      url: github_files:fosrl/cli/releases/download/0.10.2/pangolin-cli_linux_arm64
      ref: 632ad698bc973fa6a2cfa38e95f380fa6da596bab9f4b04029cfdfadd6a1ce71

- kind: local
  path: files/pangolin-cli

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - install -Dm755 pangolin-cli "%{install-root}%{bindir}/pangolin"
