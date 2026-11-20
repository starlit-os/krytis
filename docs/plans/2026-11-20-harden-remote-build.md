# Harden remote-build Transfer and Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `mise run remote-build` takes its Rex host only from operator config (no hard-coded
tailnet name), and survives a dropped image copy by retrying it up to 3 times.

**Architecture:** Both changes are confined to `mise/tasks/remote-build` and its section in
`docs/skills/mise.md`. The host lookup becomes a fail-fast check at the top of the task. The
"ship the image back" block is refactored into one `ship_attempt` function: it starts the
one-shot server, opens the forward, streams, and tears both down. A 3-attempt loop calls it,
and the image-ID check runs once after the loop.

**Tech Stack:** bash, `rex` CLI (`run`, `forward open/close`, `block close`), curl, zstd, podman, mise `[env]`.

**Spec:** GitHub issue #1689 (`gh issue view 1689 --comments`). The 2026-11-19 comment
fixes the placement: `~/Projects/StarlitOS/.mise.local.toml`.

## Global Constraints

- No default for `KRYTIS_REMOTE_HOST`. Unset or empty → exit 1 **before** any `rex`, `git fetch` or disk preflight.
- The error message shows exactly this TOML, and names the parent-directory placement:
  ```toml
  [env]
  KRYTIS_REMOTE_HOST = "https://<rex-host>"   # Rex label or address
  ```
- Placement to document: `~/Projects/StarlitOS/.mise.local.toml` (the parent of `krytis/` and `krytis.worktrees/`). Verified 2026-11-19 with `mise config ls` from a worktree (issue comment).
- No fnox fallback. Say why in the docs: the value is a tailnet name, not a secret, and the parent-directory file already reaches every worktree. That trap is what pushed `RUNNER_VPS_HOST` to fnox (`scripts/runner-vps-host.sh`).
- `rex-melog.werewolf-stonecat.ts.net` must not appear in `mise/tasks/remote-build` or `docs/skills/mise.md` afterwards. Other `werewolf-stonecat` hits (bst-cache in `project.conf` and the workflows) are out of scope.
- Retry: **3 attempts**. Each attempt restarts the one-shot server block **and** the `rex forward open`. Log each failed attempt's error. Keep the image-ID comparison after a successful load.
- Curl stall detection targets a *dead* stream, not a slow one: `--connect-timeout 30 --speed-limit 1024 --speed-time 300`, so a stream that moves under 1 KiB/s for 5 minutes fails. The measured runs (176–261 s for 7 GB uncompressed) don't show the first-byte latency of `podman save`, or the slowest legitimate interval in compressed bytes. So the threshold stays deliberately loose: it replaces an indefinite hang, it doesn't police throughput. Codex review, finding 4.
- The diff touches no BuildStream input or `Containerfile*`, so it needs no `mise run build` or `boot-test` (AGENTS.md § Verification exemption). Verify by running the task.
- Branch `1689-harden-remote-build-transfer-and-config`, worktree `krytis.worktrees/fix/gh1689-harden-remote-build-transfer-and-config`. The issue has no parent.

## Review Focus

1. **`set -e` is off inside a function called from `if`/`||`, and early returns skip teardown.** `if ship_attempt; then` makes bash ignore `set -e` for the whole body. So every fallible step must set `rc=1` explicitly. But a bare `return 1` would skip teardown, and the EXIT trap doesn't run between attempts, so the next attempt overwrites leaked handles. Structure it as `rc=0` → step (`|| rc=1`, and skip the later steps when `rc≠0`) → **one** unconditional `ship_teardown` → `return $rc`. The plan tests both a pipeline failure (missing image) and a setup failure (the forward never comes up).
2. **Close only this attempt's forwards.** Killing the `rex forward open` process can leave an *orphaned* forward that still accepts connections and then times out (`rex forward ls --help`). `--orphaned` is session-wide, and `krytis-build` is shared with other runs, so don't use it. Snapshot `rex forward ls -s "$SESSION" --json` IDs before `forward open`, diff after each poll iteration, and close exactly the new IDs (`rex forward close -s "$SESSION" <ids>`). Then `kill` + `wait` the forward process. Do this on every poll iteration that gives up, as well as at teardown.
3. **A server or `podman save` left running after a failed attempt.** The Python server loops until one transfer succeeds (`while not H.done`). After a dropped stream, `copyfileobj` raises before `p.wait()`, so its `podman save | zstd` child may outlive the request. Teardown closes the server block (`rex block close`) on every attempt, and the EXIT trap covers the current attempt's block. Nothing yet shows that closing a Rex block kills its descendants. The verification checks on the host: `pgrep -af 'podman save'` is empty after a failed attempt. If it isn't, have the handler kill `p` in a `finally:`.
4. **Empty `KRYTIS_REMOTE_HOST=""`.** Test `[ -z "${KRYTIS_REMOTE_HOST:-}" ]`, not `-v`. An empty assignment in a TOML file must fail the same way as an unset one.
5. **A partial `podman load` leaving a stale tag.** A load that died mid-stream must not let the ID check pass against the *previous* `localhost/krytis:latest`. The ID check stays after the loop and compares against `REMOTE_ID`. In `--ship-only` mode, where `REMOTE_ID` is empty, success has to come from the pipeline's exit status, never from "the tag exists".

---

### Task 1: Host from operator config, no default

**Files:**
- Modify: `mise/tasks/remote-build` (the `#MISE description` line, the header comment `Environment overrides`, and the `HOST=` line around line 21)
- Modify: `docs/skills/mise.md` § Building on melog: `mise run remote-build` (the paragraph starting "`--build-only` leaves the image on melog")

**Interfaces:**
- Produces: `HOST` (a non-empty string, a Rex label or address). Every later `r`/`rex -S "$HOST"` call uses it unchanged.

- [ ] **Step 1: Confirm the current default by inspection. Do not run the script.**

`grep -n 'KRYTIS_REMOTE_HOST:-' mise/tasks/remote-build` shows the hard-coded fallback. **Don't run the script bare as a baseline.** It reads `usage_build_only`, not `$1`, so `bash mise/tasks/remote-build --build-only` ignores the flag and would start a real remote build and transfer.

The test, which runs only after Step 2: with the flag parsing bypassed, the guard has to fire before anything else runs.
```bash
env -u KRYTIS_REMOTE_HOST usage_build_only=true bash mise/tasks/remote-build; echo "rc=$?"
KRYTIS_REMOTE_HOST= usage_build_only=true bash mise/tasks/remote-build; echo "rc=$?"
```
Expected: both print the TOML snippet and the `~/Projects/StarlitOS/.mise.local.toml` path to stderr, end with `rc=1`, and print nothing else. The guard sits on the first line after `set -euo pipefail`, so even a mistake elsewhere can't reach `rex` or `git`.

- [ ] **Step 2: Implement the check**

Replace the `HOST=` default with:
```bash
HOST="${KRYTIS_REMOTE_HOST:-}"
if [ -z "$HOST" ]; then
    cat >&2 <<'EOF'
remote-build: KRYTIS_REMOTE_HOST is not set. Add it to the .mise.local.toml in the
directory that holds both the checkout and krytis.worktrees/
(e.g. ~/Projects/StarlitOS/.mise.local.toml), so every worktree sees it:

  [env]
  KRYTIS_REMOTE_HOST = "https://<rex-host>"   # Rex label or address
EOF
    exit 1
fi
```
Put it straight after `set -euo pipefail`, before the `command -v rex` checks. Drop "(default: melog)" from the `#MISE description`. In the header comment, change `KRYTIS_REMOTE_HOST`'s "Default: melog's Rex server on the tailnet." to "Required; no default. Set in .mise.local.toml (see the error below)."

- [ ] **Step 3: Run Step 1's two test commands and confirm both exit 1 with the message**

Then confirm that resolution works from this worktree:
```bash
mise env | grep KRYTIS_REMOTE_HOST          # resolved from ~/Projects/StarlitOS/.mise.local.toml
mise config ls | grep StarlitOS/.mise.local.toml
```

- [ ] **Step 4: Docs**

In `docs/skills/mise.md` § Building on melog, replace the sentence "Set `KRYTIS_REMOTE_HOST` … (`https://rex-melog.werewolf-stonecat.ts.net`)." with a **Configuration** paragraph that says:
- `KRYTIS_REMOTE_HOST` is required and has no default. It goes in `[env]` of `~/Projects/StarlitOS/.mise.local.toml`, the parent directory. mise loads parent-directory config, so it reaches the main checkout and every `krytis.worktrees/*` worktree. A `.mise.local.toml` inside `krytis/` doesn't reach the worktrees: the same trap as § `RUNNER_VPS_HOST` in `docs/skills/ci-runner.md`. Verify the placement with `mise config ls` from a worktree.
- No fnox fallback, and why: it's a tailnet name, not a secret, and the parent file already covers worktrees.

The sentence "Its Rex server sits behind its own tailnet node, `rex-melog`" can stay: it gives a node label, not the FQDN.

- [ ] **Step 5: Verify and commit**

```bash
shellcheck mise/tasks/remote-build
mise run docs-links
git grep -n 'rex-melog.werewolf' -- mise/tasks/remote-build docs/skills/mise.md   # expect no output
env -u SSH_AUTH_SOCK git commit -am "fix(remote-build): require KRYTIS_REMOTE_HOST from .mise.local.toml" -m "Refs #1689" ...
```

---

### Task 2: Retry the image copy

**Files:**
- Modify: `mise/tasks/remote-build`, the "Ship the image back" section (from `served=$(r run … SERVE …)` through the `curl | zstd | podman load` line)
- Modify: `docs/skills/mise.md` § Building on melog. Add a bullet to "Each design choice exists for a reason".

**Interfaces:**
- Consumes: `HOST`, `SESSION`, `SHORT`, `IMAGE`, `SERVE` (unchanged Python), `r()`.
- Produces: `ship_attempt <n>`, which returns 0 only when `curl`, `zstd -dc` and `podman load` all exited 0. It always runs `ship_teardown` before it returns: it closes this attempt's forward IDs, kills and reaps the forward process, captures the server block's output into the attempt log, then closes the block. Globals `SERVE_BLOCK`/`FWD_PID` hold the *current* attempt's handles, for the EXIT trap.

- [ ] **Step 1: Write the failing tests**

(a) Pipeline failure. First confirm the tag is absent on the host: `rex -S "$KRYTIS_REMOTE_HOST" run -- podman image exists localhost/does-not-exist-1689` exits 1. Then run:
```bash
mise run remote-build --ship-only --image localhost/does-not-exist-1689; echo "rc=$?"
```
On the host, `podman save` fails, and `zstd -c` may still emit a valid empty frame, so `zstd -dc` can succeed locally. The failure the test relies on is `podman load`'s ("payload does not match…"). The real cause (`podman save`: image not known) lands in the server's Rex block, not in local stderr. The attempt log therefore has to include `rex capture` of the server block, taken before the block is closed.

Expected: three `remote-build: copy attempt N/3 failed:` lines, each followed by the tail of local stderr plus the server block's capture. Then `remote-build: image copy failed 3 times …` and `rc=1`. Afterwards: `rex -S … forward ls -s <session>` lists no forward this run created, `rex -S … block ls -s <session>` has no `ship …` block, and `rex -S … run -- pgrep -af 'podman save'` is empty.

(b) Setup failure. Temporarily set the forward-poll count to 1 with a nonexistent block (or kill the server block right after starting it). The attempt has to fail through `ship_teardown` and leave no forward or block behind. Remove the injection before committing.

- [ ] **Step 2: Implement `ship_attempt` and the loop**

- Install the EXIT/INT/TERM traps **before** the first attempt allocates anything.
- `ship_attempt n`: `rc=0`. Start the server block (`r run … --label "ship $SHORT"`); if that fails, `rc=1`. Snapshot the forward IDs. Run the existing 30×10 forward-open poll to get `URL`. Each poll iteration that gives up closes the forward IDs it created and reaps its process, and no `URL` means `rc=1`. If `rc` is still 0:
  `curl -fsS --connect-timeout 30 --speed-limit 1024 --speed-time 300 "$URL" | zstd -dc | podman load 2>>"$attempt_log"`
  (curl's and zstd's stderr also go to `$attempt_log`). Under `if ! …; then rc=1; fi` with `pipefail` on, a failure in any stage fails the attempt. Then `ship_teardown` unconditionally, then `return $rc`.
- `ship_teardown`: close this attempt's forward IDs, `kill` + `wait` `FWD_PID`, append `r capture -s "$SESSION" -b "$SERVE_BLOCK" --trim --unwrap | tail -n 5` to `$attempt_log`, `r block close`, then clear `FWD_PID`/`SERVE_BLOCK`/forward IDs. Every step is `|| true` and guarded by a non-empty handle, so the function is idempotent and the EXIT trap can call it too.
- Main: run the local `pgrep` wait once before the loop. Then `for n in 1 2 3`: on failure print `remote-build: copy attempt $n/3 failed:` plus `tail -n 5 "$attempt_log"`, and `sleep 5`. After 3 failures: `remote-build: image copy failed 3 times; the image is still on $HOST, retry with: mise run remote-build --ship-only --image $IMAGE` → `exit 1`. The `transfer took` timing covers the successful attempt only.
- `cleanup()` (EXIT trap) calls `ship_teardown` and removes the temp logs.
- Leave the image-ID comparison and the final messages after the loop unchanged.

- [ ] **Step 3: Run Step 1's tests (a) and (b) and see the expected failure with clean teardown**

- [ ] **Step 4: Test the real retry by closing the forward mid-copy**

Pick an image that already exists on the host (`localhost/krytis:latest`):
```bash
mise run remote-build --ship-only &      # or in a separate Rex pane
# wait until it prints "streaming", then confirm bytes are moving:
podman info --format '{{.Store.GraphRoot}}' | xargs du -sh   # grows between two reads ~10 s apart
rex -S "$KRYTIS_REMOTE_HOST" forward ls -s <session>          # note the active forward's ID
rex -S "$KRYTIS_REMOTE_HOST" forward close -s <session> <id>
```
Expected: `copy attempt 1/3 failed:` with the curl/zstd error. On the host, `pgrep -af 'podman save'` shows only attempt 2's process (or none, once it's done). Then attempt 2 succeeds, and the output ends with `remote-build: localhost/krytis:latest is sha256:… (copied from …)`. Then compare the IDs by hand: `podman image inspect --format '{{.Id}}' localhost/krytis:latest` locally and on the host (`rex -S … run -- podman image inspect …`) match. (`--ship-only` leaves `REMOTE_ID` empty, so the task's own check doesn't run.)

- [ ] **Step 5: Docs and skill learnings**

Add a bullet to "Each design choice exists for a reason" in `docs/skills/mise.md`:
- **The copy retries, the build doesn't.** Up to 3 attempts. Each one restarts the one-shot server and the forward, because after a dropped stream the server keeps listening with a half-finished `podman save`. curl aborts a stream that moves under 1 KiB/s for 5 minutes. That catches a dead tunnel, not a slow one. Teardown closes the forward IDs this attempt created, never `--orphaned`, because the `krytis-build` session is shared. A killed `forward open` leaves an orphaned forward that still accepts connections and times them out. A missing image fails at `podman load` locally, while the real error (`podman save`) is in the server's block, so the task captures that block before closing it. If all 3 fail, the image stays on the host for `--ship-only`. Note the 2026-11-19 `unexpected EOF` that motivated it (#1689).

Add the `set -e`-inside-`if` pitfall as one line in the same bullet, or in the existing bash-pitfalls spot in `docs/skills/mise.md` if one exists (grep `set -e`).

- [ ] **Step 6: Verify and commit**

```bash
shellcheck mise/tasks/remote-build
mise run docs-links
mise run build-changed --dry-run          # expect every path: not a BuildStream input
env -u SSH_AUTH_SOCK git commit -am "fix(remote-build): retry the image copy up to 3 times" -m "Closes #1689" ...
```
`git mv` this plan to `docs/plans/done/` in the same commit.

---

## PR

Body: link #1689, list the Task 1 and Task 2 test outputs (rc=1 message, 3-attempt failure, mid-copy retry with matching IDs), and say why the image gates don't apply (the `build-changed --dry-run` output). Before opening the PR, grep the open issues for the old hostname or default:
`gh issue list --state open --search 'rex-melog in:body'`.
