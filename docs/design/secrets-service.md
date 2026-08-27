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

**Superseded 2026-08-14: the migration ships, with the known bugs accepted.** The history
below is kept because it is the reasoning the decision was taken against, not because it is
still in force.

### Current decision — ship oo7, accept the outstanding bugs

Deliberate call, made with the failure modes measured rather than guessed. Krytis moves to
oo7 + noctalia's native prompter now, carrying two known defects and two workarounds:

| Accepted | Consequence | Workaround in tree | Exit condition |
|---|---|---|---|
| **#585** — a locked collection reads back as "no such secret" | libsecret callers get a silent wrong answer, not a prompt | FIDO2 login disabled, so `pam_oo7 auto_start` unlocks at login and the collection is never locked | upstream reports locked items from `SearchItems` |
| ~~**#588** — prompter detection picks the CLI prompter~~ **RESOLVED 2026-08-27** | ~~every unlock prompt fails with `CliPrompter does not exist`~~ | none — `patches/oo7/prompter-detect-session-type.patch` deleted | **met.** Upstream `f6a8624a` (oo7#558) added a `from_logind` → `from_environ(pid)` → `from_systemd_user_environment()` cascade that covers a peer logind cannot attribute. Verified unpatched at ref `e830f53d` with `mise run oo7-prompter-test` |
| **oo7#506** — no FIDO2/passwordless unlock path | FIDO2 login cannot unlock the keyring at all | — (this is *why* FIDO2 login is off) | upstream direction exists |
| **noctalia fork pin** | `bst source track` follows a branch head, not the `v*` glob | — | prompter upstreamed to `noctalia-dev/noctalia` |

**The residual risk, stated plainly.** The #585 workaround is not airtight: it removes the
*usual* way the collection ends up locked, not the only one. A mid-session
`systemctl --user restart oo7-daemon`, an explicit `secret-tool lock`, or an oo7 crash all
re-lock it, and from that point every read returns "no such secret" until the session is
restarted. There is no warning and no prompt. If a user reports "my saved passwords vanished",
check `Locked` on the collection before anything else.

The fork pin is the other live risk: it is a moving target that `bst source track` will follow,
so an unrelated commit on that branch can change what krytis ships. Pin discipline matters more
than usual until the prompter is upstreamed.

### History: the hold that preceded this (2026-06 → 2026-08-14)

The migration was held from #178 until now. The bar was:

1. oo7#506 lands a resolution (passwordless/FIDO2 unlock has a real path), **and**
2. oo7 reports locked items from `SearchItems` so a locked collection can be discovered and
   unlocked rather than reported as "no such secret", or
3. an explicit decision that the FIDO2-keyring-stays-locked gap is acceptable to ship.

Neither (1) nor (2) has happened. The migration proceeds on (3) — taken knowingly, with the
gap's real shape understood (applications are told the secret does not exist, rather than
being offered a manual unlock) and with FIDO2 login disabled specifically so that shape never
materialises in normal use.

Mechanics carried over from #178, verified against current upstream: the `auto_start` flag is
real and the three-stack `optional` wiring matches krytis's existing convention line-for-line.
`use_authtok` was **not** carried onto the oo7 password line — upstream's own example omits it
and #178 had copied it from the gnome-keyring line unchecked. Fedora's Rawhide
`oo7-daemon.spec`, if it has landed, remains a more authoritative packaging reference than
reverse-engineering upstream source.

**But pursue a native prompter in noctalia independently — it isn't gated on the oo7
decision.** The `gcr-3`/`gcr-prompter` fragility documented above (§ Manual unlock on niri)
affects the *current* gnome-keyring setup exactly as much as it would affect oo7 — niri has
no shell-level `org.gnome.keyring.SystemPrompter` provider either way, today. Fixing this is
valuable regardless of which Secret Service backend krytis ends up on, and de-risks a future
oo7 attempt as a side effect rather than being blocked by it.

## fdsdk 26.08 forces the oo7 swap regardless of this decision

**Verified 2026-08-13.** The Decision above only holds on krytis's current freedesktop-sdk
`25.08` baseline, where `gnome-keyring.bst` and `sdk/gcr-3.bst` both still exist upstream and
the hold is a real, deliberate choice. That stops being true once `#305` (the fdsdk `26.08`
bump) lands:

- `gnome-build-meta` `master` deleted `gnome-keyring.bst` entirely (upstream commit
  `528af16d74`, "Replace gnome-keyring with oo7"). `elements/stacks/desktop.bst` on the
  `chore/gh305-upgrade-fdsdk-26-08` branch already documents this — the oo7 swap there is
  **forced by the SDK bump, not a #84 decision**: "This is NOT the same as voluntarily
  adopting oo7."
- `sdk/gcr-3.bst` is gone too, confirmed absent (not just unreferenced) from the same
  junction — so `gcr-prompter` isn't available as a fallback on fdsdk `26.08` either. This is
  ahead of the *official* GNOME timeline (GNOME 51 Flatpak runtime drops gcr-3 end of 2026,
  gcr-3 support continues through GNOME 50 / April 2027) — `gnome-build-meta` tracking
  `master` is already past that milestone independent of the runtime schedule.
- Consequence: `#305` as it currently stands ships with **no manual-unlock UI at all**, not
  merely a fragile one. `elements/desktop/noctalia.bst` on that branch is still pinned to
  plain upstream `v5.0.0-beta.7` — the fork pin + `gcr-4` dependency from this doc's Path
  forward section (and PR #574) has not been ported there.
- The oo7 blockers documented in this doc are **not fixed** at the exact oo7 commit `#305`
  pins (`v0.6.0-alpha-219-g06b9cfe0`, via `gnome-build-meta`'s `oo7.inc`) — verified
  `server/src/collection/mod.rs::search_inner_items` still returns `Ok(Vec::new())` for a
  locked collection at that ref, identical to the finding above.

**Practical effect on "hold #84":** it only controls whether krytis *chooses* oo7 on the
SDK line it's on today. It does not prevent oo7 from arriving via `#305` as an SDK-forced
side effect — that happens either way, on its own timeline, independent of this Decision.

**Not yet actioned:** porting PR #574's `noctalia.bst` change (fork pin + `gcr-4` dependency)
onto `chore/gh305-upgrade-fdsdk-26-08` before that branch merges — there it is load-bearing
(no `gcr-prompter` fallback exists to decline gracefully behind), not the optional/reversible
experiment it is on `main`. Recorded on issue #305 rather than done as part of this pass.

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

**Verified 2026-08-13: linking `gcr-secret-exchange` does not pull in GTK.** Checked because
the concern is legitimate at face value — krytis's pinned `sdk/gcr.bst` (gnome-build-meta,
gcr-4.4.0.1) has `depends: - sdk/gtk.bst` (GTK4 4.22.4) unconditionally, and `sdk/gtk.bst`'s
own closure is large (at-spi2-core, gdk-pixbuf, glycin, graphene, gstreamer+base+bad, pango,
cups, hicolor-icon-theme, libepoxy, libxkbcommon, vulkan-icd-loader, wayland+protocols). That
dependency is real but not structural — traced against upstream gcr's actual
`meson.build`/`gcr/meson.build`/`tools/meson.build` (main, matches the pinned 4.4.0.1):
- The `gtk4` meson option (`meson_options.txt`, default `true`) only gates
  `tools/viewer/meson.build`'s `gcr-viewer-gtk4` — a standalone certificate-viewer
  **executable**, not linked into `libgcr-4.so`. `-Dgtk4=false` drops GTK4 from the build
  closure entirely; nothing else in the tree references `gtk4_dep`.
- There is no `gtk3` option or code path in current upstream source at all — the
  `libgcr-4-gtk3.so` line in krytis's pinned `gcr.bst` split-rules is stale relative to
  4.4.0.1, that file isn't produced by the current meson build.
- `gcr-secret-exchange.c` itself (`gcr/meson.build`'s `gcr_lib` target) only includes gcr's
  internal `egg/egg-{crypto,dh,fips,hkdf,padding,secure-memory}.h` — the DH key-agreement
  math is gcr's own vendored `libegg`, not GTK. `gcr_lib`'s full dependency list is
  `[glib_deps, p11kit_dep, libegg_dep, gck_dep]`; `libegg`'s only non-glib dependency is
  `crypto_deps` (libgcrypt by default, or gnutls).
- p11-kit and libgcrypt are already in krytis's base system (`overrides/systemd-base.bst`,
  pulled in for cryptsetup), so linking `libgcr-4.so` adds only itself plus `gck` (gcr's thin
  PKCS#11 GObject wrapper — glib + p11-kit only) to the closure. No new crypto backend, no new
  p11-kit.

**Correction 2026-08-13: the GTK4 pull is moot for krytis anyway.** The above was worth
verifying on principle, but krytis's OCI image already carries GTK4 unconditionally through
several unrelated elements — `elements/desktop/niri.bst` (the compositor itself),
`elements/desktop/ghostty.bst`, `elements/desktop/gtk4-layer-shell.bst`, `core/nautilus.bst`
(`stacks/desktop.bst`), and even **`elements/desktop/noctalia.bst`'s own `depends:` already
lists `gnome-build-meta.bst:sdk/gtk.bst`** — despite noctalia's C++ source having no GTK4
build-time reference at all (only a shell template, `assets/templates/gtk/apply.sh`, that
writes a `gtk.css` import for theming *other* GTK apps — no linking). So there is no
dependency-count argument for forking `gcr.bst` with `-Dgtk4=false`; the whole GTK4 stack is
already in every krytis image regardless of this feature. The finding above matters only for
**noctalia's own build purity** as a fork (its README's "no Qt or GTK dependency" claim) —
linking `gcr-secret-exchange` keeps that true at the noctalia-binary level even though the
krytis *image* was never going to avoid GTK4 either way.

**Decided against forking `gcr.bst` at all.** `-Dgtk4=false` would only skip building the
unused `gcr-viewer-gtk4` binary — smaller build sandbox for that one element, nothing shipped
differently (image-level GTK4 footprint is unchanged either way, per above). Against that:
forking the element means krytis now owns tracking gcr's upstream releases for that override
independently of `gnome-build-meta.bst`, and keeping `meson-local` flags valid across gcr
version bumps — real ongoing maintenance for zero image benefit. **Depend on `sdk/gcr.bst`
unmodified** when this gets implemented; the `gcr-secret-exchange` link works the same either
way since `libgcr-4.so` never pulled in GTK4 to begin with. Also opened
[#573](https://github.com/starlit-os/krytis/issues/573) to audit for other elements carrying
dependencies the pinned upstream source doesn't actually need (seeded with the
`noctalia.bst`/`sdk/gtk.bst` finding above) — general dependency hygiene, not specific to gcr.

**Distro packaging: `gcr-4` devel package per distro (verified 2026-08-13).** The prompter
commit added `gcr_dep = dependency('gcr-4')` to `meson.build` (unconditional — no meson
option gates it, since `shell.secret_prompter`'s off-by-default is a runtime toggle, not a
build-time one) but didn't touch the README's per-distro install commands, so a packager
following the README as of `ba821c7da` would hit an unadvertised `pkg-config` failure.
Checked each distro's actual packaging (not just guessed names) and pushed the fix directly
to the fork branch (`kitten-lily/noctalia@fcaf05e84`):

| Distro | Package | Source checked |
|---|---|---|
| Arch | `gcr-4` | [archlinux.org/packages/extra/x86_64/gcr-4](https://archlinux.org/packages/extra/x86_64/gcr-4/) — single package, ships headers+lib+`gcr-4.pc` together (no split `-devel`) |
| Fedora | `gcr-devel` | [packages.fedoraproject.org/pkgs/gcr/gcr](https://packages.fedoraproject.org/pkgs/gcr/gcr/) — current `gcr` srpm is already 4.4.0.1 (GCR4); `gcr-devel` provides `pkgconfig(gcr-4)` |
| openSUSE Tumbleweed/Slowroll | `libgcr-devel` | `gcr.spec` on `openSUSE:Factory` OBS — `%package -n libgcr-devel` owns `%{_libdir}/pkgconfig/gcr-4.pc`, `Requires: libgcr-4-4` |
| Debian/Ubuntu | `libgcr-4-dev` | [packages.debian.org/sid/libgcr-4-dev](https://packages.debian.org/sid/libgcr-4-dev) — source package `gcr4`, pinned 4.4.0.1-8, present in trixie |
| Void Linux | `gcr4-devel` | `srcpkgs/gcr4/template` on `void-packages` — pinned 4.4.0.1, matches krytis's own pin exactly |

No package needed beyond the one above per distro: every one of these `-devel` packages pulls
in `p11-kit`/`libgcrypt` transitively (they're already `Requires`/`makedepends` on the gcr
package itself), and `libsecret`/`libsodium` were already in the README's lists. Consistent
with the earlier finding in this doc — GTK is not part of this dependency on any of the five
distros either: none of the `-devel` packages above pull in a GTK `-devel` package (openSUSE's
`gcr` *source* package does `BuildRequires: pkgconfig(gtk4)` to build `gcr-viewer-gtk4`, but
that's the packager's build-time requirement for the upstream tarball as a whole, not a
dependency of the `libgcr-devel` binary package noctalia links against).

**Known consumers to interop-test against, not just gnome-keyring:** oo7's `GNOMEPrompterProxy`
(`server/src/gnome/prompter.rs`, in play if #84 is ever reopened), GCR3's own `gcr-prompter`
(for anything that still expects the legacy binary specifically), and generic libsecret/pinentry
clients that fall back to `org.gnome.keyring.SystemPrompter` when no portal-based prompter is
available.

## Status: implemented on a fork (2026-08-12)

Built and verified on `kitten-lily/noctalia`, branch `feat/system-prompter`. Originally commit
`ba821c7da` on upstream `main` at `8403cb987` (`v5.0.0-beta.8-36`); **rebased 2026-08-17 onto
upstream `main` `87b203c68` (`v5.0.0-beta.8-135`), now at `47c1df893`.** **No PR or issue
has been opened against `noctalia-dev/noctalia`** — per AGENTS.md's Upstream Gate that needs
an explicit instruction naming that action. The branch loses nothing by waiting.

The rebase absorbed 98 upstream commits with **no source conflict** — the 1722-line feature
commit applied untouched. The only conflict was documentation: upstream moved its dependency
lists out of `README.md` into a new `BUILDING.md`, so the `gcr-4` package names moved there,
including for the AerynOS entry upstream added in the meantime (`gcr-devel`, verified against
the `g/gcr` recipe in `AerynOS/recipes`, which provides `pkgconfig(gcr-4)` at 4.4.0.1 — the
same version krytis pins).

Every hunk the branch introduces is byte-identical before and after the rebase, across all 9
modified upstream files, and all 6 branch-owned files are byte-identical too. That is why the
2026-08-12 runtime verification below still stands rather than needing to be redone: the
prompter code did not change, only the code around it moved forward. Method in
`docs/skills/workflow.md` § *Rebasing a carried fork branch*.

noctalia's own `secret_prompter` unit test could not be re-run as part of this: `dbus-daemon`
cannot start in a BST sandbox at all (no passwd database), so the test builds and then fails on
bus startup. See `docs/skills/bst.md` § *Unit tests needing a D-Bus session*.

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

### Re-verified on live hardware, not a VM (2026-08-14)

The daily-driver machine now runs the oo7 image with a real 21-item keyring migrated from
gnome-keyring. **All of this is oo7 `0.6.0`** (`ref: 0.6.0-0-g9070389…`, tagged 2026-02-21),
which is 221 commits behind upstream `main` — see the staleness caveat at the end.

- **The v0 → v1 migration was clean.** All 21 items present with intact labels and readable
  secrets; the pre-existing `gh:github.com` token read back as a well-formed 40-character
  `gho_` value. No data loss.
- **Round trip works:** store → `lookup` returns the exact value, and `SearchItems` while
  unlocked correctly reports `aoao 1 "…/collection/Login/23" 0`.
- **`Lock` works here** (`Locked` flips to `b true`), unlike the earlier inconclusive attempt
  against an already-locked collection.
- **The prompter works end to end on a real niri session.** With the collection locked, a
  `store` raised noctalia's panel; the daemon log shows an 11-second gap between client
  connect and `Successfully created item` — the prompt being read and answered. A secret
  stored *before* the lock then read back correctly, so the unlock restored access rather than
  merely permitting the new write.
- **#585 reproduces exactly, and is narrower than first written.** The locked item still
  answers `Item.Locked = b true` by object path and appears in the collection's `Items`
  property; only `SearchItems` drops it, because attribute matching needs the collection key.
  oo7 could return locked items as unmatched candidates — all libsecret needs to trigger an
  unlock — without decrypting anything.
- **New, and the most serious operational finding: #586.** oo7 serves
  `/org/freedesktop/secrets/aliases/default` for introspection and property reads, but
  Service-level method calls against that path fail (`Object: … does not exist`). Go's
  `go-keyring` resolves the default collection that way, so **`gh auth login` silently stored
  its OAuth token in plaintext** at `~/.config/gh/hosts.yml` instead of the keyring. oo7's
  warnings land within microseconds of the file write, and it reproduces on a fresh,
  never-migrated keyring — so it is not a migration artifact.

Still not exercised: `ChangePassword`, and the mid-session `systemctl --user restart
oo7-daemon` re-lock scenario.

**Staleness caveat — since resolved, see below.** #585's cause was source-verified on current
`main` as well as on the pin. Everything else in this section was measured on `0.6.0` only.

### Upgraded to 0.7.0.alpha: one blocker gone, one remains (2026-08-14)

`elements/desktop/oo7.bst` was re-pinned `0.6.0` → `0.7.0.alpha` (`94a8e42`) and the machine
now runs that image (`oo7-daemon 0.7.0-alpha`). The pin had been inherited verbatim from #178
and never tracked, leaving it 221 commits behind.

- **#586 is fixed.** `Unlock` against `/org/freedesktop/secrets/aliases/default` now returns
  `aoo 1 "…/collection/login" "/"`, identical to the collection path, with **zero**
  `Object: … does not exist` warnings. The practical consequence is gone too: `gh auth status`
  reports `Logged in … (keyring)` and `~/.config/gh/hosts.yml` contains no `oauth_token`.
  Issue closed; nothing to report upstream.
- **#585 is not fixed.** Re-tested on `0.7.0.alpha`: store and lookup work unlocked,
  `SearchItems` reports the item, the lock takes, and then `SearchItems` returns `aoao 0 0`
  with `lookup` failing in 19ms and no prompt. Matches the source read of `main`.
- **The collection path changed** from `…/collection/Login` to lowercase `…/collection/login`,
  matching gnome-keyring. Anything that hardcoded the capitalised form during the `0.6.0`
  period needs revisiting.
- The 22-item keyring came through the upgrade intact.

**Net effect on the decision.** The hold stands, but on narrower grounds: the plaintext-credential
regression is gone, so what remains is **#585 plus oo7#506** rather than three blockers. #585 is
the one that matters — while a locked collection reads back as "no such secret", a FIDO2 user is
never offered the chance to unlock, and accepting the FIDO2 gap is not sufficient on its own.

Meanwhile the *prompter*, the part krytis actually owns, is verified working against both
gnome-keyring and oo7 and can proceed independently of any of this.

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

## 2026-08-16 re-pin: `0.7.0.alpha` → `main` (`c2aa2315`)

Re-pinned to check whether upstream had fixed anything since the migration shipped. Score:
**one bug fixed, one fixed-then-reopened-by-another-route, two untouched.** The element now
tracks `refs/heads/main` rather than a tag glob, because no tag carries any of it.

| Tracked defect | Status on `c2aa2315` |
|---|---|
| **oo7#530 / #588** — CLI prompter chosen | **Reworked, still broken here.** `9f4de634` swapped env-sniffing for the peer's logind session type. The new lookup fails for every client of a systemd-managed session, so krytis still lands on `Cli`. Patch rewritten as a fallback rather than dropped. |
| **#585** — locked collection invisible to `SearchItems` | **Unfixed.** `server/src/collection/mod.rs::search_inner_items` still opens with `if keyring.is_locked() { return Ok(Vec::new()); }`, byte-identical to the `0.6.0` and `0.7.0.alpha` readings. FIDO2 login therefore stays disabled. |
| **oo7#506** — passwordless/FIDO2 unlock | **Unfixed, no movement.** Still open, last comment 2026-08-03. `git log 94a8e42e..c2aa2315 -- pam/` returns exactly one commit, and it is a linker fix. |
| **oo7#546** — `pam_oo7.so` never linked `-lpam` | **Fixed** by `c2aa2315`, the pin's tip: `pam/build.rs` now emits `cargo::rustc-link-lib=pam`. Previously the module resolved `pam_get_item` and friends lazily against the host PAM process, which is why krytis never saw the undefined-symbol failure. |

Also landed and worth knowing, though neither was a tracked krytis defect: `7b8edfb`
(`server`: replace only items with identical attributes, oo7#549) and `709a551` (`cli`: allow
changing a secret, the oo7#544 Seahorse/Key Rack complaint). Neither is exercised by krytis
today — `ChangePassword` is still the untested path called out above.

**The lesson worth carrying past oo7:** a *closed* upstream issue is not evidence the bug is
gone downstream. oo7#530 was closed by a real fix that is correct for the maintainer's
environment and inert in ours, because the two disagree about where a graphical client's
process lives. Re-verify against the running system, not the issue tracker.
See `docs/skills/pam.md` § *krytis patches oo7's prompter detection* for the measurements.

`mise run oo7-prompter-test` now gates the prompter choice on the built artifact, so the next
re-pin does not have to rediscover this by hand. It failed on unpatched `c2aa2315` and passes
with the patch — the A/B is quoted in that skill section.

## Revisit trigger

The migration has shipped, so this is no longer "should we start?" but "can we drop a
workaround?". Re-read this doc when any of these move:

- **oo7 reports locked items from `SearchItems`** (#585) → re-enable FIDO2 login in
  `config/greetd-config.bst` and delete the mitigation comment there.
- ~~**oo7 handles a peer logind cannot attribute**~~ → **fired 2026-08-27.**
  `patches/oo7/prompter-detect-session-type.patch` and its wiring in
  `elements/desktop/oo7.bst` are deleted. The trigger was correctly written as "a follow-up
  fix, not oo7#530" — the follow-up turned out to be `f6a8624a` / oo7#558, which upstream
  found independently. It surfaced downstream as the `track-oo7` CI job going red, because
  the patch stopped applying to the reworked code.
- **oo7#506 gains a maintainer-endorsed direction** → revisit FIDO2 login independently of
  #585; the two reasons it is off are separable.
- **The noctalia prompter is upstreamed** → repoint `elements/desktop/noctalia.bst` back to
  `noctalia-dev/noctalia` with `track: v*`, and drop `sdk/gcr.bst` only if upstream stops
  linking `GcrSecretExchange`.

Until then the workarounds stay. Each is annotated at its call site with the issue number, so
`git grep 585` and `git grep 588` find everything that has to change.
