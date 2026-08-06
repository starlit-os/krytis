# Enables kmscon on VT2-4 only — never the bare kmsconvt@ template. The bare
# template's [Install] section carries `DefaultInstance=tty1` and
# `Alias=autovt@.service`, which would make systemd-logind spawn it in place of
# tty1's getty — greetd owns VT1 (greetd-config.bst `vt = 1`) and must not be
# preempted this way. Enabling only the tty2/tty3/tty4 instances keeps each
# unit's `Conflicts=getty@%i.service` scoped to that VT, leaving VT1 to greetd.
#
# The instances are enabled with static getty.target.wants symlinks, NOT with
# `enable kmsconvt@ttyN.service` preset lines. `systemctl preset-all` iterates
# unit *files*, so it never acts on a template instance named only in a preset
# file — those lines are silently inert. Worse, with no rule then matching the
# bare template, preset-all fell through to its default `enable` policy and
# enabled `DefaultInstance=tty1`: the exact VT1 preemption this element exists to
# prevent, observed starting kmscon on greetd's VT on every boot. The
# `disable kmsconvt@.service` rule below closes that fall-through.
#
# Fixes #503. See docs/skills/bst.md § Enabling one instance of a templated
# getty-replacement unit, never the bare template.

kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- desktop/kmscon.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    # Static "vendor enabled" symlinks: getty.target Wants each instance. They
    # live under %{indep-libdir}, so `systemctl preset-all` — which only writes
    # to /etc — can neither create nor remove them. Note `systemctl is-enabled`
    # reports these as `static`, not `enabled`; that is the expected label for a
    # unit enabled from the vendor unit path, and the dependency is still real
    # (systemd's own sysinit.target.wants/systemd-firstboot.service works the
    # same way).
    wants_dir="%{install-root}%{indep-libdir}/systemd/system/getty.target.wants"
    mkdir -p "${wants_dir}"
    for vt in tty2 tty3 tty4; do
        ln -s "../kmsconvt@.service" "${wants_dir}/kmsconvt@${vt}.service"
    done

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/80-kmscon.preset" <<'EOF'
    # Deliberately NOT `enable kmsconvt@tty2.service` etc: preset-all cannot act
    # on template instances, so such lines are inert. The instances are enabled
    # by static getty.target.wants symlinks instead. This rule exists solely to
    # stop the bare template falling through to preset-all's default `enable`
    # policy, which enables DefaultInstance=tty1 and preempts greetd on VT1.
    disable kmsconvt@.service
    EOF

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/logind.conf.d/10-krytis-vts.conf" <<'EOF'
    # krytis: keep logind's on-demand VT range aligned with the console layout.
    #
    #   vt1     greetd            (greetd-config.bst `vt = 1`)
    #   vt2-4   kmscon            (the getty.target.wants symlinks above)
    #   vt5     first-boot wizard (krytis-firstboot.service, first boot only)
    #   vt6     logind's ReserveVT — left at its default on purpose
    #
    # NAutoVTs defaults to 6, so once the wizard releases tty5, Ctrl+Alt+F5
    # spawns a plain getty on the wizard's own VT. Capping the range at 4 keeps
    # the on-demand gettys inside kmscon's range: the only consoles reachable
    # are kmscon's, plus the reserved rescue VT.
    #
    # ReserveVT is deliberately NOT set to 0. logind spawns a getty on the
    # reserved VT unconditionally, skipping the vt_is_busy() check
    # (systemd src/login/logind-core.c, manager_spawn_autovt()); that same check
    # order is why VT6 still gets its getty even though 6 > NAutoVTs. It is the
    # only in-band way into a box whose greeter has wedged — root is locked
    # (root:!unprovisioned) and sshd ships disabled by preset — and it costs
    # nothing while unused, since the unit is not loaded until someone switches
    # to VT6.
    [Login]
    NAutoVTs=4
    EOF
  - '%{install-extra}'
