# subuid-provision: assigns a subuid/subgid range to every local
# regular-login account at boot, via a oneshot systemd service.
#
# Neither systemd-sysusers nor systemd-homed populate /etc/subuid/subgid
# the way `useradd` does -- confirmed open upstream gap (systemd/systemd#21952,
# systemd/systemd#29297, containers/podman#20040, containers/podman#24828),
# not a krytis oversight. Without a range, rootless podman fails for that
# account with "potentially insufficient UIDs or GIDs available in user
# namespace" -- breaking per-user podman-restart.service and
# podman-auto-update.service on every boot for a homed user, plus any manual
# rootless podman use (mise run runner/build, renovate-check). Investigated
# 2026-09-08 after a live report of the login keyring appearing intermittently
# locked traced instead to this. See docs/skills/pam.md and
# docs/skills/ci-runner.md.
#
# This is a config-only element with no binaries to strip. The default
# buildsystem-make strip-commands call freedesktop-sdk-stripper, which is
# not in runtime-minimal. Override strip-commands with a no-op.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
# usermod (shadow.bst) and getent (glibc, always present) are what the
# script shells out to.
- freedesktop-sdk.bst:components/shadow.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 subuid-provision.sh \
      "%{install-root}/usr/libexec/krytis/subuid-provision.sh"

    install -Dm644 krytis-subuid-provision.service \
      "%{install-root}%{indep-libdir}/systemd/system/krytis-subuid-provision.service"

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-subuid-provision.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-subuid-provision.preset" <<'EOF'
    enable krytis-subuid-provision.service
    EOF

sources:
- kind: local
  path: files/subuid-provision
