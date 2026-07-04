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
# it.
#
# client.go's re-exec is itself conditional on `os.Geteuid() != 0`
# (~L375: "If already running as root, skip sudo wrapper"). So instead of
# granting sudo on the client's internal `sh -c "<dynamic string>"` re-exec
# (which we can't scope tightly — sudo-rs's Cmnd Args matcher compares the
# real argv array element-for-element with NO glob/substring matching
# inside a single argv element; only a bare trailing `*` or `""` token is
# supported, so a prefix-anchored match on part of that string is not
# expressible at all, not just fragile), we grant sudo on the *outer*
# `pangolin up` invocation itself. Callers must run `sudo pangolin up
# [args...]` (not bare `pangolin up`) to hit this rule; once euid is
# already 0, client.go's own check skips its internal sudo re-exec
# entirely — no nested sudo prompt, and no dependency on client.go's
# internal string format. This also fixes headless/GUI callers (e.g. a
# noctalia plugin invoking this with no controlling TTY): client.go's
# internal sudo call wires `procCmd.Stdin = os.Stdin` /
# `procCmd.Stderr = os.Stderr` for interactive password entry, which
# can't work without a TTY. Pre-elevating via our own NOPASSWD rule avoids
# that path being reached at all.
#
# Passwordless sudo below is scoped to a dedicated `pangolin` group (see
# sysusers.d below — group is created empty; add users manually, e.g.
# `usermod -aG pangolin <user>`) and to the `pangolin up` subcommand only
# (`Args::Prefix` on the literal arg "up" — sudo-rs's supported wildcard
# form, matching "up" plus any further args). This is a stable, public CLI
# surface — unlike the internal shell-wrapper string, renaming/removing
# the `up` subcommand would be a documented breaking change upstream, not
# silent drift.
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
# Filename is `zz-pangolin-cli`, NOT `pangolin-cli`: sudo's `#includedir`
# reads /etc/sudoers.d in filename sort order, and sudoers semantics are
# last-matching-rule-wins. base-system.bst depends on freedesktop-sdk's
# vm/config/sudo.bst, which installs /etc/sudoers.d/wheel
# (`%wheel ALL=(ALL) ALL`, password required). Any user in both `wheel`
# and `pangolin` groups (the common case — see docs/skills/bst.md) would
# have this rule silently overridden: "pangolin-cli" sorts before "wheel"
# alphabetically, so wheel's general ALL rule is read *after* ours and
# wins for the `pangolin up` command too (ALL matches everything). Prefixing
# with `zz-` forces our narrower NOPASSWD carve-out to sort and load last.
# Verified live: `sudo -n pangolin up` failed with "interactive
# authentication is required" under the old filename despite `sudo -l`
# correctly listing the NOPASSWD rule (sudo -l lists all matching entries,
# not just the effective one) — renaming to `zz-pangolin-cli` fixed it.

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
      "%{install-root}/etc/sudoers.d/zz-pangolin-cli" <<'EOF'
    %pangolin ALL=(root) NOPASSWD: %{bindir}/pangolin up *
    EOF
