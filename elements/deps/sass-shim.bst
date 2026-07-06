kind: manual

# adw-gtk3's meson.build calls find_program('sass') using Dart Sass CLI
# syntax: `sass --no-source-map INPUT OUTPUT`. Neither freedesktop-sdk nor
# gnome-build-meta vendor Dart Sass — the only sass compiler available is
# sassc (sdk-deps/sassc.bst), a different tool with an incompatible CLI.
# sassc has no --no-source-map flag but already omits source maps unless
# -m is passed, so the flag is safe to drop. This shim exists solely to
# bridge that one call site; it is not a general sass/sassc compat layer.
depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- gnome-build-meta.bst:sdk-deps/sassc.bst

config:
  strip-commands:
  - ":"
  install-commands:
  - |
    install -Dm755 /dev/stdin "%{install-root}%{bindir}/sass" <<'SCRIPT'
    #!/bin/sh
    set -e
    if [ "$1" = "--no-source-map" ]; then
      shift
    fi
    exec sassc "$@"
    SCRIPT
