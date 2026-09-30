# omp sessions in seance — stage 1: user extension

**Issue:** #1018 (stage 1 of 3) · **Branch:** `1018-track-omp-sessions-in-seance` ·
**Worktree:** `krytis.worktrees/feat/gh1018-track-omp-sessions-in-seance`

Show oh-my-pi (`omp`) sessions in seance's sidebar the way Claude Code, Codex and Pi already
appear: working, needs input, idle. Also send one completion notification per finished turn.

This stage uses **only a user-level omp extension**. It drives the `seance ctl pi-hook`
command that seance 0.1.7 already ships. Nothing changes in the seance build, in
`elements/desktop/seance.bst`, or in the image. omp itself is not image content either
(it is installed per user through mise). Stage 2 (a `kitten-lily/seance` fork carried as
a patch) and stage 3 (upstream) are out of scope here. Stage 2 starts only after the
evaluation in step 6.

## Non-goals

- Changing seance source, `seance.bst`, or `elements/stacks/desktop.bst`.
- A sidebar label other than **Pi**. `AgentConfig.name` is fixed per hook command, and
  `pi-hook` is the only one whose events fit omp.
- A Settings → Integrations toggle. The opt-out is an environment variable (see *Activation*).
- Tracking `omp -p` (print mode) or `--mode rpc --no-ui` runs.
- Anything against `no1msd/seance` or `can1357/oh-my-pi` (Upstream Gate).

## Verified inputs (2026-09-30, omp 18.4.3, seance 0.1.7)

Each item was observed on this machine. Probes were throwaway extensions run with
`omp -e <probe> --no-session --model haiku`.

| Fact | Evidence |
|---|---|
| A CommonJS extension (`module.exports = function (pi)`, the shape seance's `pi` wrapper writes) does **not** load | `Failed to load extension …: Extension does not export a valid factory function` |
| An ES module (`export default function (pi)`) loads, both as `.mjs` and as `.js` | probe events logged in both cases |
| The user extensions directory auto-scans only `.ts` / `.js` | oh-my-pi's `omp://extension-loading.md` § Inputs to extension loading |
| `import { lookup } from "@oh-my-pi/pi-coding-agent/config/registry"` resolves from an external file. `lookup("completion.notify")` returns `configured: false`, `provenance: "default"`, `get: "on"`. `.override(pi.pi.settings, "off")` then reads back `"off"` | probe log |
| `Bun.spawn` is available inside extensions | probe log `hasBun: true` |
| `session_stop` carries `last_assistant_message` (role `assistant`, text blocks) and an `AbortSignal` | probe log `stopRole: assistant, stopText: pong, hasSignal: true` |
| Tool names are lowercase and use omp argument names. `read` sends `{path}`, not `{file_path}` | probe log `tool: read, inputKeys: ["path"]` |
| In `--mode rpc` the main session has `hasUI: true`; a `task` subagent has `hasUI: false` for **every** event, including `session_start`, `tool_call`, `session_shutdown` | RPC trace below |
| `session_stop` fired once, for the main session only | RPC trace below |
| `seance ctl pi-hook <unknown>` prints `seance: unknown hook '<x>'` and exits 1 | `seance ctl pi-hook bogus` |

RPC trace of one turn that spawned one subagent (`hasUI` in brackets):

```
session_start[T] agent_start[T] tool_call:task[T]
session_start[F] agent_start[F] tool_call:wait[T]
tool_call:read[F] tool_call:read[F] tool_call:yield[F]
session_stop[T] session_shutdown[F] session_shutdown[T]
```

From seance source (`no1msd/seance@f3b7441`, `src/ctl.zig`):

- `pi-hook` accepts `session-start | session-end | prompt-submit | pre-tool-use | post-tool-use | stop`.
  `notification` returns "unknown hook" because `pi_agent.has_notification_hook = false`.
- `pre-tool-use` sets the status to `toolDescription(tool_name, tool_input)`. That function
  pretty-prints Claude's names (`Read` / `Edit` / `Write` + `file_path`, `Bash` + `command`,
  `Glob` / `Grep` + `pattern`, `Agent` + `description`, `WebSearch` + `query`) and **returns any
  other name verbatim**.
- `stop` reads `cwd` and `last_assistant_message`. It emits a "Completed in \<basename\>"
  notification and sets **Idle**.
- `session-end` clears the status key `pi-<SEANCE_SURFACE_ID>`. If `SEANCE_PI_SESSION_DIR` is set,
  it also deletes that directory.
- Nothing clears an agent status when its pane closes. Only a `session-end` call removes it.

## Design

### Files

| Path | Purpose |
|---|---|
| `scripts/omp-seance.js` | The extension (ESM). The one copy of the logic. Stage 2 lifts it into the fork's wrapper. |
| `mise/tasks/omp-seance/install` | `mise run omp-seance:install [--profile <name>] [--remove]`. Copies the extension into omp's agent dir. |
| `mise/tasks/omp-seance/test` | `mise run omp-seance:test [--model <m>]`. RPC-mode harness against a stub `seance`. Makes real model calls. |
| `docs/skills/desktop.md` | New section: tracking omp in seance (what this plan learned). |

Copy, not symlink. A symlink into a worktree dies when the worktree is pruned, and omp would then
log a load error on every start. The installed file begins with a
`// krytis omp-seance — installed by mise run omp-seance:install` marker. `install` refuses to
overwrite a `seance.js` that lacks the marker, and `--remove` deletes only a marked file.

The target directory is `${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/extensions/seance.js`. With
`--profile <name>` it is `$HOME/.omp/profiles/<name>/agent/extensions/seance.js`, matching omp's own
resolution in oh-my-pi's `omp://extension-loading.md`.

### Activation

The factory registers nothing unless all of these hold:

- `SEANCE_SURFACE_ID` and `SEANCE_SOCKET_PATH` are set (we are in a seance pane);
- `SEANCE_OMP_HOOKS_DISABLED !== "1"` (our opt-out, the name stage 2 will keep);
- `SEANCE_PI_HOOKS_DISABLED !== "1"` (seance sets this when **Pi Agent Integration** is off. We
  drive `pi-hook`, so we honour it).

Every handler additionally returns immediately when `ctx.hasUI` is false. That one check
excludes subagents, `-p` print mode and `--mode rpc --no-ui`.

### Event map

| omp event (main session only) | `seance ctl pi-hook …` | stdin payload | Effect in seance |
|---|---|---|---|
| `session_start` | `session-end` | `{}` | Clears a stale status left by a previous omp in this pane that was killed with SIGKILL |
| `agent_start` | `prompt-submit` | `{}` | **Running** |
| `tool_call`, `toolName === "ask"` | `pre-tool-use` | `{"tool_name":"Needs input"}` | **Needs input** (unknown names are shown verbatim) |
| `tool_call`, any other tool | `pre-tool-use` | translated, see below | Tool description |
| `tool_result` | `pre-tool-use` of the newest still-running sibling, else `post-tool-use` | sibling's payload / `{}` | That sibling's description, else **Running** |
| `tool_approval_requested` | `pre-tool-use` | `{"tool_name":"Needs approval"}` | **Needs approval** (only with `tools.approvalMode` ≠ `yolo`) |
| `tool_approval_resolved` | as `tool_result` | | |
| `session_stop` | `stop` | `{"cwd": ctx.cwd, "last_assistant_message": <text>}` | "Completed in \<project\>" notification + **Idle** |
| `session_shutdown` | `session-end` | `{}` | Status cleared |

`session_stop` is used rather than `agent_end` because it is main-session-only by construction.
The `session_stop` handler must return `undefined`; a returned `{continue: true}` would make omp
run another turn. `agent_start` is used rather than `input` because it also covers queued
follow-up and steering turns.

**In-flight tracking (added during implementation).** omp runs independent tool calls
concurrently and emits every `tool_call` at arg-prep time, before any of them finishes. The
first live run showed the naive map above going wrong: with `read` and `bash sleep` in one
response, `read`'s `tool_result` reset the sidebar to **Running** while the sleep still ran. The
extension keeps a `toolCallId → payload` map, cleared on `agent_start` and `session_stop`.
A `tool_result` re-reports the newest remaining entry and sends `post-tool-use` only when the
map is empty. A pending approval is an entry too, so it wins while its siblings finish.

The **Needs input** notification is omp's own: the `ask` tool calls `TERMINAL.sendNotification`
(gated by `ask.notify`, default `on`), and seance already surfaces it via `src/osc_parser.zig`.
This makes up for `pi-hook` having no `notification` subcommand, so stage 1 does get
Needs input after all. #1018's stage-1 section said otherwise and is corrected along with this plan.

### Tool translation (so `toolDescription` pretty-prints)

| omp tool | Sent as `tool_name` | `tool_input` |
|---|---|---|
| `read` | `Read` | `{file_path: input.path}` |
| `write` | `Write` | `{file_path: input.path}` |
| `edit` | `Edit` | `{file_path: input.path ?? <first "[PATH#" header in input.input>}` |
| `bash` | `Bash` | `{command: input.command}` |
| `grep` | `Grep` | `{pattern: input.pattern}` |
| `glob` | `Glob` | `{pattern: input.pattern ?? input.path}` |
| `task` | `Agent` | `{description: "<n> subagent(s)"}` |
| `web_search` | `WebSearch` | `{query: input.query}` |
| anything else | the omp name | `{}` |

The `edit` fallback covers omp's hashline edit shape, whose file path lives inside the
`input` text (`[PATH#TAG]` headers) rather than in a field. Any field that is missing just
yields the bare verb (`Editing`), never an error.

### Transport

- `Bun.spawn({ cmd: ["seance", "ctl", "pi-hook", hook], stdin: new Blob([json]), stdout: "ignore", stderr: "ignore", timeout: 5000, env })`.
  `timeout` was verified: a `sleep 10` child with `timeout: 500` exited 143 (SIGTERM), about
  1.1 s after spawn. The child env is `process.env` minus `SEANCE_PI_SESSION_DIR`, so
  `session-end` can never delete a real Pi wrapper's directory.
- **One serial queue per process** (`queue = queue.then(send).catch(() => {})`). Handlers enqueue
  and return without awaiting, so a tool call never waits on seance. Order is still preserved:
  a fire-and-forget `post-tool-use` could otherwise overtake its `pre-tool-use` and leave a
  stale tool label.
- Every handler body is wrapped in `try/catch`. A throw from a `tool_call` handler **blocks the
  tool**, because omp fails closed (oh-my-pi's `omp://extensions.md` § Constraints and pitfalls).
- `session_shutdown` is the one handler that awaits: `Promise.race([queue.then(() => send("session-end")), sleep(1500)])`.
  omp caps shutdown handlers at 2 s (`extensibility/extensions/runner.ts`, `sessionShutdownHandlerTimeoutMs`).

### Notification de-duplication

In the main session's `session_start` (not at factory time, so untracked `-p` runs keep omp's
own notification), if `lookup("completion.notify")` is **not** `isConfigured`, override it to
`"off"`. `pi.pi` is omp's package namespace, so `pi.pi.settings` is the same singleton omp's
event controller reads. `stop` then produces the only completion notification, the richer one
(project name + last message). A user who has set `completion.notify` explicitly keeps their
choice and gets both. `ask.notify` is left alone because it is the Needs-input notification
(see above). `error.notify` defaults to `off` and is left alone.

## Steps

### 1. Extension

- [x] Write `scripts/omp-seance.js` per *Design*, with the marker comment on line 1.
- [x] Load check without a model call:
      `echo '{"type":"get_state"}' | omp --mode rpc --no-session -e scripts/omp-seance.js`.
      Expect no `Failed to load extension` line. RPC mode runs the factory, answers `get_state`
      and exits on EOF (verified with a probe). **Not** `omp -p ""`: an empty print-mode
      prompt still starts a model turn.

### 2. `omp-seance:install`

- [x] `mise/tasks/omp-seance/install`: bash, `#MISE description=…` header, and `#USAGE` flags
      `--profile <name>` and `--remove`, following `mise/tasks/fido2/enroll-signing`
      (dev-host tooling, not image content). It must:
      - resolve the target directory as in *Files* and `mkdir -p` it;
      - refuse to overwrite an unmarked `seance.js`;
      - `install -m 0644` the file;
      - print the installed path.
- [x] `--remove` deletes only a marked file. It is a no-op with a message if the file is absent.
- [x] Re-running `install` is idempotent (compare checksums; report "up to date").
      Exercised against a temp `PI_CODING_AGENT_DIR`: fresh install, "up to date", `--profile`
      path, refusal to overwrite or remove a foreign `seance.js` (exit 1), remove, and remove
      when absent.

### 3. `omp-seance:test` (automated, real model calls)

A stub `seance` goes first on `PATH` in a temp dir. It appends one JSON line per call
(`{"argv": [...], "stdin": <parsed>}`) to a log and exits 0. The task drives
`omp --mode rpc --no-session --model "${usage_model:-haiku}" -e scripts/omp-seance.js` with an
inline `python3` JSONL driver:

1. send `prompt`;
2. read frames until `session_settled`;
3. close stdin, which triggers `session_shutdown`.

The stub environment is `SEANCE_SURFACE_ID=4242 SEANCE_WORKSPACE_ID=4242 SEANCE_SOCKET_PATH=/nonexistent`.
The prompts use a fixture file in a temp cwd. Assertions per scenario:

- [x] **Plain turn** ("read `note.txt` with the read tool, reply with its contents"):
      - the sequence starts `session-end, prompt-submit` and ends `stop, session-end`, with
        exactly one `stop` and one `prompt-submit`, and `post-tool-use` right before `stop`.
        With in-flight tracking, a `tool_result` can legitimately re-send `pre-tool-use`, so
        pre/post counts need not match;
      - a `pre-tool-use` payload is `{"tool_name":"Read","tool_input":{"file_path":<…>note.txt}}`;
      - `stop` carries the fixture cwd, and its `last_assistant_message` contains the fixture text.
- [x] **Subagent turn** ("use the task tool to have one subagent read `note.txt`"):
      - an `Agent` `pre-tool-use` was sent (the subagent really ran);
      - exactly one `stop`, second to last;
      - the only `session-end` calls are the first and the last line;
      - no `yield` `pre-tool-use`. `yield` is the subagent-only return tool, so seeing it means
        subagent events leaked. This is the regression guard for the subagent-shutdown bug in
        #1018.
- [x] **Opt-out**: `SEANCE_OMP_HOOKS_DISABLED=1` gives zero stub calls. So does
      `SEANCE_PI_HOOKS_DISABLED=1`. These, **outside seance** and a positive control use a
      model-free `get_state` RPC run.
- [x] **Outside seance**: `SEANCE_SURFACE_ID` unset gives zero stub calls.
- [x] **Print mode**: `omp -p` with the seance env set gives zero stub calls.
- [x] Exits non-zero, printing the stub log, on any failed assertion.

Result 2026-09-30, `--model haiku`: all 12 checks PASS (~46 s). **Mutation check:** with the
`ctx.hasUI` guard removed, three checks FAIL (the subagent `session-end` / `stop` ordering, the
subagent `yield` leak, and print mode). So the harness does catch the bug it exists for.

The task header states that it spends model tokens. The model is overridable with `--model`.

### 4. Live check in a seance pane (manual)

Run 2026-09-30 in a scratch seance workspace, driven with `seance ctl send` / `read-screen` and
`niri msg action screenshot-window`. **Notifications for a visible pane are dropped by seance
by design** (`NotificationCenter.emit` returns early when the pane is visible), so the pane was
moved off-screen (`select-workspace`) before counting.

- [x] `mise run omp-seance:install`, then open a **new** seance pane and run `omp`.
- [x] Read + `bash sleep` in one response: after `read` finished, the sidebar read
      **Pi: Running sleep 25** until the sleep ended, then **Pi: Idle**. Before in-flight
      tracking it read **Pi: Running** here. `Editing x` was not exercised live; the
      translation is shared with `Read` and covered by the stub trace.
- [x] Exactly one completion notification per turn: `list-notifications` showed
      `Completed in omp-live | live-check-alpha`, with no omp-native "Complete" beside it.
- [x] `ask`: **Pi: Needs input** in the sidebar plus omp's `omp: Waiting for input`
      notification. After answering: **Pi: Idle**.
- [ ] A turn with a subagent, live. Not run; covered by the `omp-seance:test` subagent
      scenario and its mutation check.
- [x] `/exit` clears the status. Exiting with Ctrl+C was not exercised.
- [x] `kill -9` of omp leaves the status stuck (**Pi: Idle** remained). Starting `omp` again in
      the same pane cleared it.
- [ ] `SEANCE_OMP_HOOKS_DISABLED=1 omp` / a non-seance terminal, live. Not run; both are
      covered by the model-free gating checks in `omp-seance:test`.

### 5. Docs and PR

- [x] New section in `docs/skills/desktop.md` covering:
      - the ESM-only loading;
      - the `ctx.hasUI` subagent gate, and why `session_stop` beats `agent_end`;
      - the fail-closed `tool_call` handlers;
      - the settings-override de-dup;
      - the `pi-hook` + verbatim-status trick for Needs input;
      - in-flight tracking and the model-free RPC load check.
- [x] Add a `docs/SKILL.md` routing row if the section does not fit an existing row.
- [x] Update #1018's stage-1 section: Needs input *is* available (via omp's own `ask`
      notification plus the status trick).
- [x] `mise run docs-links`.
- [x] Commit (`feat(omp): track omp sessions in seance via user extension`, `Refs #1018`) and
      open the PR. This PR changes no image input. Whether AGENTS.md's build/boot-test gate
      applies to dev-host tooling is a Merge Gate question for the human. The PR body carries
      the `omp-seance:test` output and the step-4 results instead.

### 6. Evaluation period

Use it for day-to-day work and log observations as comments on #1018. Watch for:

- a stale or wrong label with concurrent tools that in-flight tracking does not cover (e.g. a
  tool whose `tool_result` never fires);
- missing or duplicated notifications;
- sessions resumed with `/resume` or switched with `/new`;
- `--profile` sessions (need their own `install --profile`);
- anything that blocks or slows omp.

**Exit to stage 2** when the event map has held up and the remaining complaints are the stage-1
limits below. Stage 2 lifts `scripts/omp-seance.js` into the fork's `resources/bin/omp` wrapper;
at that point run `mise run omp-seance:install --remove` so the hooks don't fire twice.

## Known limits (fixed in stage 2)

- The sidebar says **Pi**.
- No Settings toggle, only `SEANCE_OMP_HOOKS_DISABLED=1`, or the Pi toggle, which also disables Pi.
- After `kill -9`, the status stays until the next omp starts in that pane or the pane closes and
  reopens.
- Per-profile installation.
- `wait`, `yield`, `todo` and other omp tools show raw names. Stage 2 moves the translation into
  `toolDescription`, where Pi benefits too.

## Risks

- **`pi-hook` is not a public interface.** A seance bump could change its subcommands or
  payload keys. The `omp-seance:test` stub would not catch that, since it stubs seance. Re-run
  step 4 after every `seance-update` while stage 1 is live.
- **omp extension API drift.** Event names or the `lookup` subpath could change in an omp
  update. `omp-seance:test` exercises the real omp, so run it after `mise` upgrades
  `oh-my-pi`.
- **Settings override scope.** `override` writes omp's in-memory runtime layer, which outranks
  project and global settings (only the setting's env var beats it). That is why it is applied
  only when `isConfigured` is false.
