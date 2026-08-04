# Battery-Triggered Power Profile Switch Implementation Plan

**Goal:** Auto-switch `power-profiles-daemon`'s `ActiveProfile` to `power-saver` on AC unplug and
back to the previously-active profile on AC reconnect, opt-in via a noctalia settings toggle,
without fighting falcond's game-profile holds.

**Architecture:** New `PowerAutoSwitchController` in noctalia (fork), owned alongside the existing
`UPowerService`/`PowerProfilesService` in `src/app/application.{h,cpp}`. Reacts to `UPowerService`
change callbacks, gates writes on `/tmp/falcond_status`, persists a settings toggle. Krytis-side:
carry the noctalia change as a `kind: patch` source on `desktop/noctalia.bst`.

**Tech Stack:** C++ (noctalia, sdbus-c++, existing service pattern), QML/existing UI toolkit for
the settings toggle, BuildStream `kind: patch` source for krytis integration.

**Design reference:** `docs/design/power-profile-auto-switch.md` — read this first. All policy
decisions below are locked in there (Design Gate resolved 2026-08-04); this plan does not
re-litigate them.

## Global Constraints

- Default **off** (`power.autoSwitchOnBattery = false`). No behavior change for existing users
  until they opt in.
- No new D-Bus surface — reuse `UPowerService`/`PowerProfilesService`, gate on
  `/tmp/falcond_status`.
- No upstream PR to `noctalia-dev/noctalia` as part of this plan — fork-and-patch only
  (`kitten-lily/noctalia`).
- This plan's Task 1-5 happen in the `kitten-lily/noctalia` fork (a repo krytis doesn't check
  out); Task 6 is the krytis-side integration. Tasks 1-5 need to be executed from a session with
  that fork checked out — this plan documents exactly what to do there, but this krytis worktree
  cannot run/test C++ code against it directly.
- Task 6 must update `docs/skills/desktop.md`'s new "Carrying a local patch" bullet AND add a row
  to [issue #483](https://github.com/starlit-os/krytis/issues/483)'s patch inventory table, in
  the same commit — this is now a repo-wide mandate, not specific to this feature.

---

### Task 1: Fork and branch

**Files:** none (repo/branch setup)

- [ ] **Step 1: Fork if not already forked**

Check whether `kitten-lily/noctalia` already exists (`gh repo view kitten-lily/noctalia`). If
not, fork upstream:

```bash
gh repo fork noctalia-dev/noctalia --org kitten-lily --clone=false
```

- [ ] **Step 2: Clone and branch**

```bash
git clone git@github.com:kitten-lily/noctalia.git
cd noctalia
git remote add upstream https://github.com/noctalia-dev/noctalia.git
git checkout -b feat/battery-auto-switch-profile v5.0.0-beta.7-0-gc366a35ffc30b011d03fcd122bbe7d22f932fc57
```

(Branch from the exact commit krytis currently pins, per `elements/desktop/noctalia.bst`'s
`ref:` — keeps the diff minimal against what krytis actually builds.)

**Interfaces:** none — setup only.

---

### Task 2: `PowerAutoSwitchController` — state machine, no I/O yet

**Files:**
- Create: `src/dbus/power/power_auto_switch_controller.h`
- Create: `src/dbus/power/power_auto_switch_controller.cpp`
- Test: `tests/dbus/power/power_auto_switch_controller_test.cpp` (mirror the existing test
  harness pattern used for `power_profiles_service` if one exists under `tests/dbus/power/`;
  if none exists, add a plain Meson test executable following the pattern of noctalia's other
  `tests/` targets referenced in `meson.build`)

Isolate the policy decision (what profile to set, when) from the I/O (D-Bus calls, file reads) so
it's unit-testable without a live system bus or `/tmp/falcond_status`.

**Interfaces:**
- Consumes: nothing from earlier tasks (this is the first code task).
- Produces:
  - `enum class FalcondHoldState { Unknown, Held, Free };`
  - `struct AutoSwitchDecision { bool shouldSetProfile = false; std::string targetProfile; bool shouldRecordCurrent = false; };`
  - `class PowerAutoSwitchPolicy` with:
    - `AutoSwitchDecision onBatteryStateChanged(bool onBattery, bool enabled, FalcondHoldState falcondHeld, std::string_view currentProfile, std::optional<std::string> recordedProfile) const;`
    - Pure function, no members beyond constants — later tasks call this from the D-Bus-facing
      controller.

- [ ] **Step 1: Write the failing tests**

```cpp
#include "dbus/power/power_auto_switch_controller.h"
#include <gtest/gtest.h> // or noctalia's existing test framework — check meson.build for the
                          // actual test runner in use before assuming gtest; adjust includes/
                          // macros to match if it's a different framework (e.g. Catch2, doctest).

TEST(PowerAutoSwitchPolicy, DisabledDoesNothing) {
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      /*onBattery=*/true, /*enabled=*/false, FalcondHoldState::Free,
      /*currentProfile=*/"balanced", /*recordedProfile=*/std::nullopt
  );
  EXPECT_FALSE(decision.shouldSetProfile);
}

TEST(PowerAutoSwitchPolicy, UnplugRecordsAndSwitchesToPowerSaver) {
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      true, true, FalcondHoldState::Free, "balanced", std::nullopt
  );
  EXPECT_TRUE(decision.shouldSetProfile);
  EXPECT_EQ(decision.targetProfile, "power-saver");
  EXPECT_TRUE(decision.shouldRecordCurrent);
}

TEST(PowerAutoSwitchPolicy, UnplugWhileAlreadyPowerSaverDoesNotRecord) {
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      true, true, FalcondHoldState::Free, "power-saver", std::nullopt
  );
  EXPECT_FALSE(decision.shouldSetProfile); // already power-saver, nothing to do
  EXPECT_FALSE(decision.shouldRecordCurrent);
}

TEST(PowerAutoSwitchPolicy, ReconnectRestoresRecordedProfile) {
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      false, true, FalcondHoldState::Free, "power-saver", std::optional<std::string>{"performance"}
  );
  EXPECT_TRUE(decision.shouldSetProfile);
  EXPECT_EQ(decision.targetProfile, "performance");
}

TEST(PowerAutoSwitchPolicy, ReconnectWithNoRecordedProfileFallsBackToBalanced) {
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      false, true, FalcondHoldState::Free, "power-saver", std::nullopt
  );
  EXPECT_TRUE(decision.shouldSetProfile);
  EXPECT_EQ(decision.targetProfile, "balanced");
}

TEST(PowerAutoSwitchPolicy, FalcondHeldSuppressesWrite) {
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      true, true, FalcondHoldState::Held, "performance", std::nullopt
  );
  EXPECT_FALSE(decision.shouldSetProfile);
}

TEST(PowerAutoSwitchPolicy, FalcondUnknownSuppressesWrite) {
  // Fail closed: if the status file can't be read/parsed, don't guess.
  PowerAutoSwitchPolicy policy;
  auto decision = policy.onBatteryStateChanged(
      true, true, FalcondHoldState::Unknown, "balanced", std::nullopt
  );
  EXPECT_FALSE(decision.shouldSetProfile);
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
meson setup build -Dtests=enabled && meson test -C build power_auto_switch_controller_test -v
```
Expected: FAIL — `power_auto_switch_controller.h` doesn't exist yet.

- [ ] **Step 3: Implement `power_auto_switch_controller.h`**

```cpp
#pragma once

#include <optional>
#include <string>
#include <string_view>

enum class FalcondHoldState { Unknown, Held, Free };

struct AutoSwitchDecision {
  bool shouldSetProfile = false;
  std::string targetProfile;
  bool shouldRecordCurrent = false;
};

// Pure policy: given the current world state, decide what (if anything) to do. No I/O.
class PowerAutoSwitchPolicy {
public:
  static constexpr std::string_view kBatteryProfile = "power-saver";
  static constexpr std::string_view kFallbackAcProfile = "balanced";

  [[nodiscard]] AutoSwitchDecision onBatteryStateChanged(
      bool onBattery, bool enabled, FalcondHoldState falcondHeld, std::string_view currentProfile,
      std::optional<std::string> recordedProfile
  ) const;
};
```

- [ ] **Step 4: Implement `power_auto_switch_controller.cpp`**

```cpp
#include "dbus/power/power_auto_switch_controller.h"

AutoSwitchDecision PowerAutoSwitchPolicy::onBatteryStateChanged(
    bool onBattery, bool enabled, FalcondHoldState falcondHeld, std::string_view currentProfile,
    std::optional<std::string> recordedProfile
) const {
  AutoSwitchDecision decision;
  if (!enabled || falcondHeld != FalcondHoldState::Free) {
    return decision;
  }

  if (onBattery) {
    if (currentProfile == kBatteryProfile) {
      return decision; // already there, nothing to record or set
    }
    decision.shouldRecordCurrent = true;
    decision.shouldSetProfile = true;
    decision.targetProfile = std::string(kBatteryProfile);
    return decision;
  }

  decision.shouldSetProfile = true;
  decision.targetProfile = recordedProfile.value_or(std::string(kFallbackAcProfile));
  return decision;
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
meson test -C build power_auto_switch_controller_test -v
```
Expected: PASS, all 7 cases.

- [ ] **Step 6: Register the new test in `meson.build`**

Find the existing `tests/` target list in noctalia's root `meson.build` (grep for
`tests/dbus/power` or the nearest sibling test registration) and add the new test executable
following the exact same pattern (source list, `test()` call, dependencies). Do not invent a new
registration style — match whatever the neighboring `power_profiles_service` test (if any) does,
or the general test-registration idiom used elsewhere in the file.

- [ ] **Step 7: Commit**

```bash
git add src/dbus/power/power_auto_switch_controller.h src/dbus/power/power_auto_switch_controller.cpp \
        tests/dbus/power/power_auto_switch_controller_test.cpp meson.build
git commit -m "feat(power): add battery auto-switch policy (pure, untested against D-Bus)"
```

---

### Task 3: falcond hold detection — `/tmp/falcond_status` reader

**Files:**
- Create: `src/dbus/power/falcond_status_reader.h`
- Create: `src/dbus/power/falcond_status_reader.cpp`
- Test: `tests/dbus/power/falcond_status_reader_test.cpp`

**Interfaces:**
- Consumes: `FalcondHoldState` from Task 2's header.
- Produces: `FalcondHoldState readFalcondHoldState(std::string_view statusFilePath = "/tmp/falcond_status");`
  — free function, injectable path for testing.

- [ ] **Step 1: Write the failing tests**

```cpp
#include "dbus/power/falcond_status_reader.h"
#include <filesystem>
#include <fstream>
#include <gtest/gtest.h>

namespace {
  std::string writeTempStatusFile(std::string_view contents) {
    auto path = std::filesystem::temp_directory_path() / "falcond_status_reader_test.tmp";
    std::ofstream out(path);
    out << contents;
    out.close();
    return path.string();
  }
} // namespace

TEST(FalcondStatusReader, MissingFileIsUnknown) {
  EXPECT_EQ(readFalcondHoldState("/nonexistent/path/for/test"), FalcondHoldState::Unknown);
}

TEST(FalcondStatusReader, EmptyActiveProfileIsFree) {
  auto path = writeTempStatusFile("LOADED_PROFILES: 7\n\nACTIVE_PROFILE: \n\nQUEUED_PROFILES:\n");
  EXPECT_EQ(readFalcondHoldState(path), FalcondHoldState::Free);
  std::filesystem::remove(path);
}

TEST(FalcondStatusReader, NonEmptyActiveProfileIsHeld) {
  auto path = writeTempStatusFile("LOADED_PROFILES: 7\n\nACTIVE_PROFILE: cs2\n\nQUEUED_PROFILES:\n");
  EXPECT_EQ(readFalcondHoldState(path), FalcondHoldState::Held);
  std::filesystem::remove(path);
}

TEST(FalcondStatusReader, NoneLiteralIsFree) {
  // falcond's status format uses "(None)" for other empty fields — verify ACTIVE_PROFILE
  // specifically, not a blanket "(None)" scan, since other sections use that literal too.
  auto path = writeTempStatusFile("ACTIVE_PROFILE: (None)\n\nQUEUED_PROFILES:\n  (None)\n");
  EXPECT_EQ(readFalcondHoldState(path), FalcondHoldState::Free);
  std::filesystem::remove(path);
}
```

- [ ] **Step 2: Run to verify failure** — `meson test -C build falcond_status_reader_test -v`,
  expect FAIL (header missing).

- [ ] **Step 3: Implement `falcond_status_reader.h`**

```cpp
#pragma once

#include "dbus/power/power_auto_switch_controller.h" // FalcondHoldState

#include <string_view>

[[nodiscard]] FalcondHoldState readFalcondHoldState(std::string_view statusFilePath = "/tmp/falcond_status");
```

- [ ] **Step 4: Implement `falcond_status_reader.cpp`**

Before writing this, re-verify the exact live format of `ACTIVE_PROFILE:` against a real
`/tmp/falcond_status` on a machine with falcond running a game (the README example is
authoritative but re-confirm empty-state formatting — README shows the *held* example only,
not what an idle daemon prints for `ACTIVE_PROFILE:`; check with `systemctl status falcond` +
`cat /tmp/falcond_status` on an idle system before assuming it's a bare blank line vs. `(None)`).

```cpp
#include "dbus/power/falcond_status_reader.h"

#include <fstream>
#include <sstream>
#include <string>

namespace {
  std::string trim(std::string_view s) {
    const auto begin = s.find_first_not_of(" \t\r\n");
    if (begin == std::string_view::npos) {
      return {};
    }
    const auto end = s.find_last_not_of(" \t\r\n");
    return std::string(s.substr(begin, end - begin + 1));
  }
} // namespace

FalcondHoldState readFalcondHoldState(std::string_view statusFilePath) {
  std::ifstream file{std::string(statusFilePath)};
  if (!file.is_open()) {
    return FalcondHoldState::Unknown;
  }

  std::string line;
  while (std::getline(file, line)) {
    constexpr std::string_view kPrefix = "ACTIVE_PROFILE:";
    if (line.compare(0, kPrefix.size(), kPrefix) != 0) {
      continue;
    }
    const std::string value = trim(line.substr(kPrefix.size()));
    if (value.empty() || value == "(None)") {
      return FalcondHoldState::Free;
    }
    return FalcondHoldState::Held;
  }

  // File exists but no ACTIVE_PROFILE line found — treat as unknown, fail closed.
  return FalcondHoldState::Unknown;
}
```

- [ ] **Step 5: Run tests, verify pass.** Register in `meson.build` (same pattern as Task 2 Step 6).

- [ ] **Step 6: Commit**

```bash
git add src/dbus/power/falcond_status_reader.h src/dbus/power/falcond_status_reader.cpp \
        tests/dbus/power/falcond_status_reader_test.cpp meson.build
git commit -m "feat(power): read falcond game-hold state from /tmp/falcond_status"
```

---

### Task 4: Wire the controller into the app — D-Bus-facing glue

**Files:**
- Modify: `src/app/application.h` (add `PowerAutoSwitchController` member, near existing
  `PowerProfilesService`/`UPowerService` members — read the file first to get the exact
  surrounding member declarations and constructor signature before editing)
- Modify: `src/app/application.cpp` (construct it after both services exist)
- Create: `src/dbus/power/power_auto_switch_controller_glue.h` / `.cpp` — the non-pure, I/O-doing
  half: owns callback subscriptions, calls `readFalcondHoldState()`, calls
  `PowerProfilesService::setActiveProfile()`, reads/writes the settings toggle.

**Interfaces:**
- Consumes: `PowerAutoSwitchPolicy` (Task 2), `readFalcondHoldState()` (Task 3),
  `UPowerService::setChangeCallback()` / `state().onBattery` (existing), `PowerProfilesService::
  setActiveProfile()` / `activeProfile()` / `consumeActiveProfileChangeOrigin()` (existing).
- Produces: `class PowerAutoSwitchGlue` with constructor
  `PowerAutoSwitchGlue(UPowerService& upower, PowerProfilesService& profiles, Settings& settings)`
  (adjust `Settings&` to whatever noctalia's actual settings-access type is named — grep
  `src/config/` or wherever `settings.json` is read/written before assuming a name; do not
  invent a type that doesn't exist in the codebase).

Before writing this task's code: read `src/app/application.h` and `src/app/application.cpp` in
full to get the real member list, constructor order, and settings-access pattern — this plan was
written from external reads of individual service files, not the full `application.*` pair, so
the exact wiring syntax must be confirmed against the live file, not assumed from this plan.

- [ ] **Step 1: Read `src/app/application.h` and `.cpp` in full**, note:
  - Exact member declaration syntax for `PowerProfilesService`/`UPowerService` (unique_ptr? plain
    member? owned elsewhere and injected?).
  - Where `PowerTab` is constructed and handed both services — construct
    `PowerAutoSwitchGlue` at the same point, after both.
  - How settings are read (`Settings::instance()`? injected reference? — find the real pattern).

- [ ] **Step 2: Write the failing test for the glue's D-Bus-independent behavior**

The glue class touches D-Bus and a settings singleton, so it isn't unit-testable the way Task 2/3
were. Test it via the existing `UPowerService`/`PowerProfilesService` test doubles if noctalia has
any (check `tests/dbus/power/` and `tests/dbus/upower/` for existing fakes/mocks before assuming
none exist). If test doubles exist for these services, write a test that:

```cpp
TEST(PowerAutoSwitchGlue, DisabledByDefaultMakesNoProfileCalls) {
  FakeUPowerService upower;         // adjust to whatever fake type actually exists
  FakePowerProfilesService profiles;
  FakeSettings settings;            // autoSwitchOnBattery defaults false
  PowerAutoSwitchGlue glue(upower, profiles, settings);

  upower.setOnBattery(true); // triggers change callback

  EXPECT_EQ(profiles.setActiveProfileCallCount(), 0);
}
```

If no fakes exist for these services in the codebase, skip the unit test for the glue layer and
rely on Task 6's manual verification instead — do not invent a mocking framework not already used
elsewhere in the project.

- [ ] **Step 3: Implement `PowerAutoSwitchGlue`**, wiring `UPowerService::setChangeCallback` to:
  1. Check `settings.autoSwitchOnBattery` (or equivalent — real accessor name from Step 1).
  2. Compare new `onBattery` against last-seen value; only act on an actual flip (guard against
     the callback firing on unrelated `UPowerState` field changes, e.g. percentage).
  3. Call `readFalcondHoldState()`.
  4. Call `PowerAutoSwitchPolicy::onBatteryStateChanged(...)`.
  5. Apply the `AutoSwitchDecision`: if `shouldRecordCurrent`, store `profiles.activeProfile()`
     into a recorded-profile member (in-memory is enough — no persistence needed across restarts,
     since the design doc's fallback is `balanced` for that case). If `shouldSetProfile`, call
     `profiles.setActiveProfile(decision.targetProfile)`.
  6. Also subscribe to `PowerProfilesService`'s change callback: if a profile change arrives whose
     origin (`consumeActiveProfileChangeOrigin`) is `External` while on battery, set an
     "overridden" flag that suppresses the next auto-switch until the next AC transition (per the
     design doc's "respect manual override" rule).

- [ ] **Step 4: Wire into `application.cpp`** at the point identified in Step 1.

- [ ] **Step 5: Build**

```bash
meson compile -C build
```
Expected: builds clean, no new warnings.

- [ ] **Step 6: Commit**

```bash
git add src/dbus/power/power_auto_switch_controller_glue.h src/dbus/power/power_auto_switch_controller_glue.cpp \
        src/app/application.h src/app/application.cpp
git commit -m "feat(power): wire battery auto-switch controller into the app"
```

---

### Task 5: Settings toggle in the Power tab UI

**Files:**
- Modify: `src/shell/control_center/tabs/power_tab.h` / `.cpp` — add a toggle row to
  `buildProfilesCard()`, alongside the existing segmented profile selector.
- Modify: wherever noctalia's settings schema/defaults are declared (find via grep for an
  existing `bool` setting under a `power.*` key — do not assume `Assets/settings-default.json`
  exists at that exact path; it 404'd during investigation, confirm the real location first).

**Interfaces:**
- Consumes: the real settings-access pattern confirmed in Task 4 Step 1.
- Produces: a persisted `power.autoSwitchOnBattery` boolean, default `false`.

- [ ] **Step 1:** Find an existing boolean toggle elsewhere in `power_tab.cpp` or a sibling tab
  (e.g. a similar on/off row) to copy the UI-construction pattern exactly — don't introduce a new
  widget style.

- [ ] **Step 2:** Add the toggle row to `buildProfilesCard()`, bound read/write to
  `settings.autoSwitchOnBattery` (or equivalent), default off, with a label via `i18n::tr(...)`
  (add the translation key to whatever the existing i18n string table file is, following the
  neighboring `control-center.power.*` keys already used in this file).

- [ ] **Step 3: Build and manually verify** the toggle appears in the Power tab, persists across
  a settings.json round-trip (`cat ~/.config/noctalia/settings.json` before/after toggling).

- [ ] **Step 4: Commit**

```bash
git add src/shell/control_center/tabs/power_tab.h src/shell/control_center/tabs/power_tab.cpp \
        <i18n string table file> <settings schema/defaults file>
git commit -m "feat(power): expose battery auto-switch toggle in Power tab"
```

---

### Task 6: Krytis-side integration — carry the patch

**Files:**
- Create: `patches/noctalia/0001-battery-auto-switch-power-profile.patch` (krytis repo)
- Modify: `elements/desktop/noctalia.bst` (krytis repo) — add a `kind: patch` source after the
  existing `kind: git_repo` source
- Modify: `docs/skills/desktop.md` (already carries the tracking-issue mandate as of this plan's
  own commit — just add this specific patch's context if a future re-pin needs it)
- Modify: issue #483's inventory table (GitHub, not a repo file)

**Interfaces:** none — this is packaging glue, not code.

- [ ] **Step 1: Generate the patch**

From the `kitten-lily/noctalia` fork, on the feature branch from Task 1:

```bash
git diff v5.0.0-beta.7-0-gc366a35ffc30b011d03fcd122bbe7d22f932fc57..feat/battery-auto-switch-profile \
  > 0001-battery-auto-switch-power-profile.patch
```

Copy it to `patches/noctalia/0001-battery-auto-switch-power-profile.patch` in a krytis worktree
(new worktree/branch for this task, per AGENTS.md worktree policy — `docs/skills/desktop.md`
§ "Carrying a local patch" documents the same pattern already used for
`patches/noctalia-greeter/0001-show-pam-info-cue.patch`, since removed once upstream merged it).

- [ ] **Step 2: Add the patch source to `elements/desktop/noctalia.bst`**

```yaml
sources:
- kind: git_repo
  url: github:noctalia-dev/noctalia.git
  track: v*
  ref: v5.0.0-beta.7-0-gc366a35ffc30b011d03fcd122bbe7d22f932fc57
- kind: patch
  path: patches/noctalia/0001-battery-auto-switch-power-profile.patch
```

- [ ] **Step 3: Verify the patch applies cleanly** before committing (per
  `docs/skills/desktop.md` § "Carrying a local patch"):

```bash
# from a checkout of noctalia at the pinned ref
patch -p1 --dry-run < patches/noctalia/0001-battery-auto-switch-power-profile.patch
```

- [ ] **Step 4: Build and boot-test**

```bash
mise run lint
mise run boot-test
```
Expected: PASS. Manually verify: `busctl get-property org.freedesktop.UPower.PowerProfiles
/org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile` before
and after a simulated AC unplug (`upower --dump` or physically unplugging in a VM/real hardware),
with the new toggle enabled in the Power tab.

- [ ] **Step 5: Add a row to [issue #483](https://github.com/starlit-os/krytis/issues/483)'s
  patch inventory table** for this new patch (element, patch path, "Own patch" or "Upstream
  backport" — this one is a fork-carried feature pending upstream review, closest to "own patch"
  in the existing table's taxonomy since it originates in the fork, not a backport of an already-
  merged upstream commit — note that distinction in the row), and update the removal condition
  once it's known (e.g. "delete once upstream noctalia-dev/noctalia merges an equivalent, if a
  PR is later authorized and opened").

- [ ] **Step 6: Commit**

```bash
git add patches/noctalia/0001-battery-auto-switch-power-profile.patch elements/desktop/noctalia.bst
git commit -m "feat(desktop): carry battery auto-switch power profile patch for noctalia

Closes #261
Inventory: #483

Assisted-by: <model>"
```

- [ ] **Step 7: Archive the plan and open the PR**

```bash
git mv docs/plans/2026-08-04-battery-power-profile-switch.md docs/plans/done/
git commit -m "docs(plans): archive battery power profile switch plan"
```

Open the PR (not draft — implementation is complete and locally verified), link to the CI run
per AGENTS.md's Verification section, and note in the PR body that the fork PR (if any) and this
krytis PR should merge together since the patch depends on the fork commit it was generated from.

## Self-Review Notes

- **Spec coverage:** every locked-in decision in `docs/design/power-profile-auto-switch.md`'s
  "Policy" section maps to a task: opt-in/default-off → Task 5; any-unplug trigger → Task 2/4;
  recorded-profile revert → Task 2; falcond gate → Task 3; fork-only → Task 1/6.
- **Known unknowns flagged, not hidden:** Task 4/5 explicitly require reading the real
  `application.h`/`.cpp` and settings-access code before writing glue code, because this plan was
  authored from targeted external reads of individual files (`upower_service.*`,
  `power_profiles_service.*`, `power_tab.cpp`), not a full checkout of the fork. Do not skip those
  read-first steps.
- **Idle-state `ACTIVE_PROFILE:` formatting** (Task 3 Step 4) is flagged as needing live
  verification — the falcond README's example output is a *held* snapshot, not confirmed for the
  idle case.
- **Patch tracking (issue #483):** Task 6 Step 5 is not optional — every `kind: patch` source in
  krytis is now required to have a matching inventory row, per `docs/skills/bst.md` § "Patch
  hygiene" and `docs/skills/desktop.md` § "Carrying a local patch".
