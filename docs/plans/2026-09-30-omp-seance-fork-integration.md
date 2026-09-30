# omp sessions in seance — stage 2: `kitten-lily/seance` fork, carried as a krytis patch

**Issue:** #1018 (stage 2 of 3) · **Branch:** `1018-omp-seance-stage-2-plan`, stacked on
`1018-track-omp-sessions-in-seance` (#1020) · **Status: ready, not started.**

**Entry gate.** Do not start until the stage-1 evaluation
(`docs/plans/2026-09-30-omp-seance-user-extension.md` § 6. Evaluation period) has run for a while and its findings
are logged on #1018. Fold those findings into this plan before step 1. This plan was written
before stage 1 (#1020) merged, so it has not been tested against real use yet.

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

Checked in `/var/home/lily/Projects/seance` at `f3b7441`, the tag krytis pins.

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

- `patches/seance/omp-integration.patch`: `git format-patch --stdout v0.1.7..feat/omp-integration`
  from the fork, one file. It is applied as a `kind: patch` source **after** the `kind: tar`
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

- [ ] Fold stage-1 evaluation findings from #1018 into *Design*.
- [ ] `gh repo fork no1msd/seance --clone=false` under `kitten-lily`. Allowed without asking:
      AGENTS.md permits forking and branching. Enable Actions on the fork so upstream's
      `ci.yml` runs on pushes.
- [ ] Branch `feat/omp-integration` from tag **`v0.1.7`** (what krytis pins, so the exported
      patch applies to the release tarball). Stage 3 would rebase onto `main`.
- [ ] Build environment: this host is a krytis image with no `zig` or `pkg-config`. Use a
      `distrobox` on `ubuntu:24.04` (upstream CI's runner) with CI's `apt-get` list
      (`ci.yml:27-42`) and Zig 0.16.0. Build with `git submodule update --init` then
      `zig build`.

### 2. Implement in the fork

- [ ] Zig side: `ctl.zig`, `config.zig`, `default_config.toml`, `pane.zig`, `settings.zig`,
      `build.zig` per *Design*. Run `zig fmt`.
- [ ] `resources/bin/omp`, `resources/omp/seance.mjs`.
- [ ] README and CONTRIBUTING entries.

### 3. Tests in the fork

- [ ] `tests/omp_extension.test.mjs` (node, fake `pi` object and fake `seance` binary, modelled
      on `tests/opencode_plugin.test.mjs`):
      - no-op when `hasUI` is false;
      - plain sequence;
      - concurrent tools keep the running sibling's label;
      - `ask` and approval → `notification`;
      - `session_stop` payload;
      - `session_shutdown` drains within budget;
      - a failing or hanging `seance` never rejects a handler.
- [ ] `tests/test_omp.py` (modelled on `tests/test_opencode.py`, fake `omp` that records argv
      and env), covering:
      - every pass-through condition in the wrapper's step 2;
      - injection (`-e <prefix>/share/seance/omp/seance.mjs` first, `SEANCE_OMP_BIN`, `SEANCE_OMP_PID`,
        child `SEANCE_OMP_HOOKS_DISABLED=1`);
      - the exit code is preserved;
      - `EXIT` trap `omp-hook session-end` on a normal exit, a non-zero exit, and SIGTERM;
      - a prefix with spaces and quotes;
      - also runs the node suite.
- [ ] ctl-level cases against the real binary and a socket stub (the `tests/test_antigravity.py`
      fixture):
      - `omp-hook pre-tool-use` with `{"tool_name":"read","tool_input":{"path":"/a/b.txt"}}` →
        `workspace.set_status` value `Reading b.txt`, key `omp-<surface>`;
      - `notification` with `notification_type: "input"` → `Needs input` plus
        `notification.create` titled `oh-my-pi`;
      - `session-end` → `workspace.clear_status`.
- [ ] Optional real-omp test gated on `SEANCE_TEST_OMP` (like `SEANCE_TEST_OPENCODE`). Port
      stage 1's RPC harness (`mise/tasks/omp-seance/test`), including its subagent and
      print-mode scenarios, to drive the installed wrapper.
- [ ] `zig build`, `G_DEBUG=fatal-criticals GTK_A11Y=none xvfb-run -a zig build test`,
      `python3 -m unittest discover -s tests -v`, all green in the distrobox and on the fork's CI.

### 4. Live check (fork build, isolated instance)

seance is single-instance (`adw_application_new("com.seance.app", …)`), so launching the fork
build normally hands off to the running image seance. Run it isolated the way `src/e2e_test.zig`
does:

- `DBUS_SESSION_BUS_ADDRESS=disabled:`;
- a scratch `XDG_RUNTIME_DIR` / `XDG_CONFIG_HOME` / `XDG_CACHE_HOME`;
- `WAYLAND_DISPLAY` set to the **absolute** path of the real socket, because it is resolved
  relative to `XDG_RUNTIME_DIR` otherwise;
- the real `HOME`, so omp keeps its auth.

The GTK behaviour with an absolute `WAYLAND_DISPLAY` is `[INFERENCE]`; confirm it first.

Then repeat stage 1's step-4 table, with these expected differences:

- [ ] the sidebar reads **omp: …**;
- [ ] `ask` gives **omp: Needs input** plus a seance notification titled `oh-my-pi`, and no
      omp-native "Waiting for input" duplicate;
- [ ] concurrent tools keep the long tool's label;
- [ ] exactly one completion notification per turn (move the pane off-screen to count; seance
      drops notifications for a visible pane);
- [ ] a subagent turn never clears or idles the status early;
- [ ] `/exit`, Ctrl+C **and `kill -9`** all clear the status (via the `EXIT` trap);
- [ ] `omp --profile <p>` is tracked with no per-profile install;
- [ ] the Settings toggle off → a new pane runs `omp` untracked;
- [ ] `omp -p`, `omp commit`, and an `omp` nested inside omp's `!` shell are untracked;
- [ ] Pi labels (if Pi is installed) now read `Reading x` rather than `read`.

### 5. krytis PR

- [ ] New worktree/branch for #1018 stage 2.
- [ ] `patches/seance/omp-integration.patch` + `kind: patch` source in `seance.bst`.
- [ ] `seance-update` preserves patch sources; `mise run seance-update -- --regenerate` leaves
      the element byte-identical, `kind: patch` block included.
- [ ] Stage-1 removal and doc rewrite (see *krytis side*); `mise run docs-links`.
- [ ] `mise run bst build desktop/seance.bst` (with `--pull`/`--push` per `docs/skills/mise.md`).
      Check the artifact (`bst artifact list-contents`) has `usr/share/seance/bin/omp` and
      `usr/share/seance/omp/seance.mjs`.
- [ ] `mise run build` (includes lint + umbriel-config-validate) and `mise boot-test`. This one
      **does** change image content, so the AGENTS.md verification gate applies in full.
- [ ] After merge, on the updated image: re-run the step-4 checklist against the image's
      `/usr/share/seance/bin/omp`, and record the results in the PR / #1018.
- [ ] Skill entry for anything new (cross-repo exception: the fork commit message cites the
      krytis skill entry, or vice versa).

### 6. Hand-off to stage 3 (not part of this stage)

When stage 2 has run on the image for a while and holds up, ask whether to open the upstream
agent-support issue on `no1msd/seance` (CONTRIBUTING asks for the issue first), then a PR
rebased onto upstream `main`. Nothing is posted without that explicit yes.

## Risks

- **Patch rot on every seance bump.** `ctl.zig`, `pane.zig` and `settings.zig` are touched by
  every upstream agent addition, and `pane.zig`'s `env_vars` array size conflicts every time.
  Keep the patch as one commit, and rebase the fork on each `seance-update` before bumping the
  element. The `bst build` failure is the tripwire.
- **`omp-hook` / `toolDescription` diverging from upstream's choices** if upstream adds its own
  omp support meanwhile. Check upstream's changelog at each bump; if it lands, drop the patch
  in favour of it.
- **omp extension API drift** (event names, `ctx.hasUI` semantics for subagents, the
  `config/registry` subpath). The optional `SEANCE_TEST_OMP` test is the guard; run it after
  omp upgrades.
- **Nested-omp suppression hides a legitimate case.** A deliberately launched second omp in a
  sub-shell of an omp session is untracked by design. Revisit if that turns out to be wanted.
