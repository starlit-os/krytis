kind: manual

# Prebuilt pangolin-cli binary (https://github.com/fosrl/cli).
# Pangolin is a reverse proxy / VPN client (newt-compatible).
# Ships binary only — no systemd service or preset. Users configure via
# `pangolin auth login` (interactive browser device-code flow) or the
# `--id`/`--secret`/`--endpoint` flags on `pangolin up`. No env-var or
# credentials-file mechanism exists upstream (checked fosrl/cli source).
#
# Update path: kind: remote, bst source track is a no-op.
# Use: mise run pangolin-update / track-pangolin CI job.
# Closes #190.
#
# `pangolin up` does NOT use file capabilities. cmd/up/client/client.go
# unconditionally re-execs itself via `sudo sh -c "<dynamic shell
# command>"` whenever running non-root (fosrl/cli 0.12.0, client.go
# ~L375-386) — this is not conditional on missing capabilities, so
# `setcap cap_net_admin` on the binary (tried in an earlier revision of
# this file, see git history) has no effect: the client never checks for
# it. Root elevation is baked into the client every session; there is no
# flag to skip it.
#
# Passwordless sudo below is scoped to a dedicated `pangolin` group (see
# sysusers.d below — group is created empty; add users manually, e.g.
# `usermod -aG pangolin <user>`) and to the exact `sh -c` string prefix
# pangolin-cli currently emits, not a bare `sh -c *` wildcard, to avoid
# granting unrestricted root shell access to group members.
#
# The sudoers.d file installs at 0644, not the conventional 0440:
# BuildStream's artifact storage only tracks two regular-file modes
# (644/755, like a git tree object) — `install -Dm440` is silently
# clamped to 0644 by the time it lands in the image (verified via
# `bst artifact checkout --tar`). Confirmed against sudo-rs's own test
# suite (trifectatechfoundation/sudo-rs, includedir.rs) that it only
# rejects world-*writable* sudoers.d entries, not world-readable ones —
# 0644 still loads and is honored. Root-owned, not group/other-writable,
# so this is a minor hardening gap (policy text is world-readable) not a
# functional break.
#
# FRAGILE: the sudoers glob below matches a literal prefix of fosrl/cli's
# internal shell-wrapper string (see client.go buildShellCmd logic:
# `export PANGOLIN_SUBPROCESS=1 && [export PANGOLIN_CREDENTIALS_FROM_KEYRING=1 && ]nohup "<bindir>/pangolin"...`).
# If a future pangolin-cli release changes this string (env var name,
# ordering, or drops the wrapper entirely), the sudoers rule silently
# stops matching and `pangolin up` falls back to an interactive password
# prompt — it will NOT error loudly. `bst source track` is a no-op on
# this `kind: remote` source, so version bumps happen via
# `mise run pangolin-update` and won't surface this drift in review;
# re-check the prefix against upstream client.go after every version
# bump of this element.

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
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/sysusers.d/pangolin-cli.conf" <<'EOF'
    g pangolin - -
    EOF
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}/etc/sudoers.d/pangolin-cli" <<'EOF'
    %pangolin ALL=(root) NOPASSWD: /usr/bin/sh -c "export PANGOLIN_SUBPROCESS=1 && export PANGOLIN_CREDENTIALS_FROM_KEYRING=1 && nohup \"%{bindir}/pangolin\"*"
    %pangolin ALL=(root) NOPASSWD: /usr/bin/sh -c "export PANGOLIN_SUBPROCESS=1 && nohup \"%{bindir}/pangolin\"*"
    EOF
