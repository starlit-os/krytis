# Default to seance, drop warp (#1005)

Top-level issue, no parent.

## Goal

Two coupled changes to krytis's terminal lineup:

1. **`seance` becomes the terminal `Mod+Return` opens**, in both `files/niri/binds.kdl`
   and `files/umbriel/binds.toml`.
2. **`warp` leaves the image entirely** — element, stack entry, update task, tracker job,
   URL alias, manifest row.

Coupled because dropping warp changes what `xdg-terminal-exec` auto-selects, and the
entry it falls through to is `com.seance.app.desktop` — a terminal that silently ignores
`-e`.

## Verified facts (live krytis box, 2026-09-29)

All of the following were run on a booted krytis system, not inferred from the tree.

- **Three `TerminalEmulator` desktop entries exist today.**
  `grep -rl TerminalEmulator /usr/share/applications/` →
  `com.mitchellh.ghostty.desktop`, `com.seance.app.desktop`, `dev.warp.Warp.desktop`.

- **`xdg-terminal-exec` resolves to warp today, and the command it builds is broken.**

  ```
  $ xdg-terminal-exec --print-id --print-cmd -- echo hi
  dev.warp.Warp.desktop
  warp-terminal
  -e
  echo
  hi
  ```

  Warp's entry is `Exec=warp-terminal %U` with no `X-TerminalArgExec`, so
  `xdg-terminal-exec` synthesises the default `-e`, which warp does not implement.
  "Open a terminal here" is already broken on `main`.

- **Removing warp promotes seance, which is broken for the same role.** Verified with an
  exclusion list (`-dev.warp.Warp.desktop` in `$XDG_CONFIG_HOME/xdg-terminals.list`):

  ```
  $ XDG_CONFIG_HOME=/tmp/xtetest xdg-terminal-exec --print-id --print-cmd -- echo hi
  com.seance.app.desktop
  seance
  -e
  echo
  hi
  ```

  Not ghostty — ghostty loses the fallback ordering despite sorting earlier
  alphabetically. Do not assume it wins by default.

- **seance cannot execute a command.** `seance --help` documents exactly two forms:
  `seance` (GUI) and `seance ctl <cmd>` (control a *running* instance over its socket).
  `timeout 5 seance -e echo hi` exits 0, prints nothing, opens no window, and runs
  nothing. Its desktop entry declares `Categories=System;TerminalEmulator;` with no
  `X-TerminalArg*` keys, so every spec-compliant consumer hands it `-e` and gets a
  silent no-op.

- **Nothing pins the selection.** `/etc/xdg/xdg-terminals.list` does not exist, and
  neither does `~/.config/xdg-terminals.list`. `elements/desktop/xdg-terminal-exec.bst`
  deliberately relocates upstream's shipped list to `%{docdir}` (it is the
  lowest-priority fallback, not configuration — see `docs/skills/zirconium-hawaii.md`
  § xdg-terminal-exec Install Quirk).

- **`/etc/xdg` is an honoured search path.** Verified end to end:

  ```
  $ XDG_CONFIG_DIRS=/tmp/xtecd:/etc/xdg xdg-terminal-exec --print-id -- echo hi
  com.mitchellh.ghostty.desktop
  ```

- **ghostty accepts the generated command.** With an explicit list naming it:
  `/usr/bin/ghostty --gtk-single-instance=true -e echo hi`. Its entry carries the full
  `X-TerminalArgExec` / `X-TerminalArgDir` / `X-TerminalArgTitle` set.

- **noctalia is already on ghostty and needs no config.** `src/system/terminal_launch.cpp`
  (noctalia-dev/noctalia) tries `$TERMINAL` first, then a hardcoded list —
  `x-terminal-emulator`, **`ghostty`**, `kitty`, `alacritty`, `wezterm`, `foot`,
  `konsole`, `gnome-terminal`, `kgx`, `ptyxis`, `xterm` — and appends `-e sh -lc <cmd>`
  (`--` only for gnome-terminal/kgx/ptyxis). `x-terminal-emulator` is not in krytis, so
  ghostty wins. No `TERMINAL` is exported anywhere in this repo (grepped), and
  `files/noctalia-skel/settings.toml` sets no terminal key. **Do not seed
  `TERMINAL=seance`** — it would break every `Terminal=true` launcher entry and
  `noctalia.runInTerminal()`.

  (`~/.config/noctalia/settings.json` on this box still carries
  `"terminalCommand": "alacritty -e"`, but that file is stale — mtime 2026-08-19,
  predating noctalia's move to `~/.local/state/noctalia/settings.toml`. It is not read.)

## Decision

Split the two roles instead of conflating them under "default terminal":

| Role | Binary | Wiring |
| --- | --- | --- |
| Terminal the human opens | `seance` | `Mod+Return`, niri + umbriel |
| Terminal that *executes a command* | `ghostty` | `/etc/xdg/xdg-terminals.list`, noctalia's own discovery |

ghostty stays in the image for that reason, and keeps its `draw-border-with-background
false` + 1/3-column window rules.

**No seance window rule is added.** seance is itself a scrolling multiplexer with an
internal pane strip; the 0.33333 rules exist to make a plain terminal narrow, which is the
wrong shape here. The layout default (`default-column-width { proportion 0.66667; }`,
`default_extent_fraction = 0.66667`) is correct — leave it, and say so in the config
comment so a future reader does not "fix" the omission.

---

## Phase 1 — seance as the `Mod+Return` terminal

- [x] **Step 1: niri bind**

  `files/niri/binds.kdl:12`:

  ```kdl
  Mod+Return hotkey-overlay-title="Open a Terminal: seance" { spawn "seance"; }
  ```

  The hotkey-overlay title is user-visible (`Mod+Shift+7`) — update it, do not leave it
  reading "ghostty".

- [x] **Step 2: umbriel bind**

  `files/umbriel/binds.toml:26-29`. Replace both the action and the port comment, which
  currently cites niri's ghostty line:

  ```toml
  # niri: `Mod+Return hotkey-overlay-title=... { spawn "seance"; }`. Overrides
  # upstream's spawn:kitty. Only `action` is set so upstream's own repeat = false
  # merges through key-by-key.
  "Mod+Return" = { action = "spawn:seance" }
  ```

  Keep the `{ action = ... }` table form: the inline-table merge is what preserves
  upstream's `repeat = false` (documented at the head of that file, krytis#982).

- [x] **Step 3: pin the command-executing terminal**

  New `files/xdg-terminals/xdg-terminals.list`:

  ```
  # Which terminal xdg-terminal-exec hands a command to (`-e <cmd>`).
  #
  # NOT the same question as "which terminal does Mod+Return open" — that is
  # seance (files/niri/binds.kdl, files/umbriel/binds.toml). seance has no
  # command-execution CLI: `seance -e <cmd>` exits 0 and runs nothing. Its
  # desktop entry still declares Categories=...TerminalEmulator;, so without
  # this file xdg-terminal-exec picks it and every "open in terminal" action
  # silently does nothing. Verified on krytis: see krytis#1005.
  com.mitchellh.ghostty.desktop
  -com.seance.app.desktop
  ```

  New `elements/config/xdg-terminals-list.bst`, following `config/gtk-settings.bst`'s
  shape (`kind: manual`, `strip-commands: [':']`, `runtime-gnu` dep, `%{install-extra}`
  last) but with a `kind: local` source over `files/xdg-terminals`, as
  `config/noctalia-skel.bst` does:

  ```yaml
  install-commands:
  - install -Dm644 xdg-terminals.list "%{install-root}%{sysconfdir}/xdg/xdg-terminals.list"
  - "%{install-extra}"
  ```

  Wire it into `elements/stacks/desktop.bst` directly after
  `desktop/xdg-terminal-exec.bst` (L176), inside the existing `── XDG utilities ──`
  block.

- [x] **Step 4: update path gate**

  Not applicable — `kind: local`, no upstream source to track, so neither
  `track-bst-sources.yml` matrix option applies. State this explicitly in the PR so the
  gate is visibly considered rather than skipped.

## Phase 2 — drop warp

- [x] **Step 1: element and stack entry**

  - `git rm elements/desktop/warp.bst`
  - `elements/stacks/desktop-apps.bst:19-21` — delete the whole `── Terminal ──` block
    including the header comment; warp is its only member, and terminals belong to
    `stacks/desktop.bst`'s Terminal section (ghostty, seance), not to the app stack.

- [x] **Step 2: update task and tracker job**

  - `git rm mise/tasks/warp-update`
  - `.github/workflows/track-bst-sources.yml` — remove `- warp` from the
    `workflow_dispatch` `group` choice list (L61) **and** the entire `track-warp:` job,
    lines 2256-2350 inclusive (next job `track-qemu:` starts at 2352). Leave exactly one
    blank line between the preceding job and `track-qemu:`.

- [x] **Step 3: alias**

  `include/aliases.yml:22` — remove `warp_releases: https://releases.warp.dev/`. It has
  no other consumer (grep confirms the only uses were `warp.bst` and `warp-update`).

- [x] **Step 4: check for strays before building**

  ```shell
  grep -rn "warp" --include='*' . \
    | grep -viE "warped|warpmv|warp_plane|warp_affine|pointer-warp|docs/plans/done"
  ```

  Expected remainder after steps 1-3: `docs/skills/bst.md` (Step 5),
  `scripts/enrich-sbom-purls.py:21`, `files/fakecap-manifest.tsv` (Step 6). Anything else
  is a missed reference. `docs/plans/done/` is frozen — never edit it
  (`2026-08-09-add-limux-element.md` cites `desktop/warp.bst` three times and must stay
  as written).

- [x] **Step 5: re-scope the skill entries, do not delete them**

  `docs/skills/bst.md` carries three Warp-derived lessons that remain true about `.deb`
  packaging generally even though the element is gone — per AGENTS.md's rot rule
  ("mechanism gone but the lesson moved → re-scope, don't delete"):

  - L1446 `### Vendor apt/yum repos as a pinnable prebuilt-binary source (e.g. Warp)`
  - L1456 the `postinst` symlink bullet
  - L1653 the `/opt` → `%{indep-libdir}` relocation section

  Rewrite the framing to past tense with an explicit "element removed in #1005; the
  pattern still applies to `desktop/zed.bst` and `desktop/equibop.bst`" note, so a reader
  does not go looking for `elements/desktop/warp.bst`. Keep the URL-resolution and
  `postinst` details verbatim — those were expensive to discover.

  `scripts/enrich-sbom-purls.py:21` lists `warp` among packages whose Grype matches traced
  to element wrappers. That is a record of a past scan, not a claim about the current
  image; leave the sentence, since rewriting it would falsify the evidence it cites.

- [ ] **Step 6: regenerate the fakecap manifest**

  After the image builds (Phase 3 Step 1):

  ```shell
  mise run generate-fakecap-manifest
  ```

  Drops `/./usr/bin/warp-terminal` (currently L3133). The task walks every element's
  artifact and is slow; run it once, after the build, not before. Not CI-verified, so it
  will silently rot if skipped.

## Phase 3 — verification

- [ ] **Step 1: build**

  ```shell
  mise run build
  ```

  Ends with `lint` + `umbriel-config-validate` on its own — do not run `mise run lint`
  separately (AGENTS.md § Verification). `umbriel-config-validate` is the gate that
  catches a bad `spawn:seance` action name; confirm it passed rather than assuming.

- [x] **Step 2: docs**

  ```shell
  mise run docs-links
  ```

  Deleting `elements/desktop/warp.bst` and `mise/tasks/warp-update` invalidates any
  backticked reference to those paths in markdown (checker classes 3 and 4).

- [ ] **Step 3: terminal selection, in the built image**

  ```shell
  mise run boot-vm   # or boot-test for automated pass/fail
  ```

  In the guest:

  ```
  xdg-terminal-exec --print-id --print-cmd -- true   # → com.mitchellh.ghostty.desktop, /usr/bin/ghostty ... -e true
  command -v warp-terminal                           # → nothing, exit 1
  grep -c warp /usr/manifest.json                    # → 0
  ls /usr/lib/warp-terminal                          # → No such file or directory
  ```

- [ ] **Step 4: the bind, on both compositors**

  niri session: `Mod+Return` opens seance; `Mod+Shift+7` shows "Open a Terminal: seance".
  umbriel session: `Mod+Return` opens seance. Confirm the window's `app_id` is
  `com.seance.app` (`niri msg --json windows`), which is what a future window rule would
  have to match.

  A compositor smoke run (`mise run compositor-smoke`) does not exercise a keybind — this
  step is manual, and the PR must say so rather than implying automation covered it.

- [ ] **Step 5: vuln-scan delta**

  Removing a vendored `.deb` moves the match count. Re-run the scan and confirm the
  change is subtractive only; `.grype.yaml` needs no new ignores (verified: it has no
  warp entries today). If a *new* advisory appears, triage per
  `.claude/skills/vuln-scan-triage/` — do not blanket-ignore.

## Phase 4 — skill write-back (same commits, not a follow-up)

The learning this work produces is **not** "krytis uses seance now" — it is the trap
underneath:

> `Categories=...TerminalEmulator;` is a *classification*, not a capability. It says
> nothing about whether the app can run a command. Both warp and seance declare it and
> neither implements `-e`; `xdg-terminal-exec` synthesises `-e` for any entry lacking
> `X-TerminalArgExec`, so the failure is a silent no-op with exit 0 — no error, no
> window, nothing in a log. Any image shipping more than one `TerminalEmulator` entry
> must pin `/etc/xdg/xdg-terminals.list` explicitly; fallback ordering is not
> alphabetical and not stable across package changes.

- [x] Add that to `docs/skills/desktop.md` as a new section, with the two `--print-id`
      transcripts as evidence and the "which terminal opens" vs "which terminal executes"
      split stated once, plainly.
- [x] Record in the same section that noctalia does its own discovery
      (`$TERMINAL` → hardcoded list → `-e sh -lc`), so it is pinned by `$TERMINAL` if ever
      needed, *not* by `xdg-terminals.list` — two different mechanisms that look like one.
- [x] `docs/skills/bst.md` re-scoping from Phase 2 Step 5 lands in the same commit as the
      element deletion, not after it.
- [x] While in `docs/skills/desktop.md`: it is 2000+ lines. Check whether the section
      being added neighbours anything already stale and fix it in the same pass
      (AGENTS.md § Skill files rot too).

## Cleanup

- [ ] `git mv docs/plans/2026-09-29-default-to-seance-drop-warp.md docs/plans/done/` in
      the PR that lands the work.
