// krytis omp-seance — installed by mise run omp-seance:install
//
// oh-my-pi (omp) extension: reports omp session state to the seance terminal's
// sidebar through seance's existing `seance ctl pi-hook` command. Stage 1 of
// starlit-os/krytis#1018; design and verified facts are in
// docs/plans/2026-09-30-omp-seance-user-extension.md.
//
// Must stay an ES module: omp rejects the CommonJS `module.exports` shape that
// seance's own Pi wrapper writes ("does not export a valid factory function").

import { lookup } from "@oh-my-pi/pi-coding-agent/config/registry";

const env = process.env;
const ACTIVE =
	Boolean(env.SEANCE_SURFACE_ID) &&
	Boolean(env.SEANCE_SOCKET_PATH) &&
	env.SEANCE_OMP_HOOKS_DISABLED !== "1" &&
	// seance sets this when "Pi Agent Integration" is off; we drive pi-hook.
	env.SEANCE_PI_HOOKS_DISABLED !== "1";

// pi-hook session-end deletes $SEANCE_PI_SESSION_DIR when set. That directory
// belongs to seance's real Pi wrapper, never to us.
const CHILD_ENV = { ...env };
delete CHILD_ENV.SEANCE_PI_SESSION_DIR;

const HOOK_TIMEOUT_MS = 5000;
const SHUTDOWN_BUDGET_MS = 1500; // omp caps session_shutdown handlers at 2 s

// One serial queue: handlers enqueue and return without awaiting, so a tool
// call never waits on seance, while pre-/post-tool-use still arrive in order.
let queue = Promise.resolve();

function enqueue(hook, payload = {}) {
	queue = queue
		.then(
			() =>
				Bun.spawn({
					cmd: ["seance", "ctl", "pi-hook", hook],
					stdin: new Blob([JSON.stringify(payload)]),
					stdout: "ignore",
					stderr: "ignore",
					timeout: HOOK_TIMEOUT_MS,
					env: CHILD_ENV,
				}).exited,
		)
		.catch(() => {});
	return queue;
}

// Strip omp read selectors (`file.ts:50-100`, `file.md:raw`) so seance shows the file name.
function cleanPath(path) {
	return typeof path === "string" ? path.replace(/:(?:\d[\d+,\-]*|raw|img|conflicts)(?::raw)?$/, "") : undefined;
}

// omp's hashline edit carries the path inside its `input` text as `[PATH#TAG]`.
function editPath(input) {
	if (typeof input.path === "string") return cleanPath(input.path);
	const m = typeof input.input === "string" ? /^\[([^\]#]+)#/m.exec(input.input) : null;
	return m ? m[1] : undefined;
}

// Map omp tool calls onto the Claude-style names seance's toolDescription
// pretty-prints; anything else is shown verbatim.
function translate(name, raw) {
	const input = raw && typeof raw === "object" ? raw : {};
	switch (name) {
		case "read":
			return { tool_name: "Read", tool_input: { file_path: cleanPath(input.path) } };
		case "write":
			return { tool_name: "Write", tool_input: { file_path: cleanPath(input.path) } };
		case "edit":
			return { tool_name: "Edit", tool_input: { file_path: editPath(input) } };
		case "bash":
			return { tool_name: "Bash", tool_input: { command: input.command } };
		case "grep":
			return { tool_name: "Grep", tool_input: { pattern: input.pattern } };
		case "glob":
			return { tool_name: "Glob", tool_input: { pattern: input.pattern ?? input.path } };
		case "task": {
			const n = Array.isArray(input.tasks) ? input.tasks.length : 1;
			return { tool_name: "Agent", tool_input: { description: `${n} subagent${n === 1 ? "" : "s"}` } };
		}
		case "web_search":
			return { tool_name: "WebSearch", tool_input: { query: input.query } };
		default:
			return { tool_name: name, tool_input: {} };
	}
}

function messageText(message) {
	if (!message || !Array.isArray(message.content)) return "";
	return message.content
		.filter(b => b && b.type === "text" && typeof b.text === "string")
		.map(b => b.text)
		.join("");
}

function lastAssistantText(event) {
	if (event.last_assistant_message) return messageText(event.last_assistant_message);
	const messages = Array.isArray(event.messages) ? event.messages : [];
	for (let i = messages.length - 1; i >= 0; i--) {
		if (messages[i]?.role === "assistant") return messageText(messages[i]);
	}
	return "";
}

// seance's stop hook sends a richer completion notification (project + last
// message); silence omp's own unless the user chose a value explicitly.
function suppressNativeCompletionNotify(pi) {
	const setting = lookup("completion.notify");
	if (setting && !setting.isConfigured(pi.pi.settings)) setting.override(pi.pi.settings, "off");
}

// Every handler returns early when !ctx.hasUI: subagents (which share this
// extension and fire their own session_start/session_shutdown), `omp -p` and
// `--mode rpc --no-ui` are not tracked. A throw from a tool_call handler blocks
// the tool (omp fails closed), hence the blanket try/catch.
function guard(fn) {
	return async (event, ctx) => {
		try {
			if (!ctx?.hasUI) return undefined;
			await fn(event, ctx);
		} catch {}
		return undefined;
	};
}

export default function seance(pi) {
	if (!ACTIVE) return;

	// omp runs independent tool calls concurrently and emits every tool_call at
	// arg-prep time, before any of them finishes. Track what is still running
	// so the first tool_result doesn't reset the status to "Running" while a
	// sibling (a long bash, a pending approval) is still going.
	const inflight = new Map();
	const showInflight = () => {
		const last = [...inflight.values()].pop();
		if (last) enqueue("pre-tool-use", last);
		else enqueue("post-tool-use");
	};

	pi.on(
		"session_start",
		guard(() => {
			suppressNativeCompletionNotify(pi);
			// Clears a status left behind by an omp in this pane that was SIGKILLed.
			enqueue("session-end");
		}),
	);

	pi.on(
		"agent_start",
		guard(() => {
			inflight.clear();
			enqueue("prompt-submit");
		}),
	);

	pi.on(
		"tool_call",
		guard(event => {
			// omp's own ask.notify supplies the alert; seance shows unknown names verbatim.
			const payload =
				event.toolName === "ask" ? { tool_name: "Needs input" } : translate(event.toolName, event.input);
			inflight.set(event.toolCallId, payload);
			enqueue("pre-tool-use", payload);
		}),
	);

	pi.on(
		"tool_result",
		guard(event => {
			inflight.delete(event.toolCallId);
			showInflight();
		}),
	);

	pi.on(
		"tool_approval_requested",
		guard(event => {
			const payload = { tool_name: "Needs approval" };
			inflight.set(`approval:${event.toolCallId}`, payload);
			enqueue("pre-tool-use", payload);
		}),
	);

	pi.on(
		"tool_approval_resolved",
		guard(event => {
			inflight.delete(`approval:${event.toolCallId}`);
			showInflight();
		}),
	);

	// session_stop, not agent_end: omp never emits it for subagent sessions.
	// Must resolve to undefined — a { continue: true } result starts another turn.
	pi.on(
		"session_stop",
		guard((event, ctx) => {
			inflight.clear();
			enqueue("stop", { cwd: ctx.cwd, last_assistant_message: lastAssistantText(event) });
		}),
	);

	pi.on(
		"session_shutdown",
		guard(async () => {
			await Promise.race([enqueue("session-end"), Bun.sleep(SHUTDOWN_BUDGET_MS)]);
		}),
	);
}
