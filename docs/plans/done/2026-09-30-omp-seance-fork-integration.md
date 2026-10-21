# omp sessions in seance — stage 2: `kitten-lily/seance` fork, carried as a krytis patch

**Issue:** #1018 (stage 2 of 3, krytis side) and kitten-lily/seance#1 (seance side) · **Branch:**
`1018-carry-seance-omp-integration` (krytis), `feat/omp-integration` (fork) ·
**Status: done 2026-10-21; archived with the krytis PR that carries it.** Results are recorded
inline under *Steps*.

**Entry gate (met 2026-10-21).** The owner gave the go after stage 1's evaluation; the stage 1
findings on #1018 were the omp 18.12.3 re-test and the `/new` / `/fork` probe (#1367). Both are
folded into *Design* and `docs/skills/desktop.md`.

Stage 1 drives seance's `pi-hook` from a user-installed omp extension. That leaves five limits:

- the sidebar is labelled **Pi**;
- there is no Settings toggle;
- a SIGKILLed omp leaves a stale status until the next launch;
- each `--profile` needs its own install;
- **Needs input** has no seance-side notification (it borrows omp's own `ask.notify`).

Stage 2 moves the integration into seance itself, the way seance already integrates Claude Code,
Codex, Pi, OpenCode and Antigravity:

- a wrapper, `resources/bin/omp`;
- a bundled extension, `resources/omp/seance.mjs`;
- an `omp-hook` agent in `src/ctl.zig`;
- a Settings toggle.

The work lives on a `kitten-lily/seance` fork branch. krytis carries it as a `kind: patch` source
on `elements/desktop/seance.bst`, and stage 1's user-level artifacts are removed in the same
krytis PR.

## Non-goals

- **Anything against `no1msd/seance`.** No issue, no PR, no comment. That is stage 3, and it
  needs explicit approval (AGENTS.md § Third-party repositories).
- Changing seance's behaviour for any other agent. The one exception is `toolDescription`,
  which learns lowercase tool names; that also improves Pi (see *Design*).
- Shipping omp in the image. omp stays a per-user mise install.

## Reference: what the seance source looks like (`no1msd/seance@v0.1.7`)

Checked in `/var/home/lily/Projects/seance` at `f3b7441`, upstream `main`. **Correction
(2026-10-21):** this used to call `f3b7441` "the tag krytis pins". It is not: `v0.1.7` is
`2138a31`, and `f3b7441` is one later commit that only touches `pkg/arch/` (`PKGBUILD`,
`.SRCINFO`). The source references below are unaffected.

| Concern | Where | Notes |
|---|---|---|
| Wrappers | `resources/bin/{claude,codex,pi,opencode,agy}` → `share/seance/bin/` | `build.zig:212-215` `installDirectory`. `pane.zig` prepends that dir to `PATH` in every pane. |
| Newest wrapper pattern | `resources/bin/opencode` + `resources/opencode/seance.mjs` (`8e28286`) | The template to follow; details below. |
| Agent table | `src/ctl.zig:1173-1255` `AgentConfig`, dispatch at `:142-146`, `cmdAgentHook` `:1349` | `pi_agent` has `has_notification_hook = false`. `printUsage` (`:2159`) lists Claude / Codex / OpenCode / Antigravity hooks but not Pi. |
| Tool label | `src/ctl.zig:1673` `toolDescription` | Only Claude names (`Read` + `file_path`, …); any other name is shown verbatim. |
| Config | `src/config.zig:66-72` fields, `:280-282` save, `:490-497` parse, `:695-710` parse test | Key `<agent>-hooks` under `[behavior]`. |
| Env to panes | `src/pane.zig:804` `var env_vars: [19]…`, `:831-848` `SEANCE_<AGENT>_HOOKS_DISABLED` | The array size must grow with every new env var. |
| Settings UI | `src/settings.zig:44-46` widgets, `:441-445` switch rows, `:697-702` handler | |
| Default config doc | `src/default_config.toml:40-41` | Only `opencode-hooks` / `antigravity-hooks` are listed. |
| Pane-close cleanup | `src/window.zig:396-403` | Only needed for per-surface cache dirs; the static-extension design below has none. |
| Tests | `tests/test_opencode.py` (wrapper + runs `node --test tests/opencode_plugin.test.mjs`), `tests/test_antigravity.py` (real `seance` binary against a Python socket stub), `tests/test_antigravity_pane.py` (all-hooks-disabled pane) | CI `.github/workflows/ci.yml` runs `python3 -m unittest discover -s tests -v`. |

The OpenCode integration is the model because it avoids the Pi wrapper's weak points:

- the plugin is a **static installed file** (`share/seance/opencode/seance.mjs`), not a
  per-surface generated one, so there is no cache dir to leak or delete;
- the wrapper resolves `seance` from its own prefix (`$WRAPPER_DIR/../../../bin/seance`,
  exported as `SEANCE_OPENCODE_BIN`), so it never calls a different seance found on `PATH`,
  and it works inside AppImages;
- `session-end` runs from an `EXIT` trap with explicit `INT` / `TERM` / `HUP` exit codes,
  preserving the agent's exit status;
- the plugin keeps one ordered queue and calls `execFile` with a timeout and `SIGKILL`.

## Design

### Files in the fork

| File | Change |
|---|---|
| `resources/bin/omp` | **new** wrapper (below) |
| `resources/omp/seance.mjs` | **new** extension (below); `build.zig` gains `b.installFile("resources/omp/seance.mjs", "share/seance/omp/seance.mjs")` next to the OpenCode line (`:218`) |
| `src/ctl.zig` | `omp_agent` `AgentConfig`, `omp-hook` dispatch, a `printUsage` section, lowercase names in `toolDescription` |
| `src/config.zig` | `omp_hooks: bool = true`, save/parse `omp-hooks`, extend the `[behavior]` parse test |
| `src/default_config.toml` | `# omp-hooks = true              # track oh-my-pi (omp) sessions (new panes)` |
| `src/pane.zig` | `env_vars` `[19]` → `[20]`; `SEANCE_OMP_HOOKS_DISABLED=1` when `!cfg.omp_hooks` |
| `src/settings.zig` | `omp_hooks` widget, switch row **oh-my-pi Integration**, handler branch |
| `tests/test_omp.py`, `tests/omp_extension.test.mjs` | **new** (see *Tests*) |
| `tests/test_antigravity_pane.py` | add `omp-hooks = false` to `config_extra`, which is meant to disable every integration |
| `README.md`, `CONTRIBUTING.md` | add omp to the auto-detected agent list and the integration notes; add the test commands |

### `omp_agent`

```zig
const omp_agent = AgentConfig{
    .name = "omp",                    // sidebar label: "omp: Running"
    .display_name = "oh-my-pi",       // notification title
    .usage = "usage: omp-hook <session-start|session-end|prompt-submit|pre-tool-use|post-tool-use|notification|stop>\n",
    .pid_env = "SEANCE_OMP_PID",
    .response = "OK\n",
    .status_key_prefix = "omp",
    .status_key_mode = .surface,
    .has_ask_user_handling = false,   // Claude-specific AskUserQuestion bookkeeping
    .has_notification_hook = true,    // ask + approvals → "Needs input" + notification
    .has_post_tool_hook = true,
    .session_dir_env = null,          // static extension: nothing per-surface to delete
};
```

`agentHookNotification` already does what omp needs. It reads `notification_type` and `message`
through `summarizeNotification`; "input"/"wait" categorise as **Waiting** and "permission" as
**Permission**. It sets **Needs input** and emits a notification titled `display_name`. The
Claude-worded fallbacks there ("Claude needs your attention") only fire when `message` is empty,
and the extension always sends one.

### `toolDescription` (also improves Pi)

Add lowercase branches before the verbatim fallback:

- `read` / `write` / `edit` → `tiFileDesc`, taught to read `path` as well as `file_path`;
- `bash` → `command`;
- `grep` / `glob` → `pattern`;
- `web_search` → `query`;
- `task` → `"Agent"`.

Pi's tools (`read`, `bash`, `edit`, `write`) use the same `path` / `command` names, so Pi's sidebar
labels improve with no change to Pi's wrapper. omp's hashline `edit` carries its path inside the
`input` text, so the **extension** normalises that one case to `{path}`. Everything else is sent
as omp emits it. This replaces stage 1's rename-to-Claude-names table.

### `resources/bin/omp`

Follows `resources/bin/opencode` line for line where the logic is the same.

1. Find the real `omp` on `PATH`, skipping the wrapper's own directory (the opencode loop,
   including its `-ef` self-check).
2. `exec` the real `omp` unchanged when any of these hold:
   - `SEANCE_SURFACE_ID`, `SEANCE_WORKSPACE_ID` or `SEANCE_SOCKET_PATH` is unset;
   - `SEANCE_OMP_HOOKS_DISABLED=1`;
   - any argument is `-h|--help|-v|--version|-p|--print|--export|--export=*`;
   - `--mode` / `--mode=` is anything but `text`;
   - `$1` is an omp subcommand.

   The subcommand list is `acp agents auth-broker auth-gateway bench browser-relay cleanse
   clip collab commit completions compress config dry-balance find gallery gc git grep
   grievances if-bench images install join login models play plugin predict ps read render say
   search setup share shell skill ssh stats stream tiny-models token toks ttsr update usage
   worktree`, taken from `omp --help` at 18.4.3. **Drift is harmless:** verified 2026-09-30,
   `omp -e /nonexistent.js stats --help` and `omp -e /nonexistent.js completions bash` still
   dispatch the subcommand. A subcommand missing from the list just receives an unused `-e`.
3. Resolve `SEANCE_OMP_BIN="$WRAPPER_DIR/../../../bin/seance"` and
   `EXTENSION="$WRAPPER_DIR/../omp/seance.mjs"`. Pass through if either is missing or
   `timeout 0.75 "$SEANCE_OMP_BIN" ctl ping` fails.
4. Export `SEANCE_OMP_BIN` and `SEANCE_OMP_PID=$$`. Export **`SEANCE_OMP_HOOKS_DISABLED=1`**
   for the child as well. This makes an `omp` started from inside omp (its bash tool, a `!`
   escape) pass straight through instead of claiming the pane's status. It also makes an
   installed stage-1 `~/.omp/agent/extensions/seance.js` go inert, because that file honours
   the variable, so hooks can never double up during the cutover. The bundled extension gates
   on `SEANCE_OMP_BIN`, **not** on this variable.
5. `trap 'timeout 3 "$SEANCE_OMP_BIN" ctl omp-hook session-end <<< "{}" >/dev/null 2>&1 || true' EXIT`,
   plus `trap 'exit 130' INT`, `143` TERM and `129` HUP, as in the opencode wrapper. Because the
   wrapper survives a SIGKILLed omp, the trap clears the status even then. That is stage 1's
   stale-status limit gone.
6. `"$REAL_OMP" -e "$EXTENSION" "$@" || rc=$?; exit "$rc"`. `-e` is honoured under
   `--no-extensions` and under any `--profile`, so per-profile installs are no longer needed.

### `resources/omp/seance.mjs`

Stage 1's `scripts/omp-seance.js`, with these changes:

- **Gate:** active only when `SEANCE_OMP_BIN`, `SEANCE_SOCKET_PATH`, `SEANCE_SURFACE_ID` and
  `SEANCE_WORKSPACE_ID` are set. There is no `SEANCE_*_HOOKS_DISABLED` check (the wrapper owns
  that) and no `SEANCE_PI_HOOKS_DISABLED`.
- **Transport:** `node:child_process` `execFile(SEANCE_OMP_BIN, ["ctl", "omp-hook", hook], {timeout: 750, killSignal: "SIGKILL", maxBuffer: 4096})`
  with the payload on stdin, exactly as `resources/opencode/seance.mjs` does. It replaces
  `Bun.spawn`: omp runs on Bun, which implements `execFile`, and the extension becomes
  unit-testable under plain `node --test`. Keep the single ordered queue.
- **Registry import:** `lookup` is loaded with a dynamic
  `import("@oh-my-pi/pi-coding-agent/config/registry")` inside `try`, so node tests (where the
  package does not resolve) skip de-duplication instead of failing to import.
- **Keep `ctx.hasUI` gating on every handler** (subagents / print mode), `session_stop` for
  completion, and the in-flight `toolCallId` map. All three are proven by stage 1's
  `omp-seance:test` and its mutation check.
- **`ask` → `notification`**: `{notification_type: "input", message: <first question text>}`.
  The `tool_result` for it goes through the in-flight logic as before.
- **Approvals → `notification`**: `tool_approval_requested` sends
  `{notification_type: "permission", message: "Approve <toolName>"}`; resolved goes through the
  in-flight logic.
- **Tool calls:** send `{tool_name: <omp name>, tool_input: <omp input>}` untranslated, except
  `edit`'s hashline path (see *toolDescription*).
- **De-duplication:** in the main session's `session_start`, override `completion.notify`
  **and** `ask.notify` to `off` when not `isConfigured`, since seance now owns both
  notifications. `error.notify` stays untouched.
- **Drop stage 1's startup `session-end`.** The wrapper's `EXIT` trap covers SIGKILL now.

### krytis side

- `patches/seance/omp-integration.patch`, written by `mise run seance-fork:export-patch` from
  the fork's commits only (a plain `git format-patch v0.1.7..feat/omp-integration` also
  exported upstream's `f3b7441`; see step 5). One file per fork feature branch (kitten-lily/seance#2, kitten-lily/seance#11 and
  kitten-lily/seance#3 add their own later, applied after this one in that dependency order). It is applied as a `kind: patch` source **after** the `kind: tar`
  source in `elements/desktop/seance.bst`, with a comment naming the fork branch and #1018 (the
  `ghostty.bst:44-49` precedent).
- **`mise/tasks/seance-update` must preserve the patch.** Today it rewrites the whole `sources:`
  block via `zig_zon.replace_sources_block` and would silently drop a `kind: patch`.
  `ghostty-update:113` already solves this with
  `preserved=zig_zon.extract_source_blocks(element_text, "patch")`; seance-update gets the same
  argument. Verify with `mise run seance-update -- --regenerate`: the patch block must survive
  byte-for-byte.
- **Remove stage 1** (clean cutover):
  - delete `scripts/omp-seance.js` and `mise/tasks/omp-seance/{install,test}`;
  - rewrite the `docs/skills/desktop.md` section (§ seance: tracking omp (oh-my-pi) sessions
    with a user extension (#1018)) around the wrapper and the patch;
  - update its `docs/SKILL.md` row;
  - move `docs/plans/2026-09-30-omp-seance-user-extension.md` to `docs/plans/done/`.

  **Before pulling this PR, run `mise run omp-seance:install --remove`**, because the task goes
  away with it. An installed stage-1 file left behind is inert anyway, thanks to the wrapper's
  `SEANCE_OMP_HOOKS_DISABLED=1`; it can be deleted by hand (it carries the
  `// krytis omp-seance` marker).
- The update path is unchanged: seance stays on `kind: tar` + `seance-update` (AGENTS.md
  § Update path gate, option (b)). The cost is that every seance bump now needs the fork branch
  rebased onto the new tag and the patch re-exported. A patch that no longer applies fails
  `bst build` at the source stage, which is loud rather than silent.

## Steps

### 1. Fork and branch

- [x] Fold stage-1 evaluation findings from #1018 into *Design*. `/new` and `/fork` fire
      `session_switch`, never `session_shutdown` (omp 18.12.3), so nothing changed in *Design*.
- [x] `gh repo fork no1msd/seance --clone=false` under `kitten-lily`. Allowed without asking:
      AGENTS.md permits forking and branching. Done 2026-10-21, with issues enabled, since the
      seance-side issues live there (kitten-lily/seance#1–#3). **The fork's workflows are
      disabled** (`ci.yml` and `release.yml`, by the owner on 2026-10-21), so upstream CI does not
      run on pushes: run its commands locally (step 3).
- [x] Branch `feat/omp-integration` from `upstream/main` = `f3b7441` (`v0.1.7` = `2138a31` plus
      one `pkg/arch/` commit), following
      `docs/skills/workflow.md` § Writing a feature on a fork: upstream-shaped from the first
      commit. Two commits: lowercase tool names in `toolDescription`, then the omp integration.
- [x] Build environment: a podman image, not a distrobox. `distrobox create` on `ubuntu:24.04`
      failed in its init: `update-locale: Error: invalid locale settings: LC_ALL=en_SE.UTF-8`
      (the host locale is not generated in the image). The image is
      `mise/lib/seance-build.Containerfile`, run by `mise run seance-fork:ci`.

### 2. Implement in the fork

- [x] Zig side: `ctl.zig`, `config.zig`, `default_config.toml`, `pane.zig`, `settings.zig`,
      `build.zig` per *Design*. `zig fmt --check` clean.
- [x] `resources/bin/omp`, `resources/omp/seance.mjs`. Deviations: the subcommand list was
      refreshed from omp 18.12.3 (`anonymize`, `auth`, `session` added) and `--alias` passes
      through; only label fields of a tool input are forwarded (`path`, `file_path`, `command`,
      `pattern`, `query`, `description`), never file bodies; an open `ask`/approval is
      re-reported as `Needs input` when a sibling tool finishes.
- [x] README and CONTRIBUTING entries.

### 3. Tests in the fork

- [x] `tests/omp_extension.test.mjs`: 9 tests, the cases below. The fake `seance` is `/bin/sh`:
      a Node one exceeded the 750 ms hook timeout under load and lost events.
      - no-op when `hasUI` is false;
      - plain sequence;
      - concurrent tools keep the running sibling's label;
      - `ask` and approval → `notification`;
      - `session_stop` payload;
      - `session_shutdown` drains within budget;
      - a failing or hanging `seance` never rejects a handler.
- [x] `tests/test_omp.py`: every pass-through condition, injection and env, exit code, the
      `EXIT` trap on normal/non-zero/SIGTERM/SIGHUP/SIGINT exits, a prefix with spaces and
      quotes, and the node suite.
- [x] ctl-level cases against the real binary and a socket stub (`Reading b.txt` under key
      `omp-<surface>`, `Needs input` + `notification.create` titled `oh-my-pi`, `session-end` →
      `workspace.clear_status`). Commit 1 has its own `tests/test_tool_description.py`.
- [x] Optional real-omp test, `OmpInstalledTests` gated on `SEANCE_TEST_OMP`: 3 tests passed on
      the host against omp 18.12.3 (read turn, subagent turn, print mode). The wrapper passes
      `--mode rpc` through, so those checks run omp with `-e <installed extension>` directly.
- [x] `mise run seance-fork:ci`: all suites passed (python suite `Ran 84 tests … OK
      (skipped=38)`; ghostty_integration 3, socket_server 2, shell_integration 3,
      keyboard_remaps 4, pane_close 9, fullscreen 3, ime 8). `zig build e2e` is opt-in: 2 of 24
      checks time out in the container on untouched `f3b7441` too. Mutation checks: dropping the
      wrapper's child `SEANCE_OMP_HOOKS_DISABLED=1`, its `TERM` trap or its `-p` pass-through,
      or the extension's in-flight logic or `hasUI` gate, each turns tests red.

### 4. Live check (fork build, isolated instance)

seance is single-instance (`adw_application_new("com.seance.app", …)`), so launching the fork
build normally hands off to the running image seance. Run it isolated the way `src/e2e_test.zig`
does:

- `DBUS_SESSION_BUS_ADDRESS=disabled:`;
- a scratch `XDG_RUNTIME_DIR` / `XDG_CONFIG_HOME` / `XDG_CACHE_HOME`;
- `WAYLAND_DISPLAY` set to the **absolute** path of the real socket, because it is resolved
  relative to `XDG_RUNTIME_DIR` otherwise;
- the real `HOME`, so omp keeps its auth.

Confirmed: GTK runs fine with an absolute `WAYLAND_DISPLAY`. Run 2026-10-21 against the bst
artifact of `desktop/seance.bst` with the patch (`bst artifact checkout`), real omp 18.12.3 and
haiku. A logging shim in place of the artifact's `usr/bin/seance` recorded every `omp-hook`
call; sidebar labels were read from `niri msg action screenshot-window` captures.

- [x] the sidebar reads **omp: Running sleep 15** during a `bash sleep 15`;
- [x] `ask` gives **omp: Needs input** plus one seance notification titled `oh-my-pi`
      ("Waiting: Do you want to continue?"), and no omp-native duplicate;
- [x] concurrent tools: `read` finishing during `bash sleep 6` re-sent the bash label;
- [x] exactly one completion notification per turn ("Completed in krytis"), with the pane on
      another workspace;
- [ ] a subagent turn live. Not run; covered by `OmpInstalledTests` and the node suite.
- [x] `/exit`, double Ctrl+C **and `kill -9`** all sent `session-end` (the `EXIT` trap; for
      `/exit` and Ctrl+C the extension's shutdown sends one too). bash prints a `Killed` line
      after `kill -9`, like the OpenCode wrapper.
- [x] `/new` sent nothing (no `session-end` mid-session).
- [ ] `omp --profile <p>` live. Not run; `-e` under `--profile` is covered by stage 1's
      evidence and the wrapper tests.
- [ ] the Settings toggle live. Not run; the pane env is covered by `test_antigravity_pane.py`
      and the config parse test.
- [x] `omp --version` passed through with no hook call; inside omp's bash tool
      `SEANCE_OMP_HOOKS_DISABLED` read `1`, so a nested omp passes through. The installed
      stage 1 `~/.omp/agent/extensions/seance.js` stayed inert (no `Pi:` row).
- [ ] Pi labels live. Pi is not installed here; covered by `tests/test_tool_description.py`.

### 5. krytis PR

- [x] New worktree/branch for #1018 stage 2: `1018-carry-seance-omp-integration`.
- [x] `patches/seance/omp-integration.patch` + `kind: patch` source in `seance.bst`, exported
      by the new `mise run seance-fork:export-patch`. Its first version exported
      `v0.1.7..feat/omp-integration` and wrote **3** commits: upstream's `f3b7441`
      (`pkg/arch/` checksum) came along, because the branch sits on upstream `main`, one commit
      past the tag. The task now exports `feat/omp-integration --not v0.1.7 upstream/main`: the
      two fork commits, `b7d7207` and `3c3e046`.
- [x] `seance-update` preserves patch sources: `mise run seance-update -- --regenerate` left
      the element byte-identical (`cmp`), `kind: patch` block included.
- [x] Stage-1 removal and doc rewrite (see *krytis side*); `mise run docs-links`.
- [x] `mise run bst --pull build desktop/seance.bst`: "Applying local patch:
      patches/seance/omp-integration.patch", build 5m55s. The image has
      `/usr/share/seance/bin/omp` (mode 0755) and `/usr/share/seance/omp/seance.mjs`.
- [x] `mise run build --pull --force` passed (lint 14 checks, umbriel-config-validate,
      cracklib-dict-check, portal-routing-check) and `mise run boot-test` PASSED, both on the
      image carrying the two-commit patch. The first `build` died with `no space left on
      device` while committing the sealed layer; `podman image prune -f` freed 29 GB.
- [ ] After merge, on the updated image: re-run the step-4 checklist against the image's
      `/usr/share/seance/bin/omp`, and record the results on #1018.
- [x] Skill entry: `docs/skills/desktop.md` § seance: omp (oh-my-pi) sessions through the
      carried kitten-lily/seance patch (#1018). The krytis commit cites the fork commit SHAs;
      the fork commits do not mention krytis.

### 6. Hand-off to stage 3 (not part of this stage)

When stage 2 has run on the image for a while and holds up, ask whether to open the upstream
agent-support issue on `no1msd/seance` (CONTRIBUTING asks for the issue first), then a PR
rebased onto upstream `main`. Nothing is posted without that explicit yes.

## Risks

- **Patch rot on every seance bump.** `ctl.zig`, `pane.zig` and `settings.zig` are touched by
  every upstream agent addition, and `pane.zig`'s `env_vars` array size conflicts every time.
  Keep each feature one commit on its own branch, keep the edits to those shared files minimal
  and additive, and rebase the fork on each `seance-update` before bumping the element. The
  `bst build` failure is the tripwire.
- **`omp-hook` / `toolDescription` diverging from upstream's choices** if upstream adds its own
  omp support meanwhile. Check upstream's changelog at each bump; if it lands, drop the patch
  in favour of it.
- **omp extension API drift** (event names, `ctx.hasUI` semantics for subagents, the
  `config/registry` subpath). The optional `SEANCE_TEST_OMP` test is the guard; run it after
  omp upgrades.
- **Nested-omp suppression hides a legitimate case.** A deliberately launched second omp in a
  sub-shell of an omp session is untracked by design. Revisit if that turns out to be wanted.
