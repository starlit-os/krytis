# presence-bridge — host-side game detection for sandboxed Discord

Status: **draft, not in the image (2026-10-09)**. The service lives in its own repo,
[kitten-lily/presence-bridge](https://github.com/kitten-lily/presence-bridge),
private as of 2026-10-09 and intended to go public. Its unit tests pass and its
scan → report → clear loop was exercised against a fake IPC server; it has not been
run against a real Discord. Packaging it into krytis is still open (see
*Packaging*).

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
same reasoning as native Steam in `docs/design/gaming-variant.md`. Krytis's native
Equibop (`desktop/equibop.bst`) already detects games itself, which is why the
bridge skips the canonical `$XDG_RUNTIME_DIR/discord-ipc-N` by default.

## Packaging

Planned shape, following `core/bootc.bst` and `config/xwayland-satellite.bst`:

- `elements/desktop/presence-bridge.bst`, `kind: make`: a `git_repo` source on
  `github:kitten-lily/presence-bridge.git` with a `track:` glob on release tags,
  followed by a `cargo2` block generated from the repo's `Cargo.lock`
  (`docs/skills/bst.md` § Rust / Cargo Projects). Listing the element in the
  `track` matrix of `.github/workflows/track-bst-sources.yml` satisfies the
  AGENTS.md update path gate: `bst source track` moves the git ref and regenerates
  the `cargo2` refs from the new lockfile in one pass.
- Install `/usr/bin/presence-bridge` and the repo's `systemd/presence-bridge.service`
  to `%{indep-libdir}/systemd/user/`, plus a `user-preset` enabling it.
- Enabled by default is cheap: while no client socket exists the service only
  probes for one, with no `/proc` scan and no request to discord.com.

**Blocked while the repo is private.** BuildStream fetches the `git_repo` source
anonymously, so CI and bow cannot fetch a private repo. The element has to wait for
the repo to go public.
