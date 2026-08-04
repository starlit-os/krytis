# Battery-Triggered Power Profile Switch

Status: **Implemented** (issue #261). No noctalia source patch, no fork carry — see
"Superseding the fork-and-patch plan" below for why.

## Problem

Live-verified (session behind #261): none of `power-profiles-daemon`, `falcond`, or `noctalia`
change `power-profiles-daemon`'s `ActiveProfile` in response to AC/battery state. Unplug AC,
`ActiveProfile` sits wherever it was left, indefinitely. Many desktop environments treat this as
baseline behavior (GNOME's `gsd-power` calls ppd on low battery); krytis previously didn't.

## Design Gate — resolved 2026-08-04

1. **Opt-in or default-on?** → **Opt-in**, default off.
2. **Trigger granularity?** → **Any AC unplug** (no percentage threshold).
3. **Revert target on AC reconnect?** → **Recorded previous profile** (fallback `balanced`).
4. **falcond coexistence mechanism?** → **Poll `/tmp/falcond_status`**, confirmed.
5. **Where does the code land?** → Originally decided "fork-and-patch only, no upstream PR" —
   **superseded once implementation started**, see below. All five decisions above still hold;
   only the *mechanism* changed.

## Superseding the fork-and-patch plan

The Design Gate above was resolved assuming this needs new noctalia C++ — confirmed at the time
by reading `src/dbus/upower/upower_service.cpp` and `src/dbus/power/power_profiles_service.cpp`
externally (GitHub raw, `main` branch) and finding no code path connecting the two. That
investigation was correct as far as it went, but incomplete: those two files are not the only
relevant subsystem.

Once the `kitten-lily/noctalia` fork was fast-forwarded to upstream and branched at krytis's
actual pinned ref (`v5.0.0-beta.7-0-gc366a35ffc30b011d03fcd122bbe7d22f932fc57`) for real
implementation work, a local read of `src/hooks/`, `src/config/config_types.h`, and
`src/shell/settings/settings_registry.cpp` turned up a **generic, already-shipped, GUI-exposed
hook system** that covers this exact case:

- `HookKind::BatteryDischarging` / `BatteryCharging` / `BatteryPlugged` /
  `BatteryPercentageChanged` / `PowerProfileChanged` (`src/config/config_types.h`)
- Fired from `Application::onUpowerStateChangedForHooks()` via `BatteryHookState::update()`
  (`src/hooks/battery_hook_state.cpp`) on every `UPowerState` change
- Each hook is a **user-configurable shell command**, run via `/bin/sh -lc "<command>"`
  (`src/core/process/process.cpp`), settable per-hook from **Settings → Hooks** in the GUI
  (`SettingsSection::Hooks`, `src/shell/settings/settings_registry.cpp`) — a text field per hook,
  empty by default, documented in `example.toml`'s commented-out `[hooks]` block

This is precisely the extension point the feature needs, already built, tested, and exposed to
users — a fork patch duplicating it would be pure unnecessary abstraction. **No noctalia source
change is needed at all.** Krytis's job shrinks to: ship a script that implements the
falcond-aware switch/revert policy, and document the two hook commands a user pastes in to
opt in.

## Implementation

- **Script**: `files/battery-power-profile-hook/battery-power-profile-hook.sh`, installed by
  `elements/config/battery-power-profile-hook.bst` to
  `/usr/libexec/krytis/battery-power-profile-hook.sh` (added to `stacks/desktop.bst`).
- **Opt-in mechanism**: user pastes two commands into noctalia's Settings → Hooks:

  ```
  battery_discharging = "/usr/libexec/krytis/battery-power-profile-hook.sh discharging"
  battery_charging    = "/usr/libexec/krytis/battery-power-profile-hook.sh charging"
  ```

  Krytis ships the script but sets neither hook command by default — matches the "opt-in,
  default off" decision without needing a settings toggle of our own; noctalia's own Hooks UI
  *is* the toggle.
- **Profile switch**: on `battery_discharging`, read `ActiveProfile` via
  `busctl get-property org.freedesktop.UPower.PowerProfiles …`; if it isn't already
  `power-saver`, save it to `${XDG_RUNTIME_DIR:-/tmp}/krytis-battery-power-profile.state` and
  `busctl set-property … ActiveProfile s power-saver`.
- **Revert**: on `battery_charging`, restore the recorded profile via the same `busctl
  set-property` call (fallback `balanced` if no state file — e.g. noctalia started mid-battery-
  session, so no discharging edge was ever observed).
- **falcond gate**: both directions check `/tmp/falcond_status`'s `ACTIVE_PROFILE` field first
  (falcond's documented third-party contract) and no-op if non-empty (a game hold is active) —
  or if the file is missing/unreadable at all. The latter fails **closed** (treated as "holding",
  action suppressed): falcond is unconditionally installed and preset-enabled in
  `stacks/desktop.bst`, so a missing status file means either a brief pre-first-write boot race
  or a stopped/crashed daemon, not "falcond doesn't exist here" — suppressing until falcond
  publishes real status is the safe default, and self-corrects on the next battery event.
- **Manual override**: automatically respected without extra bookkeeping. Unlike a persistent
  D-Bus-subscribed controller, these hooks fire only on the `Discharging`/`Charging` UPower state
  *edges* (`BatteryHookState` is edge-triggered, not polling) — the script runs once per unplug
  and once per reconnect, never re-asserting a profile mid-session, so there is nothing to fight
  a manual change with between those edges.

### `battery_charging` vs `battery_plugged` — a naming trap

Noctalia's `HookKind` naming is not what it looks like for the "AC reconnected" case.
`BatteryHookState::update()` maps UPower's `BatteryState` to hooks as:

| UPower state | Hook fired |
|---|---|
| `Charging` | `HookKind::BatteryCharging` |
| `Discharging` | `HookKind::BatteryDischarging` |
| `FullyCharged` / `PendingCharge` | `HookKind::BatteryPlugged` |

**`battery_plugged` does not fire when AC is plugged in** — it fires when the battery *reaches
full charge* while already on AC (`FullyCharged`), which can happen hours after the actual plug
event, or not caught at all if the machine idles below 100% (typical with charge-limiting
firmware). `battery_charging` is the hook that actually fires on the `Discharging → Charging`
transition, i.e. the real "AC reconnected" moment. Only `battery_charging` is used here; a
`battery_plugged` reconnect-restore would have been unreliable (late, or missing on hardware that
never reports `FullyCharged`). One edge case remains uncovered: a laptop that reconnects AC while
already at exactly 100% jumps `Discharging → FullyCharged` directly, skipping the `Charging`
edge — `battery_charging` doesn't fire for that reconnect. Accepted tradeoff; rare in practice
(a laptop discharging while already at 100% is itself unusual) and the profile self-corrects on
the *next* unplug/replug cycle regardless.

## Coexistence with falcond — background

falcond is a **second, independent writer** of `ActiveProfile` — it literally calls the same
D-Bus property setter this script does. Confirmed via falcond's own status contract
(`README.md` "Monitoring" section, `RESTORE_STATE: Power Profile: <value>` field): on game
launch falcond snapshots whatever `ActiveProfile` was active, forces `performance`, and on game
exit restores the snapshot. If this hook independently rewrote `ActiveProfile` while a game hold
is active, the two would race or falcond would silently clobber the hook's choice on its next
poll (`poll_interval_ms`, default 9000ms).

falcond exposes exactly the integration point needed to avoid this, and documents it as a stable
third-party contract: `/tmp/falcond_status` — "3rd-party contract; atomic rename" (falcond's
build-time `-Dtmp-status-file` doc, explicitly called out as the file for consumers like
mangohud). Its `ACTIVE_PROFILE:` field is non-empty exactly when a game-profile hold is in
effect — falcond's own restore-on-exit already returns the profile to whatever this hook last
set as the "resting" state, since falcond's `RESTORE_STATE` snapshot is taken after the hook's
prior write, so skipping while held is sufficient; no read-modify-write coordination is needed.

Caveat: falcond has no D-Bus signal for "hold started/ended," only the file and a ~9-second poll
cadence — so there's an unavoidable small window where a plug/unplug event and a game launch/exit
can interleave and briefly disagree. Acceptable: worst case is one stale profile for a few
seconds, self-corrects on the next check.

## References

- Issue #261
- `docs/skills/desktop.md` § "noctalia has a generic Hooks system" — the lesson this design
  produced, and § "Carrying a local patch" for the (unused, but still valid for other cases)
  fork-patch pattern
- noctalia source (read locally at the pinned ref, `c366a35ff`):
  `src/hooks/hook_manager.{h,cpp}`, `src/hooks/battery_hook_state.{h,cpp}`,
  `src/config/config_types.h` (`HookKind`, `HooksConfig`), `src/core/process/process.cpp`
  (`runAsync(command)` → `/bin/sh -lc`), `src/shell/settings/settings_registry.cpp`
  (`SettingsSection::Hooks`), `example.toml` (`[hooks]` block)
- falcond `README.md` "Monitoring" / "Build Path Options" sections —
  `/tmp/falcond_status` contract, `RESTORE_STATE` semantics
- `noctalia-dev/noctalia-shell#2051` (closed, unrelated feature) — evidence the v5 issue tracker
  may not be accepting public feature requests, kept for context though no upstream PR was
  needed for this issue
