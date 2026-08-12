# Secrets Service: gnome-keyring vs. oo7

Krytis ships `gnome-keyring` (`gnome-build-meta.bst:core/gnome-keyring.bst`) as its
`org.freedesktop.secrets` provider and PAM-unlocked login keyring, wired in
`stacks/desktop.bst` and `elements/config/greetd-config.bst`. This doc tracks whether/when
to switch to [oo7](https://github.com/linux-credentials/oo7) instead, and why the last
attempt was abandoned.

## Why oo7 is attractive

- Memory-safe Rust implementation of the same `org.freedesktop.secrets` spec — fits the
  "Rust over C where equivalent" preference already applied elsewhere in this repo
  (`sudo-rs.bst`).
- Wayland-native, no legacy X11 assumptions.
- Scoped-authorization model for sandboxed apps, and a path to FIDO2-backed secrets —
  relevant to krytis's existing `pam_u2f` investment (#129, #133).
- **Fedora is adopting it as the system-wide default for F45** (KWallet and GNOME Keyring
  both replaced), FESCo-approved:
  [Changes/oo7_Secrets_Service_Provider](https://fedoraproject.org/wiki/Changes/oo7_Secrets_Service_Provider).
  This validates the technical direction — it is not a niche or abandoned project.

## History

- **#84** (2026-06-20): investigation opened.
- **#178** (2026-06-26, closed without merge): implementation attempt. Added
  `elements/desktop/oo7.bst`, swapped `pam_gnome_keyring.so` → `pam_oo7.so` on all three
  PAM lines in `greetd-config.bst`, built successfully. Abandoned after discovering the
  FIDO2 login gap below — the stated goal of unblocking #129/#133 wasn't actually achieved.
- **#189** (2026-06-27): rescued the skill-file learnings from #178's branch into
  `docs/skills/pam.md` before the branch was deleted, so the findings weren't lost even
  though the code wasn't merged.
- **2026-08-12**: re-validated #178's findings against current upstream `main`
  (post-0.7.0-alpha) and Fedora's F45 change proposal, prompted by that proposal surfacing
  in conversation. Findings below; details in `docs/skills/pam.md`.

## The blocker: FIDO2-only login leaves the keyring locked

`pam_oo7.so`'s `auth` phase needs a non-null `PAM_AUTHTOK` to stash a password for the
`session` phase to send to the daemon. A FIDO2-only login via `pam_u2f sufficient` never
populates `PAM_AUTHTOK` — pam_u2f doesn't set it, and it short-circuits the stack before
`pam_unix` would. Result: the oo7 Login collection stays locked for the entire session, and
since `oo7-daemon` only exposes the `default` alias on an *unlocked* collection, libsecret
clients that expect it (e.g. Ghostty) get an unexpected Prompt response and crash.

**This is not a regression** — `gnome-keyring`'s PAM module has the identical shape of gap
on FIDO2-only login, for the same reason (no password captured, nothing to unlock with).
Switching to oo7 does not make FIDO2 login worse. It also does not unblock #129/#133 the way
#178's PR description claimed, because the actual blocker survives the swap.

**Verified still open as of 2026-08-12**, both in code and in upstream's own tracker:

- `pam/src/lib.rs::get_auth_token_internal` on current `main` still returns
  `Err(PAM_SYSTEM_ERR)` on null `PAM_AUTHTOK`, and `pam_sm_authenticate` still treats that
  as "nothing to stash" rather than failing loudly.
- [oo7#506](https://github.com/linux-credentials/oo7/issues/506) is the upstream
  maintainer's own discussion of passwordless/FIDO2 keyring unlock, still active
  (last reply 2026-08-02). The maintainer is waiting on `credentiald` and a systemd PR to
  mature before deciding a direction — there is no fix in flight, just an open design
  question. Re-attempting #84 today would not change this outcome.

See `docs/skills/pam.md` § pam_oo7 for the full technical detail, plus two more findings
from the 2026-08-12 pass that don't block anything but matter for a future attempt:

- A restart of `oo7-daemon.service` mid-session silently re-locks an already-unlocked
  collection (no FD-store/credential-based resume yet — oo7#506, 2026-08-03 comment).
  Lower risk for krytis than for traditional Fedora, since bootc updates are reboot-driven
  rather than live in-place daemon restarts, but still worth a boot-test scenario.
- oo7 ships no ssh-agent component at all. Whatever provides `SSH_AUTH_SOCK` today
  (`~/.config/fish/conf.d/ssh-agent.fish`, currently pointed at gnome-keyring's
  `$XDG_RUNTIME_DIR/gcr/ssh`) has to keep existing independent of this migration — it isn't
  a "different path to switch to" question.
- Manual unlock UI on niri (secondary keyrings, `CreateCollection`, `ChangePassword`) needs
  `gcr-prompter` (`sdk/gcr-3.bst`) — oo7 has no niri/wlroots-native prompter, and a
  Wayland session always resolves to the GNOME (`org.gnome.keyring.SystemPrompter`) path,
  never the CLI fallback, since `WAYLAND_DISPLAY` counts as "has a display". `gcr-4`
  (`sdk/gcr.bst`) is **not** a substitute: GCR4 intentionally dropped the standalone
  prompter binary, moving that responsibility into each desktop shell (gnome-shell owns
  `org.gnome.keyring.SystemPrompter` itself via `js/ui/components/keyring.js`, built on
  GCR4 as a library) — niri has no equivalent shell-level component, so the legacy GCR3
  binary is the only viable path today. Krytis gets it only transitively through
  `gnome-keyring.bst`'s runtime dependency — `oo7.bst` must add `sdk/gcr-3.bst` explicitly
  or manual unlock silently breaks. **Confirmed as a live, currently-open failure mode on a
  peer non-shell compositor**: [pop-os/cosmic-epoch#3453](https://github.com/pop-os/cosmic-epoch/issues/3453)
  — `gcr-prompter` installed and present, but fails to activate after a mid-session daemon
  restart, hanging every libsecret caller rather than erroring cleanly. Treat this as a
  required boot-test scenario, not a theoretical edge case. Full detail in
  `docs/skills/pam.md` § Manual unlock on niri needs `gcr-3`.

## Decision

**Hold the oo7 migration itself.** Leave gnome-keyring in place. Do not re-attempt #84 until
both of the first two hold:

1. oo7#506 lands a resolution (passwordless/FIDO2 unlock has a real path), **and**
2. oo7 reports locked items from `SearchItems` so a locked collection can be discovered and
   unlocked rather than reported as "no such secret" — see § *New blocker found while
   testing* below. Unfixed on `main` as of 2026-08-12, and it is the stronger of the two:
   without it, condition 3 does not help, because the user is never given the chance to
   unlock, or
3. We explicitly decide the FIDO2-keyring-stays-locked gap is acceptable to ship. **This is no
   longer sufficient on its own.** It was reasonable while the gap looked like "the user
   unlocks manually"; testing showed applications are instead told the secret does not exist.

If reopening: reuse #178's BST/PAM mechanics (verified sound against current upstream —
`auto_start` flag real, three-stack `optional` wiring matches krytis's existing convention
line-for-line) but do **not** carry `use_authtok` onto the oo7 password-stack line without
checking whether pam_oo7 needs it — upstream's own example omits it, and #178 blindly ported
it from the gnome-keyring line. Also worth checking whether Fedora's Rawhide
`oo7-daemon.spec` has landed by then (queued at the time of the F45 proposal) — it will be a
more authoritative packaging reference than reverse-engineering upstream source.

**But pursue a native prompter in noctalia independently — it isn't gated on the oo7
decision.** The `gcr-3`/`gcr-prompter` fragility documented above (§ Manual unlock on niri)
affects the *current* gnome-keyring setup exactly as much as it would affect oo7 — niri has
no shell-level `org.gnome.keyring.SystemPrompter` provider either way, today. Fixing this is
valuable regardless of which Secret Service backend krytis ends up on, and de-risks a future
oo7 attempt as a side effect rather than being blocked by it.

## Path forward: a native prompter in noctalia

2026-08-12 direction: implement `org.gnome.keyring.SystemPrompter` natively in noctalia (the
shell, not noctalia-greeter — the greeter only runs pre-login; manual unlock and mid-session
daemon-restart prompts happen in the user's running niri session, which noctalia owns), with
the long-term goal of upstreaming it or shipping it as a noctalia plugin.

**Why noctalia is a good fit, not just the only option:**
- v5 (krytis is on `v5.0.0-beta.7`) is a from-scratch native C++23 rewrite with **no Qt or
  GTK dependency at all** — confirmed via upstream's own README and `libsodium.bst`/`stb.bst`
  comments in this repo. This removes the QML/Quickshell integration problem entirely; there
  is no JS/GObject-introspection bridge to fight.
- noctalia already depends on `libsecret`, `glib2`, and `sdbus-cpp`, and already ships a
  substantial Secret-Service-aware subsystem: `src/security/secret_store.{cpp,h}` (29KB) is a
  polling, cancellation-aware, async **client** of the secrets API (`SecretStoreCollectionState::
  Locked/Unlocked` is a first-class concept there already). A prompter is the same domain
  knowledge in the *server* role — natural extension, not a bolt-on.
- noctalia already has its own D-Bus-facing service architecture (bars/OSDs/notifications/tray)
  and, per its README, **a plugin system explicitly scoped for "third-party service
  integrations"** — a real, described upstream extension point, which is what makes "ship it
  as an extension" a credible option even before/instead of a full upstream merge.

**Protocol surface to implement** (read from GCR4's `gcr/org.gnome.keyring.Prompter.xml`,
2026-08-12 — small and stable, marked "internal" but unchanged in the ABI sense since GCR3):
- `org.gnome.keyring.internal.Prompter`: `BeginPrompting(callback: o)`, `PerformPrompt(callback:
  o, type: s, properties: a{sv}, exchange: s)`, `StopPrompting(callback: o)` — this is what
  noctalia registers on the session bus as `org.gnome.keyring.SystemPrompter`.
- `org.gnome.keyring.internal.Prompter.Callback`: `PromptReady(reply: s, properties: a{sv},
  exchange: s)`, `PromptDone()` — this is what noctalia calls back on the *client's* exported
  object (gnome-keyring, oo7, gcr, seahorse, pinentry-gnome3, etc. — anything that prompts
  through the standard mechanism).
- The `exchange` string is a `GcrSecretExchange` handshake (Diffie-Hellman-style key exchange
  so the secret isn't a plaintext D-Bus argument) — GCR4 kept this as a small standalone
  primitive (`gcr/gcr-secret-exchange.c`/`.h`, no UI, no removed dependency), so the plan is
  **link only that piece from `libgcr-4`** for wire compatibility rather than reimplementing
  the crypto handshake by hand — everything else (D-Bus service registration, dialog UI,
  session-bus ownership) is native noctalia code, consistent with the "no Qt/GTK" ethos.

**Known consumers to interop-test against, not just gnome-keyring:** oo7's `GNOMEPrompterProxy`
(`server/src/gnome/prompter.rs`, in play if #84 is ever reopened), GCR3's own `gcr-prompter`
(for anything that still expects the legacy binary specifically), and generic libsecret/pinentry
clients that fall back to `org.gnome.keyring.SystemPrompter` when no portal-based prompter is
available.

## Status: implemented on a fork (2026-08-12)

Built and verified on `kitten-lily/noctalia`, branch `feat/system-prompter`, commit
`ba821c7da`, based on upstream `main` at `8403cb987` (`v5.0.0-beta.8-36`). **No PR or issue
has been opened against `noctalia-dev/noctalia`** — per AGENTS.md's Upstream Gate that needs
an explicit instruction naming that action. The branch loses nothing by waiting.

What landed:

- `src/dbus/secrets/secret_prompter.{h,cpp}` — the service. Single-slot (matching
  `GCR_SYSTEM_PROMPTER_SINGLE`) with a waiting queue, client-disconnect teardown via
  `NameOwnerChanged`, and the full `BeginPrompting`/`PerformPrompt`/`StopPrompting` state
  machine on `sdbus-c++`, matching the existing agent idiom in `dbus/network/iwd_secret_agent.cpp`.
- `src/shell/secrets/secret_prompt_panel.{h,cpp}` — the UI, modelled on `shell/polkit/polkit_panel.cpp`.
- `shell.secret_prompter` config toggle, **off by default**: if gnome-shell or a live
  `gcr-prompter` already owns the name, noctalia must stay out of the way.
- `tests/secret_prompter_test.cpp` — runs on a private bus via `dbus-run-session`.

The plan above survived contact with the code, with one correction: only `GcrSecretExchange`
is linked from `libgcr-4`, as intended, but `gcr-4` also still ships `GcrSystemPrompter` — the
*server-side* machinery. It was not used (it requires implementing the `GcrPrompt` GObject
interface, i.e. exactly the GObject subclassing the native approach avoids), but its source is
the authoritative reference for the wire behaviour and was read line-by-line to build this.

### The bug that only the real client found

A hand-written test client passed while gcr's actual client failed. **The method reply to
`BeginPrompting` must reach the bus before the `PromptReady` that follows it.** Dispatching
`PromptReady` from inside the method handler — before sdbus writes the reply — makes gcr's
`GcrSystemPrompt` hit
`prompt_method_ready: assertion 'G_IS_SIMPLE_ASYNC_RESULT (self->pv->pending)' failed` and
then refuse the session with *"Another prompt is already in progress"*. gcr's own prompter
calls `g_dbus_method_invocation_return_value()` *before* `prompt_next_ready()`; the fix is a
deferred `sdbus::Result<>` on both `BeginPrompting` and `StopPrompting`. Same constraint
applies to any future re-implementation.

### Verification

`meson test`: 81/81 pass, including the new `secret_prompter` case. `clang-tidy` clean on the
new sources. The test's final case drives the prompter through **`GcrSystemPrompt`** — gcr's
real client, the one gnome-keyring and seahorse use — in a forked child, and asserts the typed
password arrives byte-for-byte after the `sx-aes-1` round trip. That is the interop claim:
verified against gcr's client state machine and real crypto, not against a mock.

### Confirmed against oo7 on a real image (2026-08-12)

Exercised on the `feat/oo7-prompter-testbed` branch — oo7 as the Secret Service, noctalia's
native prompter, and **no `gcr-3` in the image at all**.

**oo7 does drive this exact interface.** With `oo7-daemon` running and *nothing* owning the
prompter name, a `secret-tool store` against the locked `Login` collection put this on the
session bus before giving up:

```
3  org.gnome.keyring.SystemPrompter
1  org.gnome.keyring.internal.Prompter
1  BeginPrompting
1  /org/gnome/keyring/Prompter
1  /org/gnome/keyring/Prompt/p        <- oo7's own exported Callback object
```

That is precisely the protocol `secret_prompter.cpp` implements, so oo7's `GNOMEPrompterProxy`
is no longer an assumption — it is observed traffic. It also means the prompter is not
optional decoration: it sits on the only path oo7 has to ask for a password.

**Without a prompter the caller hangs — it does not error.** The same `secret-tool store` sat
there until killed at 25s; oo7 logged only `Client :1.2 connected` and, on the timeout,
`disconnected`. This is pop-os/cosmic-epoch#3453 reproduced on krytis's own image rather than
inferred from someone else's bug report, and it is the strongest argument for shipping a
shell-owned prompter: the failure mode of *not* having one is an unkillable-looking hang in
every libsecret caller, not a clean error anyone would think to report.

**On the booted VM the loop closes.** The unlock prompt was drawn by noctalia (confirmed via
`busctl --user list` showing noctalia owning `org.gnome.keyring.SystemPrompter`, with oo7
owning `org.freedesktop.secrets` and `desktop/oo7.bst` in `/usr/manifest.json`), and after it
was answered noctalia successfully stored a secret through the Secret Service — which is only
reachable with the collection unlocked. So the whole chain ran: oo7 → `BeginPrompting` →
noctalia's panel → `sx-aes-1` exchange → unlock → store.

Still not exercised: `ChangePassword`, and the mid-session `systemctl --user restart
oo7-daemon` re-lock scenario.

### New blocker found while testing: a locked oo7 collection is invisible, not prompt-worthy

**This is the most consequential finding of the whole exercise, and it is not oo7#506.**

`secret-tool lookup` against a *locked* collection returns "not found" in 0s. It does not
prompt. Reproduced end to end on the testbed image by unlocking through oo7's PAM socket,
storing a secret, locking, and reading back:

```
stored; lookup => topsecret          # unlocked: works
Locked: b true                       # lock really took
SearchItems -> aoao 0 0              # zero unlocked AND zero locked
lookup -> rc=1, 0s, no prompt
```

The item demonstrably exists — it was just read. oo7 simply does not report it. Source, in
`server/src/collection/mod.rs::search_inner_items`, identical on the 0.6.0 tag and on current
`main`:

```rust
if keyring.is_locked() { return Ok(Vec::new()); }
```

It cannot do better as designed: oo7 encrypts item *attributes* at rest, and matching needs
the collection key (`file_item.matches_attributes(attributes, key)`). gnome-keyring keeps
attributes searchable while locked, which is exactly what lets a client discover a locked item
and ask for it to be unlocked.

The Secret Service API returns `SearchItems(unlocked, locked)` as two arrays *precisely* so a
client can unlock the second group. oo7 always returns the second array empty, so libsecret's
`on_lookup_searched` falls through to its "nothing found" branch and never requests an unlock.

**Why this outranks the FIDO2 gap.** The gap was previously characterised as "the keyring
stays locked, and the user unlocks it manually". That is too generous. The real behaviour is
that applications are told **the secret does not exist** — a silent wrong answer, not an error
and not a prompt. A working prompter does not rescue it, because nothing ever asks for one.
`store` still prompts correctly (writing needs the collection open), so the failure is
read-shaped and easy to miss in casual testing.

This is arguably the real mechanism behind the Ghostty instability recorded in
`docs/skills/pam.md` § *oo7 `default` alias requires an unlocked collection*, and it is
**unfixed upstream as of 2026-08-12**. It should be treated as a second, independent hold
reason alongside oo7#506 — accepting the FIDO2 gap is no longer sufficient to unblock #84,
because even a user who is willing to unlock manually gets no opportunity to.

Not reported upstream: AGENTS.md's Upstream Gate requires an explicit instruction before
opening anything against `linux-credentials/oo7`.

## Revisit trigger

Re-read this doc and oo7#506 before starting any new #84 attempt. If oo7#506 is still open
with no maintainer-endorsed direction, don't start — leave a comment on #84 instead noting
the re-check and moving on.
