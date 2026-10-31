kind: manual

# Tailscale client and daemon (https://tailscale.com), from upstream's own
# prebuilt static tarballs. Ported from dakota's elements/bluefin/tailscale.bst
# with three deliberate differences, all from #1384:
#
# - Shipped DISABLED. An idle, never-logged-in tailscaled binds UDP 41641 on
#   every address, creates tailscale0, adds policy-routing rules and uploads
#   logs to log.tailscale.com (measured on krytis, #1384 § Idle daemon check).
#   The preset below is an explicit `disable`: without a rule the image's
#   global preset step enables every unit with an [Install] section
#   (docs/skills/bst.md § The fall-through applies to the package's other
#   units too, not just the template). Users opt in with `mise tailscale:setup`
#   (config/tailscale-setup.bst), which runs `systemctl enable --now`.
# - TS_DEBUG_FIREWALL_MODE=nftables. /usr/bin/iptables on krytis is the
#   legacy backend (xtables-legacy-multi) while netavark uses nftables;
#   tailscaled otherwise logs `router: default choosing iptables` and programs
#   legacy tables.
# - No operator setup at all in this element. The tracked element only ever
#   changes through tailscale-update's url:/ref: edits.
#
# Sources: pkgs.tailscale.com, not GitHub (its releases carry no assets).
# Update path: kind: tar, so `bst source track` is a no-op. Use
# `mise run tailscale-update` / the track-tailscale CI job, which verifies each
# tarball's .sha256 and its distsign .sig against the root keys pinned in
# mise/lib/tailscale-distsign-roots.pem. Never hold below 1.96.4: 1.94.2
# silently dropped WireGuard data over IPv6 link-local (dakota 865e340).
#
# The kernel must have CONFIG_IPV6_MULTIPLE_TABLES, or tailscaled logs
# "kernel does not support IPv6 policy routing" and IPv6 LAN paths break after
# suspend (dakota 2f000f3). The CachyOS kernel has it (=y), but krytis does not
# own that config (core/linux-cachyos.bst is a prebuilt package).
#
# Closes #1384.

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: tailscale_pkgs:tailscale_1.104.4_amd64.tgz
      ref: 624ea093d47d62cf56f17b8332d74b8decda4a1faa610ebc60a1de334b2b3dc9
  - arch == "aarch64":
      url: tailscale_pkgs:tailscale_1.104.4_arm64.tgz
      ref: a1c249ce6bdebef62e1ae3b997595555bce2ae4709bf95a718e9ca7a129dad7e

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
# Neither is in runtime-gnu (docs/skills/bst.md § Prebuilt Binary Elements).
- freedesktop-sdk.bst:components/grep.bst
- freedesktop-sdk.bst:components/sed.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - install -Dm755 -t "%{install-root}%{bindir}" tailscale tailscaled

  # Upstream's unit assumes /usr/sbin and /etc/default/tailscaled. krytis is
  # merged-usr with %{bindir}=/usr/bin and ships no /etc/default, and the
  # removed file is what supplied PORT and FLAGS: without them ExecStart's
  # `--port=${PORT} $FLAGS` expands empty (dakota 4940fa6).
  - |
    unit="%{install-root}%{indep-libdir}/systemd/system/tailscaled.service"
    install -Dm644 /dev/null "$unit"
    sed -e 's|/usr/sbin/tailscaled|%{bindir}/tailscaled|g' \
        -e '/^EnvironmentFile=/d' \
        -e '/^\[Service\]$/a Environment=PORT=41641' \
        -e '/^\[Service\]$/a Environment=FLAGS=' \
        -e '/^\[Service\]$/a Environment=TS_DEBUG_FIREWALL_MODE=nftables' \
        systemd/tailscaled.service > "$unit"

  - |
    install -Dm644 /dev/null "%{install-root}%{indep-libdir}/systemd/system-preset/80-tailscale.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/80-tailscale.preset" <<'EOF'
    disable tailscaled.service
    EOF

  # Fail the build if upstream reshapes the unit so the rewrite above no longer
  # applies, instead of shipping a unit that cannot start.
  - |
    unit="%{install-root}%{indep-libdir}/systemd/system/tailscaled.service"
    expect() {
      n=$(grep -c -F -- "$2" "$unit" || true)
      if [ "$n" != "$1" ]; then
        echo "tailscaled.service: expected $1 line(s) containing '$2', found $n" >&2
        cat "$unit" >&2
        exit 1
      fi
    }
    expect 0 /usr/sbin
    expect 0 EnvironmentFile=
    expect 2 "%{bindir}/tailscaled "
    expect 1 'Environment=PORT=41641'
    expect 1 'Environment=FLAGS='
    expect 1 'Environment=TS_DEBUG_FIREWALL_MODE=nftables'
    expect 1 'ExecStart=%{bindir}/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${PORT} $FLAGS'

  - '%{install-extra}'
