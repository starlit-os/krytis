# Battery-Triggered Power Profile Switch

Status: **Design Gate cleared** (issue #261, decisions below). Implementation not yet started —
see `docs/plans/2026-08-04-battery-power-profile-switch.md` for the execution plan.

## Problem

Live-verified (session behind #261): none of `power-profiles-daemon`, `falcond`, or `noctalia`
change `power-profiles-daemon`'s `ActiveProfile` in response to AC/battery state. Unplug AC,
`ActiveProfile` sits wherever it was left, indefinitely. Many desktop environments treat this as
baseline behavior (GNOME's `gsd-power` calls ppd on low battery); krytis currently doesn't.

## Ownership: this is upstream noctalia code, not a krytis element

`desktop/noctalia.bst` builds `github:noctalia-dev/noctalia.git` (`kind: git_repo`, `track: v*`,
currently pinned `v5.0.0-beta.7-0-g...`). Krytis carries **no source patches** against it today —
the codebase is upstream's, not ours (`docs/skills/desktop.md` § noctalia build deps). This is
**not** a `.bst`-only change; it requires C++ changes to noctalia's own source.

Decision (Design Gate): **fork-and-patch only for now.** Build and verify on a fork
(`kitten-lily/noctalia`, matching the historical fork naming used for the pre-merge
wifi-persist-polkit-async patch), carry it into krytis as a `kind: patch` source once verified.
**No upstream PR** to `noctalia-dev/noctalia` without a separate, later explicit go-ahead per
AGENTS.md's Upstream Gate — not authorized as part of this decision. Worth re-checking later:
the *related* upstream issue (`noctalia-dev/noctalia-shell#2051`, different feature — TLP-style
per-profile tuning) was closed 2026-05-16 with "we aren't quite ready to open up the v5 tracker
for public bug reports or feature requests just yet."

## Architecture: where this hooks in

Noctalia already has every primitive needed except the policy glue:

- `src/dbus/upower/upower_service.{h,cpp}` — `UPowerService` maintains `UPowerState::onBattery`
  (read from `org.freedesktop.UPower`'s `OnBattery` property), refreshed on the `PropertiesChanged`
  D-Bus signal, exposed via `setChangeCallback()`. Purely read-only today — no code path reacts to
  `onBattery` flipping.
- `src/dbus/power/power_profiles_service.{h,cpp}` — `PowerProfilesService::setActiveProfile()`
  writes `org.freedesktop.UPower.PowerProfiles`'s `ActiveProfile` property (async, optimistic
  local update + `PropertiesChanged` reconciliation). Also tracks
  `PowerProfilesChangeOrigin` (`Noctalia` vs `External`) via `consumeActiveProfileChangeOrigin()`,
  so a component can tell "did *I* cause this transition" apart from "did something else."
- Both services are constructed once and owned by the app root (per DeepWiki's line-anchored
  read of `src/app/application.h`: `PowerProfilesService` ~L126, `UPowerService` ~L136) and handed
  by pointer to consumers like `PowerTab` (`src/shell/control_center/tabs/power_tab.cpp`,
  constructor `PowerTab(UPowerService*, PowerProfilesService*)`). A new `PowerAutoSwitchController`
  (or similar) is a natural third component constructed alongside them in `application.h`/`.cpp`,
  taking both services by pointer — no new D-Bus plumbing needed, only a new consumer.

Settings persistence: noctalia writes user config to `~/.config/noctalia/settings.json` (schema
seeded from an in-repo default-settings asset). New setting `power.autoSwitchOnBattery` (bool,
**default `false`** — opt-in, see Design Gate decisions), plus `power.autoSwitchPowerSaverProfile`
/ `power.autoSwitchAcProfile` string overrides (default `power-saver` / recorded-previous), is the
persistence point, exposed as a toggle on the existing `PowerTab` profiles card
(`buildProfilesCard()`).

## Coexistence with falcond

falcond is a **second, independent writer** of `ActiveProfile` — it is not merely something to
avoid "fighting" abstractly, it literally calls the same D-Bus property setter noctalia would.
Confirmed via falcond's own status contract (`README.md` "Monitoring" section, `RESTORE_STATE:
Power Profile: <value>` field): on game launch falcond snapshots whatever `ActiveProfile` was
active, forces `performance`, and on game exit restores the snapshot. If noctalia's auto-switch
independently rewrites `ActiveProfile` while a game hold is active, the two either race or falcond
silently clobbers noctalia's choice on the next poll (falcond's `poll_interval_ms`, default 9000ms).

falcond exposes exactly the integration point needed to avoid this, and documents it as a stable
third-party contract: `/tmp/falcond_status` — "3rd-party contract; atomic rename" (per falcond's
build-time `-Dtmp-status-file` doc, explicitly called out as the file for consumers like
mangohud). Its `ACTIVE_PROFILE:` field is non-empty exactly when a game-profile hold is in effect.
Proposed rule: **`PowerAutoSwitchController` reads `/tmp/falcond_status` before writing
`ActiveProfile`; if `ACTIVE_PROFILE` is non-empty, skip the write** (falcond's own restore-on-exit
already returns the profile to whatever noctalia last set as the "resting" state, since falcond's
`RESTORE_STATE` snapshot was taken *after* noctalia's prior write). This requires no new IPC
surface — parsing one small text file already documented as a stable external contract.

Caveat: falcond has no libnotify/D-Bus signal for "hold started/ended," only the file and a
9-second poll cadence — so there's an unavoidable small window (up to one falcond poll interval)
where a plug/unplug event and a game launch/exit can interleave and briefly disagree. Acceptable:
worst case is one stale profile for a few seconds, self-corrects on the next check.

## Policy (Design Gate decisions — locked in)

- **Opt-in, default off.** `power.autoSwitchOnBattery = false` by default; user enables it from
  the `PowerTab` profiles card. No behavior change for existing users on an update.
- **Trigger: any AC unplug**, not a percentage threshold. Subscribe to `UPowerService`'s change
  callback; act only on `onBattery` transitions (not every battery-percentage tick —
  `UPowerState::onBattery` changing is a `PropertiesChanged` on `org.freedesktop.UPower`'s
  `OnBattery` key specifically, distinct from percentage/rate updates on device objects).
- **Revert target: recorded previous profile**, not a fixed `balanced`. On `onBattery: false →
  true`: if `/tmp/falcond_status`'s `ACTIVE_PROFILE` is empty, record the current `ActiveProfile`
  (skip recording if it's already `power-saver` — avoid capturing our own prior auto-switch as
  the "previous" value on a rapid unplug/replug/unplug sequence), then
  `setActiveProfile("power-saver")`. On `onBattery: true → false`: if `/tmp/falcond_status`'s
  `ACTIVE_PROFILE` is empty, restore the recorded profile (fallback `balanced` if nothing was
  recorded, e.g. the app started while already on battery).
- **falcond coexistence: poll `/tmp/falcond_status`**, confirmed as the mechanism. Skip any
  auto-switch write while `ACTIVE_PROFILE` is non-empty (falcond's own restore-on-exit already
  returns the profile to whatever noctalia last set as the "resting" state, since falcond's
  `RESTORE_STATE` snapshot is taken after noctalia's prior write).
- Do nothing if the user manually changes `ActiveProfile` while on battery — respect
  `PowerProfilesChangeOrigin::External` as "user overrode me, don't fight back" for the rest of
  that battery session (re-arms on the next AC transition). This mirrors "shouldn't fight a manual
  override" from the issue body.

## Design Gate — resolved 2026-08-04

1. **Opt-in or default-on?** → **Opt-in**, default off.
2. **Trigger granularity?** → **Any AC unplug** (no percentage threshold).
3. **Revert target on AC reconnect?** → **Recorded previous profile** (fallback `balanced`).
4. **falcond coexistence mechanism?** → **Poll `/tmp/falcond_status`**, confirmed.
5. **Where does the code land?** → **Fork-and-patch only for now**; no upstream PR authorized.

## References

- Issue #261
- `docs/skills/desktop.md` § noctalia (shell) build dependencies — fork/patch precedent
- `docs/skills/pam.md` § noctalia-greeter PAM_TEXT_INFO — patch-then-upstream-merge precedent
- noctalia source (read at investigation time, `main` branch):
  `src/dbus/upower/upower_service.{h,cpp}`, `src/dbus/power/power_profiles_service.{h,cpp}`,
  `src/shell/control_center/tabs/power_tab.cpp`
- falcond `README.md` "Monitoring" / "Build Path Options" sections —
  `/tmp/falcond_status` contract, `RESTORE_STATE` semantics
- `noctalia-dev/noctalia-shell#2051` (closed) — evidence the v5 issue tracker may not be
  accepting public feature requests; re-check before proposing an upstream PR
