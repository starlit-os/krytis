kind: manual

# /etc/xdg/xdg-terminals.list: pins the terminal xdg-terminal-exec runs
# commands in to ghostty, and excludes seance from fallback selection.
#
# Without it, xdg-terminal-exec picks among every TerminalEmulator desktop
# entry by its own fallback ordering -- which on krytis lands on seance, a
# terminal that ignores `-e`. The file header carries the evidence; the
# lesson is in docs/skills/desktop.md § TerminalEmulator is a category, not
# a capability. krytis#1005.
#
# /etc/xdg rather than %{datadir}: xdg-terminal-exec treats the data-dir
# copy as the lowest-priority fallback (desktop/xdg-terminal-exec.bst moves
# upstream's there to %{docdir} for that reason); XDG_CONFIG_DIRS is the
# system-wide config tier, still overridable per user in ~/.config.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - install -Dm644 xdg-terminals.list "%{install-root}%{sysconfdir}/xdg/xdg-terminals.list"
  - '%{install-extra}'

sources:
- kind: local
  path: files/xdg-terminals
