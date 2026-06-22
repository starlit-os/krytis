kind: manual

sources:
- kind: tar
  url: github_files:ryanoasis/nerd-fonts/releases/download/v3.4.0/NerdFontsSymbolsOnly.tar.xz
  base-dir: ""
  ref: 7f8c090da3b0eaa7108646bf34cbbb6ed13d5358a72460522108b06c7ecd716a

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
  - "%{install-extra}"
