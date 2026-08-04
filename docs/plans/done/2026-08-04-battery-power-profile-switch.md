# Battery-Triggered Power Profile Switch — Execution Record

**Goal:** Auto-switch `power-profiles-daemon`'s `ActiveProfile` to `power-saver` on AC unplug and
back to the previously-active profile on AC reconnect, opt-in, without fighting falcond's
game-profile holds.

**Result: no C++/fork work needed.** This plan originally scoped a full noctalia fork patch
(new `PowerAutoSwitchController` class, settings toggle, meson tests — see git history of this
file for the original 6-task version). That plan was superseded the moment real implementation
started: forking `kitten-lily/noctalia` to the pinned ref and reading the actual source locally
(rather than via targeted external GitHub reads) surfaced a generic, already-shipped, GUI-exposed
hook system (`HookKind::BatteryDischarging`/`BatteryCharging`, `src/hooks/`) that implements the
exact mechanism needed. Full rationale: `docs/design/power-profile-auto-switch.md` §
"Superseding the fork-and-patch plan".

## What actually shipped

1. `kitten-lily/noctalia` fast-forwarded to `upstream/main` (`8d2c6881d..e41c99439`, fast-forward,
   zero fork-local commits lost — the fork had none to begin with). No further fork changes;
   the fork remains a clean mirror, no patch branch pushed.
2. `files/battery-power-profile-hook/battery-power-profile-hook.sh` — POSIX-ish bash script,
   invoked by noctalia as `<script> <discharging|charging>`. Reads/writes `ActiveProfile` via
   `busctl`, gates on `/tmp/falcond_status`, records/restores via a state file under
   `$XDG_RUNTIME_DIR`.
3. `elements/config/battery-power-profile-hook.bst` — ships the script to
   `/usr/libexec/krytis/battery-power-profile-hook.sh` (`kind: manual`, `runtime-minimal`
   depends only, same `strip-binaries: ''` + `strip-commands: [':']` pattern as
   `fido2-tasks.bst`/`flatpak-preinstall.bst`).
4. `elements/stacks/desktop.bst` — added `config/battery-power-profile-hook.bst` to `depends:`.
5. `docs/design/power-profile-auto-switch.md` — full design record, including the
   `battery_charging` vs `battery_plugged` naming trap discovered while reading
   `battery_hook_state.cpp`.
6. `docs/skills/desktop.md` — new lesson: check noctalia's Hooks system before assuming a
   feature needs a source patch.

## Verification performed

- `bash -n` on the script: syntax OK.
- Manual smoke test with a stubbed `busctl` in `PATH` (no live D-Bus/ppd available in the dev
  sandbox) covering: falcond-free discharging switch + state record, falcond-free charging
  restore, falcond-held discharging no-op (missing status file *and* populated
  `ACTIVE_PROFILE:`), already-`power-saver` discharging no-op (no double-record), and the usage
  error path. All matched expected `busctl` call sequences and state file contents.
- `mise validate`: full element graph resolves, `config/battery-power-profile-hook.bst` listed
  `buildable`, exit 0.
- `mise bst build config/battery-power-profile-hook.bst`: succeeds standalone; build log shows
  the exact `install -Dm755 battery-power-profile-hook.sh
  /buildstream-install/usr/libexec/krytis/battery-power-profile-hook.sh` command running and
  the artifact caching successfully.
- Not run: a full `mise lint`/`mise run boot-test` image build+boot (out of scope for this
  session; the change is additive — one new `kind: manual` leaf element with no dependency on
  anything version-sensitive — and independently build-verified above). Do this before merge per
  AGENTS.md's Verification gate.
- Not verified live: the actual D-Bus write against a running `power-profiles-daemon`, or a real
  AC unplug/replug against a live falcond `/tmp/falcond_status`. No hardware/VM with a battery
  was available in this session. Flagged as the one remaining gap before calling this
  production-verified, not just build-verified.
