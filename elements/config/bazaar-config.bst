# bazaar-config: Bazaar's Curated page, its blocklist, and the boot-time
# /etc access permission that lets the flatpak read both. Closes #245.
#
# Bazaar itself is not a BST element. It is a --system flatpak installed by
# files/flatpak-preinstall/flatpak-preinstall.sh (#66). This element is config
# only, kept apart from config/flatpak-preinstall.bst per docs/skills/bst.md
# § Bazaar curated config and the host-etc permission.
#
# /etc, not /usr/lib: the path isn't a krytis choice. The Flathub build of
# Bazaar compiles in -Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml,
# and /run/host/etc is the host's /etc seen from inside the sandbox.
#
# Ported from projectbluefin/common system_files/bluefin/etc/bazaar/, minus
# the hooks (they steer users to ujust/Homebrew, which krytis doesn't have),
# minus the bazaar.service user unit (files/niri/startup.kdl and
# files/umbriel/config.toml already spawn bazaar-daemon, #763), and minus the
# JXL banner art (Bluefin branding; files/bazaar/curated.yaml uses gradients).
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    for f in bazaar.yaml curated.yaml blocklist.yaml; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/bazaar/$f"
    done

  - |
    install -Dm755 bazaar-host-etc.sh \
      "%{install-root}/usr/libexec/krytis/bazaar-host-etc.sh"

    install -Dm644 bazaar-host-etc.service \
      "%{install-root}%{indep-libdir}/systemd/system/bazaar-host-etc.service"

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/73-krytis-bazaar-host-etc.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/73-krytis-bazaar-host-etc.preset" <<'EOF'
    enable bazaar-host-etc.service
    EOF

sources:
- kind: local
  path: files/bazaar
