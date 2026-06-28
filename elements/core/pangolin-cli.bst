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
      url: github_files:fosrl/cli/releases/download/0.11.0/pangolin-cli_linux_amd64
      ref: c1833a2234f91f9e34f4342d9c18a227ae0d3df6c89f5bf7d926a3cded69f872
  - arch == "aarch64":
      url: github_files:fosrl/cli/releases/download/0.11.0/pangolin-cli_linux_arm64
      ref: c4d97697e27fed030bbcff235fccafdf53a935832faae3a2324bce33ab65bbfe

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - install -Dm755 pangolin-cli "%{install-root}%{bindir}/pangolin"
