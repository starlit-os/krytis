# Bazaar curated recommends — Implementation Plan

**Issue:** #245

**Goal:** Ship the *wiring* for Bazaar's Curated page — `/etc/bazaar/{bazaar,curated,blocklist}.yaml`
in the OCI image from a new `elements/config/bazaar-config.bst`, plus a boot-time oneshot
that grants the `io.github.kolunmi.Bazaar` flatpak read-only access to the host `/etc`.
The result is a working "Curated" tab and a blocklist that hides the flatpak duplicates of
apps krytis already ships natively. `curated.yaml` ships a section skeleton with a handful
of verified app IDs; the curated list proper is a separate deliverable owned by a parallel
candidate-mining session (decision 10). Bazaar itself stays a `--system` flatpak installed
by `files/flatpak-preinstall/flatpak-preinstall.sh` (#66) — this issue is config only.

**Architecture:** One `kind: manual` element with a `kind: local` source at `files/bazaar/`,
mirroring `elements/config/desktop-udev.bst` (glob-loop install) and
`elements/config/flatpak-preinstall.bst` (script + unit + preset). It produces three YAML
files under `%{sysconfdir}/bazaar/`, one script under `/usr/libexec/krytis/`, one system
unit, and one preset. Wired into `elements/stacks/desktop.bst` next to
`config/flatpak-preinstall.bst`.

**Tech stack:** BST `kind: manual` + `kind: local`; systemd oneshot + `system-preset`;
`flatpak override --system`; Bazaar's modern `rows:` curated schema.

---

## Decisions already made — do not relitigate mid-implementation

**1. The modern `rows:` schema, not the legacy `css:` + `rows: - sections:` form.**
Issue #245's third comment warns that stable Bazaar `v0.8.2` only understands the legacy
schema. That warning is stale — both upstream and Bluefin have moved.

| Fact | Value | How verified |
|---|---|---|
| Bazaar version on Flathub stable | **0.9.5** | `flatpak info io.github.kolunmi.Bazaar` on this workstation → `Version: 0.9.5`, `Subject: 0.9.5 (#162)` |
| Latest upstream releases | v0.9.0 … v0.9.4 | `gh api repos/bazaar-org/bazaar/releases` |
| Bluefin's own `curated.yaml` today | modern `rows: [- banner:, - section:]` | `projectbluefin/common` `system_files/bluefin/etc/bazaar/curated.yaml`, fetched 2026-09-29 |
| Bluefin's own skill doc | "Legacy Bazaar releases (`v0.8.2` and older) used a root-level `css:` block and `rows: - sections:`, which is deprecated upstream and rejected by modern Bazaar releases." | `projectbluefin/common/docs/skills/bazaar.md` |

**2. Gradient banners, no image files.** Issue #245 describes a "JXL→PNG converted at build
time (`djxl -C sRGB`)" pipeline. That is also stale: Bluefin now references `.jxl` natively
(`light-uri: file:///run/host/etc/bazaar/11-bluefin-day.jxl`) via glycin-jxl, and in any
case those banners are Bluefin branding art from their `bluefin-branding` submodule, which
krytis has no equivalent of. Upstream's `bazaar-org/bazaar/docs/example.yaml` shows
`banner.light-color` / `banner.dark-color` accepting a plain colour *or* a CSS gradient
with no `image:` key at
all. Use gradients. This removes the binary-asset question, the `djxl` build dependency,
and the `set -e` footgun from scope entirely.

If branding art is wanted later, the precedent is `elements/config/noctalia-assets.bst`
(`kind: local` + `install -Dm644` + `strip-binaries: ''`) — but it is not part of this issue.

**3. `flatpak override --system`, NOT Bluefin's tmpfiles `L` symlink.** Bluefin ships
`L /var/lib/flatpak/overrides/io.github.kolunmi.Bazaar - - - - /usr/share/ublue-os/flatpak-overrides/io.github.kolunmi.Bazaar`.
Do not port that. Three reasons, in order of weight:

- **The symlink target is read-only on krytis.** `/usr` is a composefs mount. Any later
  `flatpak override --system io.github.kolunmi.Bazaar` — by the operator, or by krytis
  itself — resolves the symlink and fails `EROFS`. The tmpfiles form converts a mutable
  per-app override into an immutable one.
- **krytis already has a documented, working precedent for exactly this.**
  `files/flatpak-preinstall/flatpak-cursor-path.sh:41` runs `flatpak override --system`
  from a boot-time oneshot; its header (`:23-28`) and `docs/skills/desktop.md`
  § *Flatpak strips XCURSOR_PATH* explain why a declarative file write is wrong.
  `live/src/install-flatpaks.sh:110` does `flatpak override --system --filesystem=/etc:ro`
  ISO-side. A second mechanism for the same job would be a new convention beside an
  existing one.
- **No ordering constraint.** Verified on this workstation: `flatpak override` succeeds for
  an app that is not installed (`flatpak override --user --filesystem=host-etc com.example.NotInstalled` → `rc=0`,
  file written). So the override unit needs no `After=flatpak-preinstall.service`.

**4. `--filesystem=host-etc:ro`, not `host-etc`.** Bazaar only reads its config. Verified
on this workstation with a reverted `--user` override:

| Probe | Result |
|---|---|
| Without any override | `ls /run/host/etc` → `No such file or directory` |
| `--filesystem=host-etc` | `/run/host/etc` visible |
| `--filesystem=host-etc:ro` | `/run/host/etc` visible; `touch /run/host/etc/probe` → `Read-only file system` |

`host-etc:ro` is therefore sufficient and strictly tighter than what Bluefin and Aurora ship.

**5. The config path is fixed at Bazaar's compile time — `/etc/bazaar/bazaar.yaml` is the
only path that works.** The Flathub manifest pins it:

```yaml
    config-opts:
      - -Dsandboxed_libflatpak=true
      # Set this to `etc` so that distributors can override `host-etc` perms
      - -Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml
      - -Dhardcoded_content_config_path=/run/host/etc/bazaar/config.yaml
      - -Dhardcoded_blocklist_path=/run/host/etc/bazaar/blocklist.txt
```

(`flathub/io.github.kolunmi.Bazaar` `io.github.kolunmi.Bazaar.yaml`, fetched 2026-09-29.)
Upstream: *"If this is not defined at compile time, Bazaar will never attempt to read a
main config."* Both `curated-config-paths` and `yaml-blocklist-paths` are then pointed from
that main config, so `config.yaml` and `blocklist.txt` stay unused — do not create them.

**6. No `bazaar.service` user unit.** Issue #245 flags that Bluefin's must be `Type=simple`.
Irrelevant here: krytis already starts the daemon from the compositor, twice —
`files/niri/startup.kdl:12` (`spawn-at-startup`) and `files/umbriel/config.toml:69`
(`autostart`), both landed for the `bazaarsearch` noctalia plugin (#763,
`docs/skills/desktop.md` § *noctalia plugins: enabling in skel, and daemon-backed plugins like bazaarsearch*).
Adding a `WantedBy=graphical-session.target` unit would spawn a second daemon. Also note
Bluefin's unit runs `--command=bazaar` while the Flathub manifest's `command:` is
`bazaar-daemon` — krytis's existing spawn is the correct one; leave it alone.

**7. No `hooks.py` port.** Bluefin's four hooks (JetBrains, VS Code, VSCodium, Zed) all
terminate in "Install via **Homebrew**" or "Download JetBrains Toolbox" dialogs, and
`shell: exec python3 /run/host/etc/bazaar/hooks.py`. krytis has neither `ujust` nor
Homebrew, so there is nothing to steer users *to* — a warning dialog with no alternative is
worse than no dialog. The transferable half of Bluefin's steering-by-exclusion is the
blocklist, which this plan does port. Revisit only if krytis grows a host-install path.

**8. Blocklist scope: krytis's own native duplicates, not Bluefin's editor list.** Bluefin
blocks `io.neovim.nvim`, `org.vim.Vim`, `com.helix_editor.Helix`, `org.gnu.emacs`,
`app.devsuite.Ptyxis`, `org.freedesktop.fwupd` because Bluefin ships those natively or via
Homebrew. krytis's native app set is different — `elements/stacks/desktop-apps.bst` plus
`elements/desktop/ghostty.bst`. Block the flatpaks that duplicate what krytis already
installs, and Bazaar itself (per Bluefin, and because updating your app store from inside
your app store is a footgun).

**9. Element boundary.** `docs/skills/bst.md` (§ Flatpak Pre-install Service Pattern):
*"This config belongs in a dedicated BST element, not in the preinstall service."* One new
element, `elements/config/bazaar-config.bst`, owning all six files. Do not extend
`elements/config/flatpak-preinstall.bst`.

**10. This plan is the *wiring*. The curated app list is a separate deliverable with a
separate owner.** A parallel session is building a candidate-mining skill — Bluefin's
`curated.yaml` supplies the initial candidate pool, and the skill finds further candidates
the same way `.claude/skills/upstream-lessons/` mines upstreams for lessons. Consequences,
all binding on this plan:

- **The wiring PR must be mergeable before that list exists.** It therefore ships a real
  but deliberately small `curated.yaml` — enough to prove the Curated tab renders
  (Task 7 Step 4), not a curation attempt. Do not block Task 2 on the other session.
- **The curation session's output replaces `appids.list` bodies only.** It must not need to
  touch `elements/config/bazaar-config.bst`, `bazaar.yaml`, or the override unit. Task 2
  Step 2 defines the contract that guarantees this.
- **Do not pre-empt it.** Porting Bluefin's ~90 IDs here would hand that session a merge
  conflict instead of a blank field. Ship the skeleton; let the list land on top.

---

## Non-goals

- **Curating the app list** — owned by the parallel candidate-mining session (decision 10).
  This plan defines the file, the schema, and the contract it must satisfy; it does not
  choose the apps.
- Porting `hooks.py` / `bazaar-hook` (decision 7).
- Porting banner imagery or a `bluefin-branding` equivalent (decision 2).
- A `bazaar.service` user unit (decision 6).
- Changing how `bazaar-daemon` is started, or the `bazaarsearch` plugin wiring.
- `search-biases`, `articles:`, `featured-carousel:`, `override-eol-markings` — all
  supported by Bazaar, none required by #245. Adding them is a separate issue.

---

## Global Constraints

- No RPMs, no dnf, no container overlays — BST elements only (`AGENTS.md`).
- **Update path gate:** the element's only source is `kind: local`, which has no upstream
  ref to track. `bst source track` applies to `git_repo` and (via `mise/tasks/tarball-update`)
  to `tar`/`remote`; `docs/skills/bst.md` § Element update path lists only those two kinds,
  and none of the 33 `elements/config/*.bst` appears in `.github/workflows/track-bst-sources.yml`.
  **No tracking entry is required.** State that reasoning in the PR rather than claiming an
  explicit carve-out — no doc sentence grants one. The curated app list *will* drift as
  apps are renamed or delisted; that drift is accepted and unautomated (see Task 7 Step 5).
- **Mise task integrity:** every verification step below uses an existing `mise` task. No
  new task is needed.
- **Skill write-back lands in the same commit** (`AGENTS.md` § Skill-improvement mandate).
  Task 6 is not a follow-up. It is also not optional here for a second reason: this plan
  contradicts a claim currently in `docs/skills/bst.md` (decision 3), and per
  `AGENTS.md` § *What the first sweep learned about how rot gets in*, the fix commit owns
  correcting the doc it supersedes.
- `mise run build` must pass and the image must be shown to boot before requesting review.
  `mise run build` already chains `generate-image-version` → `load-image` → `lint` →
  `umbriel-config-validate`; a separate `mise run lint` afterward is redundant.
- Worktree: `.worktrees/feat/gh245-add-bazaar-curated-recommends`, branch
  `245-add-bazaar-curated-recommends` (top-level issue — `gh issue view 245 --json parent`
  returns `"parent": null`).
- **The PR gate builds only the changed elements.** `.github/workflows/build-changed.yml`
  builds `config/bazaar-config.bst` and `stacks/desktop.bst` on the PR, but not the image.
  Run `mise run build-changed` locally before opening the PR.
- Note `bash -n` in CI globs `mise/tasks/*`, `mise/tasks/*/*` and `scripts/*.sh` only — a
  script under `files/bazaar/` is **not** syntax-checked by CI. Run `bash -n` on it by hand.

---

### Task 1: Confirm the runtime preconditions on the target image

**Files:** none (verification only).

**Interfaces:** produces the "does the shipped image's Bazaar match 0.9.5's schema"
answer that Task 2's YAML depends on. Everything here was already checked against the
Flathub stable branch on 2026-09-29; re-run only if implementation happens materially
later, or if `flatpak-preinstall.sh` has started pinning a branch other than `flathub`
stable.

- [ ] **Step 1: Re-confirm the shipped Bazaar version**

```bash
flatpak remote-info flathub io.github.kolunmi.Bazaar | grep -E '^\s*(Version|Commit)'
```

Required: `Version: 0.9.x` or newer. If it has regressed below `0.9.0`, stop — the curated
schema in Task 2 will be rejected and the legacy form must be used instead (see decision 1
for what that looks like).

- [ ] **Step 2: Re-confirm the hardcoded config path**

```bash
curl -sS https://raw.githubusercontent.com/flathub/io.github.kolunmi.Bazaar/master/io.github.kolunmi.Bazaar.yaml \
  | grep hardcoded_main_config_path
```

Required: `-Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml`. If this has
changed, every path in Task 2 changes with it.

- [ ] **Step 3: Resolve the exact app IDs for krytis's native duplicates**

Verified already on this workstation via `flatpak search`:

| krytis native element | Flatpak ID to block | Status |
|---|---|---|
| `desktop/proton-pass.bst` | `me.proton.Pass` | verified |
| `desktop/zed.bst` | `dev.zed.Zed` | verified |
| `desktop/equibop.bst` | `com.discordapp.Discord`, `org.equicord.equibop` | verified |
| `desktop/zen-browser.bst` | *(resolve)* | **unverified** |
| `desktop/gnome-disk-utility.bst` | *(resolve)* | **unverified** |
| `desktop/ghostty.bst` | *(resolve)* | **unverified** |
| `desktop/warp.bst` | — | not on Flathub (`flatpak search warp-terminal` → no matches) |

**Re-derive this table at implementation time — do not trust it as an inventory.** It was
produced by reading `elements/stacks/desktop-apps.bst` on 2026-09-29, and the native app
set is actively changing: #1005 ("Default to seance, drop warp") is open and would remove
the `warp.bst` row and add `desktop/seance.bst`. Regenerate from the file, not from here.

Resolve the three unverified rows before writing the blocklist — do not guess an ID:

```bash
flatpak search --columns=application,name zen
flatpak search --columns=application,name 'disk'
flatpak search --columns=application,name ghostty
```

A wrong ID in a blocklist fails silently — the app simply stays visible, and nothing logs.

---

### Task 2: Write the three YAML configs

**Files:**
- Create: `files/bazaar/bazaar.yaml`
- Create: `files/bazaar/curated.yaml`
- Create: `files/bazaar/blocklist.yaml`

**Interfaces:**
- Consumes: the app IDs resolved in Task 1 Step 3.
- Produces: the content Task 4's element installs to `/etc/bazaar/`, and the surface Task 7
  Step 4 smoke-tests.

- [ ] **Step 1: `files/bazaar/bazaar.yaml`**

```yaml
# Bazaar main config. Bazaar reads this path and no other: the Flathub build
# bakes -Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml at compile
# time, and /run/host/etc is this file's own /etc seen from inside the sandbox.
# Reaching it needs the host-etc permission, granted by
# /usr/libexec/krytis/bazaar-host-etc.sh. Closes #245.
#
# Do NOT create config.yaml or blocklist.txt beside this file. The Flathub build
# also hardcodes those two paths, but pointing at curated/blocklist from here is
# the supported route and keeps one file per concern.
yaml-blocklist-paths:
  - /run/host/etc/bazaar/blocklist.yaml

curated-config-paths:
  - /run/host/etc/bazaar/curated.yaml

# starlit-update.service already runs `flatpak update --system` daily
# (files/starlit-update/starlit-update.service). Surfacing a second, per-user
# auto-update toggle in Bazaar's preferences would only create ambiguity about
# which one is in charge.
hide-auto-update-options: true
```

- [ ] **Step 2: `files/bazaar/curated.yaml` — skeleton only (decision 10)**

Write the section *structure*, not the curation. Each section gets a gradient banner, a
title, a subtitle, and a short `appids.list` of three to five IDs verified present on
Flathub — enough for Task 7 Step 4 to prove the tab renders and the blocklist bites.

Sections to create, matching Bluefin's so the curation session's candidates drop straight
in: Krytis Recommends, Browsers, Media, Office & Productivity, Games, Utilities,
Sustainability & Education, AI and Machine Learning, Desktop Development, Cloud Native
Development.

Shape, from `bazaar-org/bazaar/docs/example.yaml`:

```yaml
rows:
- banner:
    height: 400
    light-color: "linear-gradient(135deg, #b9a5d6 0%, #7c6f9f 100%)"
    dark-color: "linear-gradient(135deg, #2b1f3d 0%, #4a3f6b 100%)"
- section:
    title:
      en: Krytis Recommends
    subtitle:
      string:
        en: Our favourite applications
    appids:
      list:
      - app.drey.Damask
      - app.fotema.Fotema
      - re.sonny.Eloquent
```

Pick the gradients from noctalia's shipped palette rather than inventing colours —
`files/noctalia-skel/` is the reference for what the desktop actually looks like. Use the
language-map form (`title: {en: …}`) even for a single language: Bazaar accepts a bare
string or a map for any string scalar, and starting in map form means the curation session
can add `fr`/`id`/`pl` — which Bluefin already ships — without restructuring the file.

#### Contract with the curation session

The curation session owns `appids.list` contents and nothing else. State this in the PR
body so the boundary is on the record:

| Owned by this PR | Owned by the curation session |
|---|---|
| `rows:` structure, banners, section titles/subtitles | the ID list inside each `appids.list` |
| `bazaar.yaml`, `blocklist.yaml`, the element, the override unit | — |

Constraints the list must satisfy, all mechanically checkable:

1. **Every ID resolves on Flathub.** `flatpak remote-info flathub <id>` must succeed — a
   delisted or renamed ID fails silently, showing no tile and logging nothing. Task 7
   Step 5 already carries the loop that checks this; it works unchanged on a longer list.
2. **No ID also appears in `blocklist.yaml`.** The blocklist wins, so a curated entry for a
   blocked ID is a tile that silently never renders. This is the collision that Bluefin's
   own list has (`dev.zed.Zed` is curated *and* hook-intercepted); krytis blocks native
   duplicates instead, so at minimum `dev.zed.Zed` and `com.discordapp.Discord` must not
   appear in the curated list.
3. **Modern schema only** — `rows: [- banner:, - section:]`, never `css:` + `rows: - sections:`
   (decision 1).
4. **No `image:` keys under `banner:`** unless branding art has been added to
   `files/bazaar/` in the same change (decision 2).
5. **Changing the list must not require touching any other file.** If a proposed change
   does, it is out of contract — raise it rather than editing the element.

Bluefin's `projectbluefin/common` `system_files/bluefin/etc/bazaar/curated.yaml` is the
candidate pool, not the answer; the mining skill supplies the rest.

- [ ] **Step 3: `files/bazaar/blocklist.yaml`**

```yaml
# Apps hidden from Bazaar's browse and search. Blocking is display-only:
# upstream is explicit that "under no circumstance does Bazaar touch the
# underlying flatpak configuration", and an already-installed blocked app still
# appears in the library and still receives updates. `flatpak install` from a
# terminal is unaffected. Closes #245.
#
# Scope is deliberately narrower than Bluefin's: they also block CLI editors
# (nvim, vim, helix, emacs) because Homebrew is the supported path to them on
# Bluefin. krytis has no host-install path to steer anyone toward, so hiding an
# app krytis cannot otherwise provide would just be removing an option.
blocklists:
  - block:
    # Updating the app store from inside the app store.
    - io.github.kolunmi.Bazaar
    # Flatpak duplicates of apps stacks/desktop-apps.bst installs natively.
    - me.proton.Pass          # desktop/proton-pass.bst
    - dev.zed.Zed             # desktop/zed.bst
    - com.discordapp.Discord  # desktop/equibop.bst
    - org.equicord.equibop    # desktop/equibop.bst
    # … plus the zen-browser / gnome-disk-utility / ghostty IDs from Task 1 Step 3
```

- [ ] **Step 4: Parse-check all three before building anything**

```bash
python3 -c 'import sys,yaml;[yaml.safe_load(open(f)) for f in sys.argv[1:]];print("YAML OK")' \
  files/bazaar/*.yaml
```

There is no YAML linter in CI (`mise/tasks/lint` is a `podman build`, and
`.github/workflows/checks.yml` checks only shell and Python syntax), so a malformed file
would otherwise reach the image and fail silently at runtime — Bazaar just shows no
Curated tab.

---

### Task 3: Write the host-etc override oneshot

**Files:**
- Create: `files/bazaar/bazaar-host-etc.sh`
- Create: `files/bazaar/bazaar-host-etc.service`

**Interfaces:**
- Produces `/usr/libexec/krytis/bazaar-host-etc.sh` and
  `/usr/lib/systemd/system/bazaar-host-etc.service`, both installed by Task 4.
- The unit is what makes Task 2's files reachable at all; without it every config in
  `/etc/bazaar` is invisible to the sandbox and the whole feature is a no-op.

- [ ] **Step 1: `files/bazaar/bazaar-host-etc.sh`**

```bash
#!/bin/bash
# Grant Bazaar read-only access to the host /etc so it can read its own config.
# Closes #245.
#
# Bazaar's config path is fixed at compile time by the Flathub build
# (-Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml), and the
# Flathub build ships no filesystem permission for it. Without this override
# /run/host/etc does not exist inside the sandbox at all:
#
#   $ flatpak run --command=sh io.github.kolunmi.Bazaar -c 'ls /run/host/etc'
#   ls: cannot access '/run/host/etc': No such file or directory
#
# Bluefin and Aurora deliver the same permission as a tmpfiles.d `L` symlink
# from /var/lib/flatpak/overrides/<appid> into /usr/share/.../flatpak-overrides/.
# That does not port: /usr is a read-only composefs mount here, so the symlink
# makes the override file permanently unwritable and any later
# `flatpak override --system io.github.kolunmi.Bazaar` fails EROFS.
# `flatpak override` merges into the keyfile and leaves it mutable.
#
# `:ro` rather than plain host-etc — Bazaar only reads. Verified: with `:ro`,
# `touch /run/host/etc/probe` inside the sandbox returns "Read-only file system".
#
# Not marker-gated, unlike flatpak-preinstall.sh: the override lives in /var, so
# a bootc rollback or a wiped /var must be able to restore it, and the operation
# is local, offline and sub-second. Idempotent — re-running rewrites the same key.
#
# No ordering against flatpak-preinstall.service is needed: `flatpak override`
# succeeds for an app that is not installed yet (verified, rc=0).
set -euo pipefail

flatpak override --system --filesystem=host-etc:ro io.github.kolunmi.Bazaar
```

- [ ] **Step 2: `files/bazaar/bazaar-host-etc.service`**

```ini
[Unit]
Description=Grant Bazaar read-only access to the host /etc
Documentation=https://github.com/starlit-os/krytis/issues/245
# Same shape as flatpak-cursor-path.service: writes into /var, needs no network,
# must reassert itself if /var is reset, so no ConditionPathExists gate.
# Ordered before the graphical session so the first Bazaar launch already sees
# its config.
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/krytis/bazaar-host-etc.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Syntax-check the script by hand**

```bash
bash -n files/bazaar/bazaar-host-etc.sh && echo "shell syntax OK"
```

CI's `bash -n` loop does not cover `files/`, so this is the only check it gets.

---

### Task 4: Create `elements/config/bazaar-config.bst`

**Files:**
- Create: `elements/config/bazaar-config.bst`

**Interfaces:**
- Consumes: `files/bazaar/` (Tasks 2 and 3).
- Produces: `/etc/bazaar/{bazaar,curated,blocklist}.yaml`,
  `/usr/libexec/krytis/bazaar-host-etc.sh`,
  `/usr/lib/systemd/system/bazaar-host-etc.service`,
  `/usr/lib/systemd/system-preset/73-krytis-bazaar-host-etc.preset`.
  Task 5 wires the graph edge; Task 7 asserts exactly this path list.

- [ ] **Step 1: Write the element**

```yaml
# bazaar-config: Bazaar's curated-recommends page, blocklist, and the /etc
# access permission that makes both readable. Closes #245.
#
# Bazaar itself is NOT a BST element -- it is a --system flatpak installed by
# files/flatpak-preinstall/flatpak-preinstall.sh (#66). This element is config
# only, kept separate from config/flatpak-preinstall.bst per docs/skills/bst.md
# § Flatpak Pre-install Service Pattern.
#
# /etc, not /usr/lib: the path is not a krytis preference, it is compiled into
# the Flathub build of Bazaar as
# -Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml. /run/host/etc
# is the host's /etc as seen from inside the flatpak sandbox.
#
# Ported from projectbluefin/common system_files/bluefin/etc/bazaar/, minus the
# hooks (they steer to ujust/Homebrew, which krytis does not have), minus the
# bazaar.service user unit (the daemon is already spawned from
# files/niri/startup.kdl and files/umbriel/config.toml for #763), and minus the
# JXL banner art (Bluefin branding; gradients used instead).
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    for f in bazaar.yaml curated.yaml blocklist.yaml; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/bazaar/$f"
    done

  - |
    install -Dm755 bazaar-host-etc.sh \
      "%{install-root}/usr/libexec/krytis/bazaar-host-etc.sh"

    install -Dm644 bazaar-host-etc.service \
      "%{install-root}%{indep-libdir}/systemd/system/bazaar-host-etc.service"

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/73-krytis-bazaar-host-etc.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/73-krytis-bazaar-host-etc.preset" <<'EOF'
    enable bazaar-host-etc.service
    EOF

  - '%{install-extra}'

sources:
- kind: local
  path: files/bazaar
```

Notes for the implementer:

- `strip-commands: [':']` is required — the default strip invokes
  `freedesktop-sdk-stripper`, absent from `runtime-minimal`
  (`docs/skills/bst.md` § Config-Only Elements).
- Use `install -Dm644 /dev/null <target>` + `cat > <target> <<'EOF'`, never
  `install -Dm644 /dev/stdin <target> <<'EOF'` — remote-execution sandboxes have no
  `/dev/stdin` (#735 converted all 46 sites; `elements/` is uniformly two-step today).
- Preset number `73-` follows `72-krytis-flatpak-preinstall` / `72-krytis-flatpak-cursor-path`
  in `elements/config/flatpak-preinstall.bst`. Never `systemctl enable` in install-commands.
- `fatal-warnings: overlaps` is on and no element owns `/etc/bazaar/*` today (grep-confirmed:
  no `/etc/bazaar` path exists anywhere in the tree). Do **not** pre-emptively add an
  `overlap-whitelist`. If a collision does appear, report it rather than whitelisting.
- Do not let `files/bazaar/` become empty in a later change without also removing the
  `kind: local` source block — BST validates the path at resolution time and a dangling
  `files/<name>` blocks the whole pipeline (`docs/skills/bst.md` § *`kind: local` source
  becomes dangling when directory is emptied*).

- [ ] **Step 2: Build it standalone and assert the produced tree**

```bash
mise run bst build config/bazaar-config.bst
mise run bst -- artifact checkout --tar /tmp/bazaar.tar config/bazaar-config.bst
tar tf /tmp/bazaar.tar | grep -E 'bazaar|krytis'
```

Expect exactly the six paths under **Produces** above and nothing else. The PR gate
(`build-changed.yml`) proves the element builds; only this checkout proves what it
installs.

---

### Task 5: Wire the element into `stacks/desktop.bst`

**Files:**
- Modify: `elements/stacks/desktop.bst`

**Interfaces:** consumes Task 4; produces the graph edge every step in Task 7 relies on.

- [ ] **Step 1: Append a block immediately after the existing Flatpak pre-install block**

The `# ── Flatpak pre-install ──` block currently ends at `- config/flatpak-preinstall.bst`,
followed by `# ── Background updates ──`. Insert between them:

```yaml
  # ── Bazaar config ───────────────────────────────────────────────────────
  # Curated-recommends page, blocklist, and the boot-time `flatpak override`
  # that grants Bazaar read-only access to /etc so it can read them. Bazaar
  # itself is a --system flatpak from the preinstall service above, not an
  # element. Ported from projectbluefin/common. Closes #245.
  - config/bazaar-config.bst
```

Place it after the preinstall block rather than in the `# ── Config ──` group at lines
254-263: the element is meaningless without the flatpak that block installs, and adjacency
is the only thing that records the dependency (a BST `depends:` edge would be wrong — there
is no build-time relationship). Do not reorder or reformat the existing entries.

- [ ] **Step 2: Resolve the graph**

```bash
mise run validate
```

Must exit 0 with `oci/krytis/image.bst` resolving.

---

### Task 6: Skill write-back — same commit, not a follow-up

**Files:**
- Modify: `docs/skills/bst.md`
- Modify: `docs/SKILL.md`

**Interfaces:** none. Required by `AGENTS.md` § Skill-improvement mandate.

- [ ] **Step 1: Fix the stale claim in `docs/skills/bst.md` § Flatpak Pre-install Service Pattern**

The bullet currently reads, in part:

> Accessing `/etc` from a flatpak requires a permission override delivered via a tmpfiles
> symlink (see issue #245 for full porting notes).

Two defects, both of the classes `AGENTS.md` § *What the first sweep learned about how rot
gets in* names:

- **Wrong mechanism.** It describes Bluefin's tmpfiles `L` symlink, which decision 3 above
  establishes does not work on a read-only `/usr`. It also contradicts
  `docs/skills/desktop.md`, which already states `flatpak override --system` is the only
  safe writer for override files.
- **Conditional framing that is about to outlive its decision.** "see issue #245 for full
  porting notes" points at an issue this PR closes. Per the same AGENTS.md section, an
  `#<n>` in a doc whose GitHub state is CLOSED is the strongest rot signal in this repo.

Rewrite the bullet to name the shipped mechanism (`flatpak override --system
--filesystem=host-etc:ro` from `bazaar-host-etc.service`), cite
`elements/config/bazaar-config.bst`, and drop the forward reference.

- [ ] **Step 2: Add a `## Bazaar curated config and the host-etc permission` section to
  `docs/skills/bst.md`**

Content, each entry a thing discovered rather than assumed:

- The config path is a **compile-time** meson option in the Flathub build
  (`-Dhardcoded_main_config_path`), not a search path — so `/etc/bazaar/bazaar.yaml` is the
  only file Bazaar will ever read, and `config.yaml` / `blocklist.txt` are decoys from the
  other two `-Dhardcoded_*` options.
- Without the override, `/run/host/etc` does **not exist** inside the sandbox — quote the
  `ls: cannot access` probe. The failure mode is silent: no Curated tab, no log line.
- `host-etc:ro` is sufficient; the write probe result.
- `flatpak override` works on a not-yet-installed app, so no unit ordering is needed.
- Why the tmpfiles `L` symlink does not port to a composefs `/usr`.
- Bazaar ≥ 0.9 requires the modern `rows: [- banner:, - section:]` schema; `v0.8.2`'s
  `css:` + `rows: - sections:` is rejected. Name the version the claim was verified against
  and the command (`flatpak info io.github.kolunmi.Bazaar`), per AGENTS.md's rule that an
  inventory-style assertion must cite the command that produced it.
- Banners accept `light-color`/`dark-color` gradients with no `image:` — no JXL/PNG
  pipeline is required.
- Name the owning repo for every upstream path cited (`projectbluefin/common`
  `system_files/bluefin/etc/bazaar/…`, `flathub/io.github.kolunmi.Bazaar`), per AGENTS.md's
  rule that a bare backticked path is indistinguishable from a first-party one.

- [ ] **Step 3: Add a `docs/SKILL.md` router row**

Check first whether an existing row would lead an agent here — the closest are the two
`docs/skills/bst.md` rows and the `docs/skills/desktop.md` row, neither of which mentions
Bazaar. Add one row rather than a redundant second:

```markdown
| Change Bazaar's curated app list, blocklist, or its `/etc` access permission | [`docs/skills/bst.md`](skills/bst.md) § Bazaar curated config and the host-etc permission |
```

- [ ] **Step 4: Check the neighbouring section for drift while you are in there**

`AGENTS.md` § *Skill files rot too — prune, don't just append*: `docs/skills/bst.md` is
already 3300+ lines. The § Flatpak Pre-install Service Pattern bullets being edited in
Step 1 are the immediate neighbourhood — verify the other bullets there still match
`files/flatpak-preinstall/` as it exists today, and fix or cut in this same pass rather
than only appending.

---

### Task 7: Verification

**Files:** none.

- [ ] **Step 1: Graph + full build**

```bash
mise run validate
mise run build
```

`build` chains `generate-image-version` → `load-image` → `lint` → `umbriel-config-validate`.
Do not run `mise run lint` separately — it re-lints the same image.

- [ ] **Step 2: In-image path assertion**

```bash
podman run --rm --entrypoint= localhost/krytis:latest sh -c '
  ls -l /etc/bazaar/
  ls -l /usr/libexec/krytis/bazaar-host-etc.sh
  cat /usr/lib/systemd/system-preset/73-krytis-bazaar-host-etc.preset
'
```

Required: three `.yaml` files mode 644, the script mode 755, and
`enable bazaar-host-etc.service`.

- [ ] **Step 3: Boot test — assert the override was actually applied**

```bash
mise run boot-test
```

Then in the booted VM:

```bash
systemctl is-active bazaar-host-etc.service      # → active (exited)
cat /var/lib/flatpak/overrides/io.github.kolunmi.Bazaar
# → [Context]
#   filesystems=host-etc:ro;
```

This is the half that proves the plan's central mechanism. A green `boot-test` alone does
not — the unit could have failed and nothing else would notice.

- [ ] **Step 4: Runtime smoke test — the actual proof**

In a booted krytis session (hardware or a graphical VM), after
`flatpak-preinstall.service` has installed Bazaar:

```bash
flatpak run --command=sh io.github.kolunmi.Bazaar -c 'ls /run/host/etc/bazaar'
# → bazaar.yaml  blocklist.yaml  curated.yaml
```

Then launch Bazaar and confirm, in order:

1. A **Curated** tab appears in the header bar. (Upstream: the tab only appears "if Bazaar
   is provided a non-zero amount of curated configs" — its absence is the single signal
   that the config was not read.)
2. Each section renders with its gradient banner and populated app tiles.
3. Searching for a blocked ID — e.g. `Bazaar` itself — returns no result.
4. Searching for an unblocked curated app returns it.
5. The auto-update toggle is absent from Preferences (`hide-auto-update-options: true`).

Curated configs are watched for filesystem events and reload live, so iterating on
`curated.yaml` during this step does not need a restart.

- [ ] **Step 5: Pre-merge sanity on the app list**

Blocked or curated IDs that no longer exist on Flathub fail silently. Before merge:

```bash
while read -r id; do
  flatpak remote-info flathub "$id" >/dev/null 2>&1 || echo "MISSING: $id"
done < <(grep -oP '^\s+-\s+\K[a-z][a-z0-9_]*(\.[A-Za-z0-9_-]+)+$' files/bazaar/curated.yaml files/bazaar/blocklist.yaml | sort -u)
```

Report any `MISSING:` lines in the PR rather than silently dropping them — a delisted app
is a fact about Flathub worth recording, and may be an upstream rename to follow.

- [ ] **Step 6: Docs and SBOM gates**

```bash
mise run docs-links
mise run sbom
mise run vuln-scan
```

`docs-links` is the gate for Task 6 — note it resolves `<path>.md § <anchor>` citations, so
the new `docs/SKILL.md` row's `§ Bazaar curated config and the host-etc permission` must
match the heading written in Step 2 exactly. `vuln-scan`'s match count should be unchanged:
this PR adds no binaries.

---

### Task 8: Close out

- [ ] **Step 1:** Confirm the `AGENTS.md` pre-PR checklist — skill file updated and present
  in this PR's commits (Task 6), not a follow-up.
- [ ] **Step 2:** `mise run docs-links` clean.
- [ ] **Step 3:** `git mv docs/plans/2026-09-29-bazaar-curated-recommends.md docs/plans/done/`
  in the merging PR, per `AGENTS.md` § Plan & Design Docs.
- [ ] **Step 4:** Open the PR against `main` with `Closes #245`, the Task 7 evidence, and an
  explicit list of any gate not run in-session. Include the ownership table from Task 2
  Step 2 and state that `curated.yaml` ships a skeleton whose app lists the curation
  session fills in a follow-up PR (decision 10). Merge is a human decision.

**Does this PR close #245?** Yes — #245 is "add bazaar curated recommends" and the
mechanism is what was missing; a Curated tab that renders is the deliverable. The app list
arriving later is a content change to one file, not unfinished wiring. If the human would
rather hold #245 open until the list lands, say so before merge and use `Refs #245`.

---

## Open questions for the human

1. **Gradient palette.** Task 2 Step 2 proposes deriving banner gradients from noctalia's
   shipped palette. If krytis has branding art intended for this surface, say so — it
   changes decision 2 and adds a `files/bazaar/` image asset.
2. **CLI-editor blocklist.** Decision 8 deliberately does *not* port Bluefin's
   nvim/vim/helix/emacs blocks. If krytis would rather hide those too, that is a one-line
   change to `blocklist.yaml` — but note krytis offers no alternative install path for them.
3. **Section list.** Task 2 Step 2 creates Bluefin's ten sections so mined candidates drop
   into an existing home. If the curation session expects to define its own sections, the
   skeleton should ship fewer — tell it before that session starts, since an empty section
   renders as a bare banner with no tiles.

---

## Sources verified for this plan (2026-09-29)

| Claim | Source | Method |
|---|---|---|
| Bazaar 0.9.5 on Flathub stable | local install | `flatpak info io.github.kolunmi.Bazaar` |
| Config path is compile-time | `flathub/io.github.kolunmi.Bazaar` manifest | fetched raw |
| Modern `rows:` schema; legacy rejected ≥0.9 | `bazaar-org/bazaar/docs/overview.md`, `bazaar-org/bazaar/docs/example.yaml`; `projectbluefin/common/docs/skills/bazaar.md` | fetched raw |
| Gradient banner needs no image | `bazaar-org/bazaar/docs/example.yaml` | fetched raw |
| `/run/host/etc` absent without override | local sandbox probe | `flatpak run --command=sh … -c 'ls /run/host/etc'` |
| `host-etc:ro` readable, not writable | local sandbox probe | `--user` override, then `touch`; reverted |
| `flatpak override` works on uninstalled app | local probe | `flatpak override --user … com.example.NotInstalled` → rc=0; reverted |
| Bluefin's tmpfiles/override/service/blocklist/curated content | `projectbluefin/common` `system_files/bluefin/…` | fetched raw |
| krytis's native app set | `elements/stacks/desktop-apps.bst`, `elements/desktop/` | read |
| No `config/*.bst` in the tracking workflow | `.github/workflows/track-bst-sources.yml` | grep |
| `docs/plans` exempt from docs-links path checks | `mise/tasks/docs-links` | read |
