kind: manual

sources:
- kind: tar
  url: github_files:ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.tar.xz
  base-dir: ""
  ref: 01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996
# Local fontconfig conf overrides the simpler upstream version from the tarball.
# Provides <alias> rules that make Symbols Nerd Font a fallback for all
# common monospace families so glyphs render without per-user configuration.
- kind: local
  path: files/fontconfig

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  strip-commands:
  - ":"
  install-commands:
  - |
    install -Dm644 SymbolsNerdFont-Regular.ttf \
      "%{install-root}%{datadir}/fonts/nerd-fonts-symbols/SymbolsNerdFont-Regular.ttf"
  - |
    install -Dm644 SymbolsNerdFontMono-Regular.ttf \
      "%{install-root}%{datadir}/fonts/nerd-fonts-symbols/SymbolsNerdFontMono-Regular.ttf"
  - |
    install -Dm644 10-nerd-font-symbols.conf \
      "%{install-root}%{datadir}/fontconfig/conf.avail/10-nerd-font-symbols.conf"
  - |
    mkdir -p "%{install-root}%{sysconfdir}/fonts/conf.d"
    ln -s "%{datadir}/fontconfig/conf.avail/10-nerd-font-symbols.conf" \
      "%{install-root}%{sysconfdir}/fonts/conf.d/10-nerd-font-symbols.conf"
  - "%{install-extra}"
