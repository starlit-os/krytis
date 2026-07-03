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
#
# cap_net_admin file capability lets wheel-group users bring up the
# pangolin tun interface without root/sudo (polkit doesn't apply here —
# tun creation is a raw CAP_NET_ADMIN syscall check, not a D-Bus action).
#
# setcap CANNOT run in install-commands: BuildStream's build sandbox
# denies CAP_SETFCAP even under fakeroot ("unable to set CAP_SETFCAP
# effective capability: Operation not permitted"), confirmed via
# `bst build`. The security.capability xattr is applied instead by a
# oneshot systemd unit at boot (real root, unsandboxed). This means the
# cap is briefly absent immediately post-boot until the unit runs.

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

depends:
- freedesktop-sdk.bst:components/libcap.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - install -Dm755 pangolin-cli "%{install-root}%{bindir}/pangolin"
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system/pangolin-setcap.service" <<'EOF'
    [Unit]
    Description=Grant pangolin cap_net_admin for non-root tun access
    ConditionFileNotEmpty=%{bindir}/pangolin
    ConditionCapability=CAP_SETFCAP

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=%{sbindir}/setcap cap_net_admin+ep %{bindir}/pangolin

    [Install]
    WantedBy=multi-user.target
    EOF
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/80-pangolin-setcap.preset" <<'EOF'
    enable pangolin-setcap.service
    EOF
