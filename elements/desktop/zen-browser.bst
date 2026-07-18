kind: manual

# Zen Browser: Firefox-based browser focused on privacy/customization (https://zen-browser.app).
# Pre-built binary release — upstream publishes x86_64 and aarch64 tarballs (Firefox-style
# unpacked binary tree: no .desktop entry, no icon-theme install, no update-policy file —
# all three are hand-authored below). RPATH is $ORIGIN-relative like zed.bst, so the whole
# tree is installed to /usr/lib/zen-browser/ and /usr/bin/zen symlinks to the launcher inside.
# DisableAppUpdate is set because Zen's built-in updater can't write into a read-only bootc
# image — updates flow through the mise-managed pin instead.
# Update path: mise run zen-browser-update / track-zen-browser CI job.
# Closes #314.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/gtk3.bst

variables:
  version: "1.21.8b"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -d "%{install-root}/usr/lib/zen-browser"
    cp -a * "%{install-root}/usr/lib/zen-browser/"

    install -d "%{install-root}/usr/bin"
    ln -s /usr/lib/zen-browser/zen "%{install-root}/usr/bin/zen"

    for size in 16 32 48 64 128; do
      install -d "%{install-root}/usr/share/icons/hicolor/${size}x${size}/apps"
      ln -s "/usr/lib/zen-browser/browser/chrome/icons/default/default${size}.png" \
        "%{install-root}/usr/share/icons/hicolor/${size}x${size}/apps/zen-browser.png"
    done

    install -Dm644 /dev/stdin "%{install-root}/usr/share/applications/zen-browser.desktop" <<'EOF'
    [Desktop Entry]
    Name=Zen Browser
    GenericName=Web Browser
    Comment=A fast, private, and secure web browser built to improve your day-to-day experience.
    Exec=zen %u
    Icon=zen-browser
    Terminal=false
    Type=Application
    StartupNotify=true
    StartupWMClass=zen
    Categories=Network;WebBrowser;
    MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
    EOF

    install -Dm644 /dev/stdin "%{install-root}/usr/lib/zen-browser/distribution/policies.json" <<'EOF'
    {
      "policies": {
        "DisableAppUpdate": true
      }
    }
    EOF

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:zen-browser/desktop/releases/download/1.21.8b/zen.linux-x86_64.tar.xz
      ref: 05a36657e4c9dbe700e54a2e3941f7af4656abbe330690aa74d8cf793af396f4
  - arch == "aarch64":
      url: github_files:zen-browser/desktop/releases/download/1.21.8b/zen.linux-aarch64.tar.xz
      ref: 0586ff279d7a1f93207fdb195c5586ef0d6813bd4f4318badcd0984adc39db39
