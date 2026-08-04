# Battery-Triggered Power Profile Switch

Status: **Design Gate — awaiting human sign-off** (issue #261). No implementation yet.

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

Two paths, not mutually exclusive:

1. **Local patch** (`kind: patch` source added after the `git_repo` source in `noctalia.bst`,
   same pattern as the historical `0001-show-pam-info-cue.patch` — see `docs/skills/pam.md`
   § noctalia-greeter PAM_TEXT_INFO, since merged and removed once upstream absorbed it).
   Ships immediately, survives re-pins only as long as someone re-verifies the patch applies.
2. **Upstream PR** to `noctalia-dev/noctalia`. Per AGENTS.md Upstream Gate, opening this requires
   an explicit go-ahead from the human, not implied by "fix it in noctalia." Also worth noting:
   the *related* upstream issue (`noctalia-dev/noctalia-shell#2051`, different feature —
   TLP-style per-profile tuning) was closed 2026-05-16 with "we aren't quite ready to open up
   the v5 tracker for public bug reports or feature requests just yet." Unclear if that has
   changed since; needs a fresh check before assuming a PR will even be triaged.

Recommendation: build and verify on a fork (`kitten-lily/noctalia`, matching the historical fork
naming used for the pre-merge wifi-persist-polkit-async patch), carry it into krytis as a
`kind: patch` source once verified, and separately **propose** (not open) an upstream PR per the
Upstream Gate's "propose, then wait" allowance.

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
seeded from an in-repo default-settings asset). A new setting, e.g. `power.autoSwitchProfiles`
(bool, default **TBD — see open questions**) plus `power.autoSwitchPowerSaverProfile` /
`power.autoSwitchAcProfile` string overrides, is the natural persistence point, exposed as a
toggle on the existing `PowerTab` profiles card (`buildProfilesCard()`).

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

## Proposed policy (draft — see open questions for what's actually locked in)

- Subscribe to `UPowerService`'s change callback; act only on `onBattery` transitions (not every
  battery-percentage tick — `UPowerState::onBattery` changing is a `PropertiesChanged` on
  `org.freedesktop.UPower`'s `OnBattery` key specifically, distinct from percentage/rate updates
  on device objects).
- On `onBattery: false → true`: if `/tmp/falcond_status`'s `ACTIVE_PROFILE` is empty, record the
  current `ActiveProfile` (skip recording if it's already `power-saver` — avoid capturing our own
  prior auto-switch as the "previous" value on a rapid unplug/replug/unplug sequence), then
  `setActiveProfile("power-saver")`.
- On `onBattery: true → false`: if `/tmp/falcond_status`'s `ACTIVE_PROFILE` is empty, restore the
  recorded profile (fallback `balanced` if nothing was recorded, e.g. app started while already on
  battery).
- Do nothing if the user manually changes `ActiveProfile` while on battery — respect
  `PowerProfilesChangeOrigin::External` as "user overrode me, don't fight back" for the rest of
  that battery session (re-arms on the next AC transition). This mirrors "shouldn't fight a manual
  override" from the issue body.

## Open questions (Design Gate — human sign-off required before implementation)

1. **Opt-in or default-on?** Issue body suggests "configurable, maybe opt-in." A silent
   behavioral default change (auto-downclocking on unplug) is exactly the kind of thing the
   Design Gate exists for.
2. **Trigger granularity:** any-AC-unplug (`OnBattery` flip, as drafted above), or gated on a
   percentage/time threshold (e.g. only below 20%, like some DEs' "low battery" policy)? The
   drafted proposal is the simpler any-unplug rule.
3. **Revert target on AC reconnect:** "whatever was active before the switch" (drafted above,
   needs the record/restore bookkeeping) vs. a fixed default (e.g. always `balanced`)? The
   record/restore approach is more correct but has more edge cases (app restart mid-battery-session
   loses the recorded value; drafted fallback is `balanced` in that case).
4. **falcond coexistence mechanism:** confirmed viable via `/tmp/falcond_status` (see above) — is
   polling a text file before each write acceptable, or is a different signal preferred?
5. **Where does the code land:** fork-and-patch only (carried indefinitely as a `kind: patch` in
   `noctalia.bst`), or fork-and-patch now with an explicit go-ahead to also propose it upstream to
   `noctalia-dev/noctalia`?

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
