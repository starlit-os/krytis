# presence-bridge — host-side game detection for sandboxed Discord

Status: **in the image, installed disabled (2026-10-11)**. The service lives in its
own repo, [kitten-lily/presence-bridge](https://github.com/kitten-lily/presence-bridge),
public since about 08:16Z on 2026-10-11
(`docs/skills/workflow.md` § When a repo went public). Its unit tests pass, and the
README's live check passed on 2026-10-09 against the `com.discordapp.Discord`
flatpak for World of Warcraft and Hearthstone launched from Faugus: detected,
reported with the right start time, and cleared on exit
([kitten-lily/presence-bridge#3](https://github.com/kitten-lily/presence-bridge/pull/3)).
krytis builds it as `desktop/presence-bridge.bst` (see *Packaging*).

This is option 2 of [#595](https://github.com/starlit-os/krytis/issues/595):
"something outside any sandbox scans `/proc`, matches executables, and pushes
activity over RPC to Discord's socket."

## Problem

A flatpak Discord client sits in its own PID namespace, so its process-scan game
detection never sees a game launched from another flatpak (Faugus, Heroic, Steam,
Lutris, Bottles). Games that speak Discord RPC themselves are fine once the socket
path is solved (#591, Proton's `rpc-bridge`). Games that rely on detection alone —
World of Warcraft holds zero Discord sockets — show nothing.
`docs/skills/bst.md` § Flatpak sandboxing: Discord RPC and game detection has the
evidence and why no flatpak override fixes it.

## Decision

A user service in the host PID namespace detects games on the client's behalf. It
matches `/proc/<pid>/cmdline` argv0 against Discord's detectable-applications list
with arRPC's rules, finds every sandboxed client by globbing
`$XDG_RUNTIME_DIR/{.flatpak/*/xdg-run,app/*}/discord-ipc-N`, and reports each game by
handshaking as the game's own application ID. The repo's README is the reference for
the mechanism, its known limitations, and the live test procedure; it is not
duplicated here.

**Why its own repo:** nothing in it is krytis-specific — any distro shipping
flatpak Discord has the same gap — and a separate repo gives it its own release tags
for krytis to track.

**Why not the alternatives:** a native Discord element was rejected in #595 by the
same reasoning as native Steam in `docs/design/gaming-variant.md`. Krytis shipped
native Equibop (`desktop/equibop.bst`) from #609 until #1194 removed it in favour of
the `org.equicord.equibop` flatpak, which this bridge covers.

**The canonical `$XDG_RUNTIME_DIR/discord-ipc-N` stays skipped by default** (the
bridge's `--include-host` flag is off; the unit passes no flags). Native Equibop
was the original reason: it held that path and detected games itself. Since #1194
the image puts nothing there, so the skip costs nothing on a stock install, and the
upstream rule still holds for a native client a user adds: anything listening at the
canonical path shares the host PID namespace and detects games itself, so reporting
to it doubles the activity (presence-bridge
[`ipc.md` § Finding clients](https://github.com/kitten-lily/presence-bridge/blob/main/docs/skills/ipc.md#finding-clients)).
Decided in #1194: no change upstream or in the unit.

## Packaging

`desktop/presence-bridge.bst`, a `kind: manual` cargo build in the shape of
`desktop/xwayland-satellite.bst` (upstream has no Makefile, so `kind: make` does not
apply), pulled in by `stacks/desktop-apps.bst`:

- A `git_repo` source on `github:kitten-lily/presence-bridge.git` with `track: v*`,
  matching the `v{{ version }}` tags release-plz cuts, followed by a `cargo2` source.
  `bst source track` moves the git ref and regenerates the `cargo2` refs from the new
  tag's `Cargo.lock` in one pass (`docs/skills/bst.md` § Rust / Cargo Projects).
  Listing the element in the `track` matrix of `.github/workflows/track-bst-sources.yml`
  satisfies the AGENTS.md update path gate. The tags are unsigned; the tracked
  `ref:` pins the commit, so a moved tag cannot change what krytis builds.
- Installs `/usr/bin/presence-bridge` and the repo's own
  `systemd/presence-bridge.service` to `%{indep-libdir}/systemd/user/`.
- **The unit ships disabled** (maintainer decision on #1152), even though running it
  is cheap — while no client socket exists it only probes for one, with no `/proc`
  scan and no request to discord.com. That takes a `disable presence-bridge.service`
  user-preset rule: with no rule, the image's global preset step enables it
  (`docs/skills/bst.md` § User units fall through too). Users opt in with
  `mise presence-bridge:enable` and out with `mise presence-bridge:disable`;
  those tasks call upstream's `presence-bridge service install|uninstall`,
  which finds this packaged unit and enables or disables it. The tasks are
  declared by the same element in `/etc/mise/conf.d/presence-bridge.toml`.
