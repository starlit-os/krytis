kind: manual

# Adds /usr/lib/limux to the dynamic linker search path so limux-host can
# find its bundled libghostty.so.
#
# Both limux binaries are built with RUNPATH=/usr/local/lib/limux (upstream's
# install.sh default prefix), but bootc's /usr/lib/tmpfiles.d/10-bootc.conf
# makes /usr/local a symlink to /var/usrlocal — runtime state, empty on every
# fresh boot — so the baked RUNPATH can never resolve in a krytis image.
# desktop/limux.bst installs the library to %{indep-libdir}/limux instead, and
# this entry is what makes it findable. Kept out of the shared %{libdir} so a
# vendored 29 MB libghostty.so is not on every binary's default search path.
#
# oci/krytis/image.bst bakes the cache at assembly time, so nothing runs at
# boot. NOTE: that step only picks up /etc/ld.so.conf.d at all once the
# ldconfig fix on branch fix/ldconfig-ld-so-conf-d-cache lands — see
# docs/skills/bst.md § ldconfig -r. Without it this file is inert and
# limux-host fails with "libghostty.so: cannot open shared object file".
# Closes #550.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm644 /dev/stdin \
        "%{install-root}/etc/ld.so.conf.d/limux.conf" <<'EOF'
    %{indep-libdir}/limux
    EOF
  - "%{install-extra}"
