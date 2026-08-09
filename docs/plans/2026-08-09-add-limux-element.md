# Add limux terminal workspace element — Implementation Plan

**Issue:** #550

**Goal:** Ship [limux](https://github.com/am-will/limux) 0.1.23 — a GPU-accelerated terminal *workspace* manager (embedded Ghostty renderer, splits, tabs, folder-named persistent workspaces, browser pane, and a CLI an agent can drive from inside its own pane) — as `elements/desktop/limux.bst`, wired into `stacks/desktop-apps.bst`, with a working automated update path.

**Architecture:** Prebuilt upstream tarball, `kind: manual`, exactly the shape `desktop/zed.bst` / `desktop/warp.bst` / `desktop/proton-pass.bst` already use. Three ELF payloads (`limux` CLI, `limux-host` GTK app, bundled `libghostty.so`) plus Ghostty resources, icons, `.desktop`, metainfo. A second tiny element (`config/limux-ldconfig.bst`) puts the bundled `libghostty.so` on the dynamic linker's search path, because the binaries' baked RUNPATH points at `/usr/local/lib/limux`, which does not exist in a bootc image.

**Tech stack:** BuildStream 2 `kind: manual` + `kind: tar` source, `gnome-build-meta.bst:sdk/webkitgtk-6.0.bst`, mise task + `track-bst-sources.yml` job for the update path.

---

## Decisions already made — do not relitigate mid-implementation

**1. Prebuilt tarball, not build-from-source.** Evidence collected while writing this plan:

| Fact | Value | How verified |
|---|---|---|
| Tarball | `limux-0.1.23-linux-x86_64.tar.gz`, `sha256:6d8eadcbd3817c26403899bdf1ecde69e4e1d8a206119596eead6f3322134a7a` | downloaded, `sha256sum` |
| Unpacked size | 35 MB (29 MB of it `libghostty.so`) | `du -sh` |
| glibc floor | `GLIBC_2.39` on all three ELFs; fdsdk 25.08 ships 2.42 | `objdump -T \| grep -oE 'GLIBC_[0-9]+\.[0-9]+' \| sort -Vu \| tail -1` |
| Arch coverage | x86_64 asset only — and `project.conf` `options.arch.values` lists **only** `x86_64`, so there is no gap to guard | release assets + `project.conf` |

Source-building was rejected: upstream publishes no vendored-deps tarball (so a generated `cargo2` block over a gtk4-rs + webkit6 crate graph would be needed — see `docs/skills/bst.md` § Rust / Cargo Projects), *and* the renderer is a **fork** submodule (`am-will/ghostty@81ab8ffa90185221782baf785e85387321e16f8d`, `.gitmodules` → `https://github.com/am-will/ghostty.git`) built with `zig build -Dapp-runtime=none`, whose Zig dependency set would need hand-pinning as ~40 `kind: remote` sources the way `elements/desktop/ghostty.bst` already does for upstream Ghostty 1.3.1. Two coupled source trees, neither trackable by `bst source track`. Not justified for a binary that already clears our glibc floor.

**2. WebKitGTK 6.0 is unavoidable and is the human decision gate.** `limux-host`'s `NEEDED` list contains `libwebkitgtk-6.0.so.4` and `libjavascriptcoregtk-6.0.so.1` — hard links, not `dlopen`, so the browser pane cannot be compiled out without forking upstream. krytis has no webkit today (`grep -rn webkit elements/` → empty; the only reverse-deps of `sdk/webkitgtk-6.0.bst` inside gnome-build-meta are `epiphany`, `gnome-builder`, `gnome-initial-setup`, `evolution-data-server`, `foundry`, `yelp`, `NetworkManager-openconnect`, `manuals`, `sdk-platform`, and krytis depends on **none** of them). Issue #550 states the cost. **Do not start Task 2 until the issue carries a human "accept the webkit build" comment.**

**3. Install to `/usr` with the upstream prefix layout, not a self-contained blob.** `limux-cli`'s `resolve_host_binary()` walks `current_exe().parent().parent().join("libexec/limux/limux-host")`, so `/usr/bin/limux` finds `/usr/libexec/limux/limux-host` with zero patching (`rust/limux-cli/src/main.rs`, `host_binary_candidates()`). Do **not** relocate into `%{indep-libdir}/limux/bin` the way `zed.bst` does — zed needs that for its `$ORIGIN/../lib` RPATH; limux does not, and relocating would break host discovery.

**4. `libghostty.so` goes to `%{indep-libdir}/limux/` plus an `ld.so.conf.d` entry — not into `%{libdir}` directly.** Both binaries carry `RUNPATH: /usr/local/lib/limux`, and bootc's `/usr/lib/tmpfiles.d/10-bootc.conf` makes `/usr/local` a symlink to `/var/usrlocal`, i.e. empty runtime state on every boot (see `docs/skills/bst.md` § Never install payload content under `/opt` — same mechanism). Dumping a bundled 29 MB `libghostty.so` into the shared `%{libdir}` would put a vendored copy on every binary's default search path; a private directory plus `/etc/ld.so.conf.d/limux.conf` keeps it scoped. `elements/oci/krytis/image.bst` already runs `ldconfig -r /layer -f /layer/etc/ld.so.conf` during assembly, so the cache is baked at build time — exactly how `config/codecs-extra-ldconfig.bst` works.

**5. Do not make limux the default terminal.** `xdg-terminal-exec`'s `xdg-terminals.list`, niri keybinds, and noctalia config stay untouched. limux ships as one more app in `desktop-apps.bst`.

## Global Constraints

- No RPMs, no dnf, no container overlays — BST elements only (`AGENTS.md`). The upstream `.rpm`/`.deb`/`.AppImage` assets exist; use the plain tarball.
- **Update path gate:** `bst source track` is a no-op on `kind: tar`, so Task 5 (`mise run limux-update` + a `track-limux` CI job) is mandatory, not optional (`AGENTS.md` § Update path gate, `docs/skills/bst.md` § Element update path).
- **Mise task integrity:** every step below is either an existing `mise` task or adds one. No loose shell maintenance commands.
- **Skill write-back lands in the same commit** as the change that produced the learning (`AGENTS.md` § Skill-improvement mandate). Task 6 is not a follow-up.
- `mise lint` must pass and the image must be shown to boot before requesting review. If this session cannot run the BST-build-dependent gates (a full build is a documented multi-hour job), say so explicitly in the PR and list what still needs running — do not claim untested things as verified.
- Worktree: `.worktrees/feat/gh550-add-limux-terminal-workspace-element`, branch `550-add-limux-terminal-workspace-element` (top-level issue, no `parent:`).
- **Sandbox tool floor:** `runtime-minimal.bst` gives a shell, `install`, `cp`, `ln` — but **no `sed`, `grep`, or `find`** (`docs/skills/bst.md` § Prebuilt Binary Elements — Sandbox Tool Availability). Every install command below is written to that floor; do not reintroduce upstream's `sed`-based desktop-file rewriting.

---

### Task 1: Prove the webkit dependency resolves and builds

**Files:** none (verification only).

**Interfaces:** produces the two facts Task 2's `depends:` relies on — that `gnome-build-meta.bst:sdk/webkitgtk-6.0.bst` builds in this project's junction context, and that its sonames match what `limux-host` asks for.

- [ ] **Step 1: Confirm the element resolves in krytis's junction context**

```bash
mise run bst show gnome-build-meta.bst:sdk/webkitgtk-6.0.bst
```

Watch for the "loaded in multiple contexts" plugin-junction failure mode documented in `docs/skills/bst.md` § Multiple Plugin Junction Contexts. krytis already consumes ~50 gnome-build-meta elements including `sdk/gtk.bst` and `sdk/libsoup.bst` (webkit's two extra `depends`), so this is expected to pass; if it does not, stop and report — nothing below works without it.

- [ ] **Step 2: Build it (long — hours)**

```bash
mise run bst build gnome-build-meta.bst:sdk/webkitgtk-6.0.bst
```

- [ ] **Step 3: Verify the sonames match `limux-host`'s NEEDED entries**

```bash
mise run bst artifact checkout --tar /tmp/webkit.tar gnome-build-meta.bst:sdk/webkitgtk-6.0.bst
tar tf /tmp/webkit.tar | grep -E 'libwebkitgtk-6\.0\.so|libjavascriptcoregtk-6\.0\.so'
```

Required: `libwebkitgtk-6.0.so.4` and `libjavascriptcoregtk-6.0.so.1` (major-soname match; the patch component is irrelevant). Upstream webkitgtk in this junction is 2.52.x per `elements/sdk/webkitgtk.inc`. If either major differs, `limux-host` will not start and this plan needs a rethink — report rather than patching around it. (Artifact checkouts go under `/tmp`, never the repo — `docs/skills/bst.md` § Artifact Checkouts.)

---

### Task 2: Create `elements/desktop/limux.bst`

**Files:**
- Create: `elements/desktop/limux.bst`

**Interfaces:**
- Consumes: `gnome-build-meta.bst:sdk/webkitgtk-6.0.bst` (Task 1).
- Produces: `/usr/bin/limux`, `/usr/libexec/limux/limux-host`, `/usr/lib/limux/libghostty.so`, `/usr/share/limux/**`, `/usr/share/icons/hicolor/**/limux*`, `/usr/share/applications/dev.limux.linux.desktop`, `/usr/share/metainfo/dev.limux.linux.metainfo.xml`. Task 3 depends on the `/usr/lib/limux` path; Task 4 wires the element in; Task 5's `sed` regexes target the `version:` variable and the `ref:` line.

- [ ] **Step 1: Confirm `%{libexecdir}` expands to `/usr/libexec`**

```bash
mise run bst show --format '%{vars}' desktop/zed.bst | grep -E '^(libexecdir|indep-libdir|datadir|bindir):'
```

fdsdk's `include/install-dirs.yml` overrides `lib`, `indep-libdir`, `licensedir` and friends but **not** `libexecdir`, so BuildStream's built-in `%{prefix}/libexec` should apply. If it expands to anything else, use the literal expansion in Step 2 — `limux-cli` hardcodes the `libexec/limux/limux-host` suffix relative to the prefix and cannot be redirected without `LIMUX_HOST_BIN`.

- [ ] **Step 2: Write the element**

```yaml
kind: manual

# Limux: GPU-accelerated terminal workspace manager (https://github.com/am-will/limux).
# Embedded Ghostty renderer, split panes, tabbed terminals, persistent
# folder-named workspaces, WebKitGTK browser panes, and a CLI (limux notify /
# new-pane / send / agent-team) that a coding agent can drive from inside its
# own pane. Closes #550.
#
# Prebuilt upstream tarball — x86_64 only (no aarch64 asset; project.conf's
# arch option is x86_64-only anyway). All three ELFs need GLIBC_2.39; fdsdk
# 25.08 ships 2.42.
#
# Installed with the upstream /usr prefix layout on purpose: limux-cli's
# resolve_host_binary() derives <prefix>/libexec/limux/limux-host from
# current_exe(), so /usr/bin/limux finds /usr/libexec/limux/limux-host with no
# patching. Do NOT relocate under %{indep-libdir}/limux/bin the way zed.bst
# does — that would break host discovery.
#
# The bundled libghostty.so lands in %{indep-libdir}/limux/ and is made
# findable by config/limux-ldconfig.bst: both binaries carry
# RUNPATH=/usr/local/lib/limux, and /usr/local is a symlink to /var/usrlocal
# (bootc tmpfiles), i.e. empty runtime state on every boot.
#
# webkitgtk-6.0 is a hard NEEDED of limux-host (libwebkitgtk-6.0.so.4,
# libjavascriptcoregtk-6.0.so.1) — the browser pane is not optional. It is the
# only reason webkit enters the krytis image at all.
#
# Upstream ships no LICENSE file in the repo or the tarball (Cargo.toml
# declares MIT), so fdsdk's %{install-extra} licence harvest finds nothing for
# this element. Ghostty's own MIT text is already in the image via
# desktop/ghostty.bst.
#
# Update path: mise run limux-update / track-limux CI job.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/fontconfig.bst
- gnome-build-meta.bst:sdk/gtk.bst
- gnome-build-meta.bst:sdk/libadwaita.bst
- gnome-build-meta.bst:sdk/webkitgtk-6.0.bst

variables:
  version: "0.1.23"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  # install.sh is deliberately not shipped — its /etc/ld.so.conf.d write is
  # config/limux-ldconfig.bst's job, and its ldconfig/gtk-update-icon-cache
  # calls are handled by image.bst's assembly step.
  - install -Dm755 limux "%{install-root}%{bindir}/limux"
  - install -Dm755 libexec/limux/limux-host "%{install-root}%{libexecdir}/limux/limux-host"
  - install -Dm755 lib/libghostty.so "%{install-root}%{indep-libdir}/limux/libghostty.so"

  # Ghostty themes + shell-integration + terminfo. limux-host probes
  # <prefix>/share/limux/ghostty first, then /usr/share/ghostty; ship the
  # fork's own copy rather than relying on desktop/ghostty.bst's 1.3.1 tree.
  - install -d "%{install-root}%{datadir}"
  - cp -a share/limux "%{install-root}%{datadir}/"

  # Exec=/TryExec=limux are left as the bare command name (resolved via PATH):
  # upstream's install.sh rewrites them with sed, which runtime-minimal does
  # not provide, and a bare name is valid per the desktop-entry spec.
  - install -Dm644 share/applications/dev.limux.linux.desktop "%{install-root}%{datadir}/applications/dev.limux.linux.desktop"
  - install -Dm644 share/metainfo/dev.limux.linux.metainfo.xml "%{install-root}%{datadir}/metainfo/dev.limux.linux.metainfo.xml"
  - install -d "%{install-root}%{datadir}/icons"
  - cp -a share/icons/hicolor "%{install-root}%{datadir}/icons/"
  - "%{install-extra}"

sources:
- kind: tar
  url: github_files:am-will/limux/releases/download/v0.1.23/limux-0.1.23-linux-x86_64.tar.gz
  ref: 6d8eadcbd3817c26403899bdf1ecde69e4e1d8a206119596eead6f3322134a7a
```

Notes for the implementer:
- The tarball's single top-level `limux-0.1.23-linux-x86_64/` directory is stripped by `kind: tar`'s default `base-dir: '*'`, so the staged root is `limux`, `lib/`, `libexec/`, `share/`, `install.sh`.
- `install -Dm755` on `libghostty.so` is correct: BST clamps artifact file modes to 644/755 (`docs/skills/bst.md` § `install -Dm###` modes are clamped), and a shared library wants the executable bit.
- `strip-binaries: ''` **and** `strip-commands: [':']` — the payload is already stripped upstream and re-stripping a vendored `.so` risks breaking it. Same as `zed.bst`/`warp.bst`.
- `fatal-warnings: overlaps` is on. `share/icons/hicolor/**` file names are all `limux*`, so no file collides with `hicolor-icon-theme`, `papirus-icon-theme`, or `adw-gtk3`; directories are not overlaps. If a collision does appear, do **not** reach for `overlap-whitelist` — report it, because it would mean upstream started shipping a generic filename.

- [ ] **Step 3: Build it standalone**

```bash
mise run bst build desktop/limux.bst
mise run bst artifact checkout --tar /tmp/limux-artifact.tar desktop/limux.bst
tar tf /tmp/limux-artifact.tar | grep -vE 'share/limux/ghostty/themes/'
```

Expect exactly the paths listed under **Produces** above, and no `install.sh`.

---

### Task 3: Create `elements/config/limux-ldconfig.bst`

**Files:**
- Create: `elements/config/limux-ldconfig.bst`

**Interfaces:**
- Consumes: the `/usr/lib/limux` path produced by Task 2 (path only; no BST dependency edge is needed — the file is a static config).
- Produces: `/etc/ld.so.conf.d/limux.conf`, consumed by `image.bst`'s existing `ldconfig -r /layer -f /layer/etc/ld.so.conf` step.

- [ ] **Step 1: Write the element** (mirror `elements/config/codecs-extra-ldconfig.bst` exactly — same `kind`, same `strip-binaries: ''`, same `install -Dm644 /dev/stdin` heredoc)

```yaml
kind: manual

# Adds /usr/lib/limux to the dynamic linker search path so limux-host can
# find its bundled libghostty.so.
#
# Both limux binaries are built with RUNPATH=/usr/local/lib/limux (upstream's
# install.sh default prefix), but bootc's /usr/lib/tmpfiles.d/10-bootc.conf
# makes /usr/local a symlink to /var/usrlocal — runtime state, empty on every
# fresh boot — so the baked RUNPATH can never resolve in a krytis image.
# desktop/limux.bst installs the library to %{indep-libdir}/limux instead, and
# this entry is what makes it findable. Kept out of the shared %{libdir} so a
# vendored 29 MB libghostty.so is not on every binary's default search path.
#
# oci/krytis/image.bst runs `ldconfig -r /layer -f /layer/etc/ld.so.conf` at
# assembly time, so the cache is baked into the image — nothing runs at boot.
# Closes #550.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm644 /dev/stdin \
        "%{install-root}/etc/ld.so.conf.d/limux.conf" <<'EOF'
    %{indep-libdir}/limux
    EOF
  - "%{install-extra}"
```

- [ ] **Step 2: Build and inspect**

```bash
mise run bst build config/limux-ldconfig.bst
mise run bst artifact checkout --tar /tmp/limux-ldconfig.tar config/limux-ldconfig.bst
tar xOf /tmp/limux-ldconfig.tar etc/ld.so.conf.d/limux.conf
```

Must print `/usr/lib/limux`. If it prints an unexpanded `%{indep-libdir}`, the variable was quoted wrong in the heredoc.

---

### Task 4: Wire both elements into `stacks/desktop-apps.bst`

**Files:**
- Modify: `elements/stacks/desktop-apps.bst`

**Interfaces:** consumes Tasks 2 and 3; produces the graph edge every verification step in Task 7 relies on.

- [ ] **Step 1: Append a section in the existing commented style**

```yaml
  # ── Terminal workspace manager ─────────────────────────────────────────────
  # limux: GPU-accelerated workspace manager with embedded Ghostty, splits,
  # tabs, browser panes, and an agent-drivable CLI. Prebuilt tarball, x86_64.
  # Pulls webkitgtk-6.0 into the image (hard NEEDED of limux-host). Closes #550.
  - desktop/limux.bst
  # /etc/ld.so.conf.d entry for limux's bundled libghostty.so — the binaries'
  # RUNPATH points at /usr/local, which is /var state under bootc.
  - config/limux-ldconfig.bst
```

Place it after the existing `desktop/warp.bst` **Terminal** block. Do not reorder or reformat the existing entries.

- [ ] **Step 2: Resolve the graph**

```bash
mise run validate
```

Must exit 0 with `oci/krytis/image.bst` resolving. `unaliased-url` is a fatal warning, so a bad `url:` in Task 2 surfaces here — `github_files:` is the existing alias (`include/aliases.yml`), do not add a new one.

---

### Task 5: Update path — `mise run limux-update` + `track-limux` CI job

**Files:**
- Create: `mise/tasks/limux-update`
- Modify: `.github/workflows/track-bst-sources.yml`

**Interfaces:** consumes Task 2's `version:` variable and `ref:` line shape. Produces the automated bump PR path required by `AGENTS.md` § Update path gate option (b).

- [ ] **Step 1: Write `mise/tasks/limux-update`**

Model it on `mise/tasks/zed-update`, minus the arch loop (limux publishes x86_64 only). Required shape:

```bash
#!/usr/bin/env bash
#MISE description="Update limux element to the latest stable release"

set -euo pipefail

ELEMENT="elements/desktop/limux.bst"

echo "==> Fetching latest am-will/limux release..."
LATEST_TAG=$(gh api repos/am-will/limux/releases/latest --jq '.tag_name')
LATEST_VER="${LATEST_TAG#v}"
CURRENT_VER=$(grep -oP 'version: "\K[^"]+' "${ELEMENT}" | head -1)

echo "==> Latest: ${LATEST_VER}  Current: ${CURRENT_VER}"
if [ "${LATEST_VER}" = "${CURRENT_VER}" ]; then
  echo "==> Already up to date (${CURRENT_VER})"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TARBALL="limux-${LATEST_VER}-linux-x86_64.tar.gz"
URL="https://github.com/am-will/limux/releases/download/${LATEST_TAG}/${TARBALL}"
echo "==> Downloading ${URL}..."
curl -sSfL "$URL" -o "${TMPDIR}/${TARBALL}"
SHA256=$(sha256sum "${TMPDIR}/${TARBALL}" | awk '{print $1}')
echo "    sha256=${SHA256}"

sed -i "s|limux-${CURRENT_VER}-linux-x86_64.tar.gz|${TARBALL}|" "${ELEMENT}"
sed -i "s|/v${CURRENT_VER}/|/v${LATEST_VER}/|g" "${ELEMENT}"
sed -i "s|version: \"${CURRENT_VER}\"|version: \"${LATEST_VER}\"|" "${ELEMENT}"
sed -i "/limux-${LATEST_VER}-linux-x86_64.tar.gz/{n;s|ref: .*|ref: ${SHA256}|}" "${ELEMENT}"

echo "==> Done: ${CURRENT_VER} → ${LATEST_VER}. Run 'mise run validate' to verify."
```

`chmod +x` it. Verify idempotence and correctness by running it twice: the first run should either bump or report up-to-date, the second must report up-to-date and leave `git diff` clean.

- [ ] **Step 2: Add the `track-limux` CI job**

In `.github/workflows/track-bst-sources.yml`:
1. Add `limux` to `workflow_dispatch.inputs.group.options` (the list around lines 13–43), alphabetically-adjacent placement is fine; the list is not sorted.
2. Copy the `track-zed` job (currently at line 1683) verbatim and change: job name → `track-limux`; the `group == 'zed'` guard → `'limux'`; every `elements/desktop/zed.bst` → `elements/desktop/limux.bst`; `mise run zed-update` → `mise run limux-update`; `BRANCH="auto/track-zed"` → `auto/track-limux`; the PR title/body strings and the **Source**/**Releases** table rows → limux's GitHub URLs.

Keep every `uses:` pinned to the same full commit SHAs the neighbouring jobs use (`AGENTS.md` § SHA pinning) — copy, never re-resolve to a tag.

- [ ] **Step 3: Validate the workflow and trigger it on this branch**

```bash
mise run renovate-check   # only if renovate.json5 was touched — it should not be
gh workflow run track-bst-sources.yml --ref 550-add-limux-terminal-workspace-element -f group=limux
gh run list --workflow track-bst-sources.yml --limit 1
```

Per `docs/skills/bst.md` § Verifying the CI job before merge, confirm end-to-end behaviour on the branch before the PR merges. On a branch the job runs `limux-update` and reports; the PR-creation steps are gated on `github.ref == 'refs/heads/main'`, so a green run with "Already up to date" is the expected pass.

---

### Task 6: Skill write-back — same commit, not a follow-up

**Files:**
- Modify: `docs/skills/bst.md`

**Interfaces:** none. Required by `AGENTS.md` § Skill-improvement mandate.

- [ ] **Step 1: Add a subsection under the prebuilt-binary material (near § Bundled-app tarballs with RPATH structure)**

Write these two lessons — both were discovered while scoping #550 and neither is currently in the tree:

1. **A prebuilt binary's RUNPATH pointing into `/usr/local` is dead on bootc.** `/usr/local` → `/var/usrlocal` (bootc tmpfiles), which is empty runtime state on every boot — the same trap already documented for `/opt`, but reached through RUNPATH rather than through payload paths. The fix pattern: install the bundled library to `%{indep-libdir}/<app>/` and ship an `/etc/ld.so.conf.d/<app>.conf` entry, because `image.bst` already runs `ldconfig -r /layer` at assembly time. Cross-reference `config/codecs-extra-ldconfig.bst` and `config/limux-ldconfig.bst`. Always `readelf -d` a prebuilt payload before writing the element; a plausible-looking RUNPATH is not a working one.
2. **Check the reverse-dependency set before assuming a junction library is "already there".** For #550: `grep -rn webkit elements/` is empty *and* none of the ~50 gnome-build-meta elements krytis consumes pulls `sdk/webkitgtk-6.0.bst` — so one prebuilt app added an hours-long WebKit build to the image. Recipe: `grep -rln '<element>.bst' <staged-junction>/elements` for reverse-deps, then intersect with `grep -rn '<junction>.bst:' elements/ | sed 's/.*://' | sort -u`. Note the AGENTS.md caveat that a static grep is not proof about a *live* system, only about the graph.

- [ ] **Step 2: If the element's `docs/SKILL.md` router has no row that would lead an agent here, add one.** Likely unnecessary — § Adding a Package already routes there — so check before editing rather than adding a redundant row.

---

### Task 7: Verification

**Files:** none.

- [ ] **Step 1: Graph + build + lint**

```bash
mise run validate
mise run build
mise run load-image
mise run lint
```

- [ ] **Step 2: SBOM / vuln surface**

```bash
mise run sbom
mise run vuln-scan
```

WebKit entering the image will move the vuln-scan match count. Triage per `.claude/skills/vuln-scan-triage/` — do **not** blanket-add ignores; if new genuine advisories appear against webkitgtk 2.52.x, report them in the PR rather than silencing them. Expect limux's own payload to contribute no SBOM package (hand-installed binaries have no purl, same as zed/warp).

- [ ] **Step 3: Boot test**

```bash
mise run boot-test
```

- [ ] **Step 4: Runtime smoke test — the actual proof**

In a booted VM or on hardware:

```bash
ldd /usr/libexec/limux/limux-host          # every entry resolved, incl. both webkit sonames + libghostty.so
ldconfig -p | grep libghostty              # baked cache resolves the private dir
limux --help                               # prints "limux CLI"
limux --version
```

Then, in a niri session: launch Limux from the app launcher (or run `limux` with no args), and confirm

- a terminal pane renders and accepts input (GPU path: this is `libghostty.so` + mesa),
- `Ctrl+Alt`-based split shortcuts create a second pane,
- a **browser** pane loads a page (this is the webkit payload the whole Design Gate was about),
- `limux notify --body test "hi"` from inside a pane raises a libadwaita toast,
- `limux identify --json` returns the pane/workspace IDs.

Record the results verbatim in the PR. If the browser pane fails, check whether WebKit's bubblewrap sandbox has what it needs — `xdg-dbus-proxy` and `bubblewrap` come in transitively via `sdk/webkitgtk-6.0.bst`'s own `depends`, and `bubblewrap` is separately in `stacks/dev-tools.bst`; `WEBKIT_DISABLE_SANDBOX=1` is a **diagnostic only**, never a shipped workaround.

---

### Task 8: Close out

- [ ] **Step 1:** Confirm the AGENTS.md pre-PR checklist: skill file updated and in this PR's commits (Task 6), same commit as the change that produced the learning.
- [ ] **Step 2:** `mise run docs-links` — fails on any `docs/…` reference that no longer resolves.
- [ ] **Step 3:** `git mv docs/plans/2026-08-09-add-limux-element.md docs/plans/done/` in the merging PR, per `AGENTS.md` § Plan & Design Docs — not as a separate follow-up.
- [ ] **Step 4:** Open the PR against `main` with `Closes #550`, the verification evidence from Task 7, and an explicit list of any gate that could not be run in-session. Merge is a human decision.
