kind: make

public:
  bst:
    overlap-whitelist:
    - /usr/bin/sudo
    - /usr/bin/sudoedit
    - /usr/lib/debug/usr/bin/sudo.debug
  initial-script:
    script: |
      #!/bin/bash
      chmod 4755 "${1}/usr/bin/sudo"

build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/linux-pam.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/linux-pam.bst

config:
  build-commands:
  - cargo build --release

  install-commands:
  - install -Dm755 target/release/sudo "%{install-root}/usr/bin/sudo"
  - ln -sr "%{install-root}/usr/bin/sudo" "%{install-root}/usr/bin/sudoedit"
  # Install /etc/sudoers 0644, not 0440: with the two-step write the mode lands
  # before `cat >` opens the file, and the build sandbox is not root, so 0440
  # gives `Permission denied` (broke publish run 33872670405). Chmod'ing after
  # the write would be theatre — BST's CAS keeps only the exec bit, so every
  # artifact file arrives 0644/0755 regardless (live image: /etc/sudoers 0644).
  # A stricter mode has to be applied from `initial-script`, like the setuid
  # bit above. sudo-rs only requires sudoers not be group/world writable.
  - |
    install -Dm644 /dev/null \
      "%{install-root}/etc/sudoers"
    cat > "%{install-root}/etc/sudoers" <<'EOF'
    #includedir /etc/sudoers.d
    EOF
  - |
    install -Dm644 /dev/null \
      "%{install-root}/etc/pam.d/sudo"
    cat > "%{install-root}/etc/pam.d/sudo" <<'EOF'
    auth            sufficient      pam_rootok.so
    auth            include         system-auth
    account         include         system-auth
    password        include         system-auth
    session         include         system-auth
    EOF

sources:
- kind: git_repo
  url: github:trifectatechfoundation/sudo-rs.git
  track: 'v[0-9]*.[0-9]*.[0-9]*'
  ref: v0.2.15-0-ge4cfa9cf7b71e287dd5046633c0f5276072d147d
- kind: cargo2
  url: crates:crates
  ref:
  - kind: registry
    name: glob
    version: 0.3.4
    sha: e4eba85ea1d0a966a983acd07deee566e67395d2d96b6fb39e62b5a833f1eb0b
  - kind: registry
    name: libc
    version: 0.2.189
    sha: 3eaf3ede3fee6db1a4c2ee091bf8a8b4dccdc6d17f656fb07896ee72867612f2
