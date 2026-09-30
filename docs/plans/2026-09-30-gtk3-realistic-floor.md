# Shrink GTK3 to its realistic floor

**Issue:** #641 · **Branch:** `641-investigate-dropping-gtk3` (this plan) · **Status: ready, not started.**

GTK3 ships in the image for 15 different reasons (#641 has the full map). Four of them krytis
cannot change: zen-browser, Equibop, Proton Pass and `xdg-desktop-portal-gtk` (#181, blocked).
This plan removes every other one. Afterwards GTK3 ships *only* because of those four, and
the eventual removal is theirs to unlock rather than an archaeology project.

Each step is independently landable as its own PR, in the order given. Steps 1–4 are cheap
and self-contained. Step 5 is the expensive one.

## Non-goals

- **#181 / `xdg-desktop-portal-gtk`.** Blocked, see [Why xdg-desktop-portal-gtk stays](#why-xdg-desktop-portal-gtk-stays).
- **`gtk+-3` itself.** Leave gnome-build-meta's element alone. `-Dbroadway_backend=false` would
  drop `broadwayd` and `im-broadway.so`, but overriding `sdk/gtk+-3.bst` rebuilds 61 elements
  (measured below) for two files.
- **`desktop/adw-gtk3.bst`, `config/gtk-settings.bst`.** They theme GTK3 for the floor apps and
  stay as long as those do.
- **Anything against gnome-build-meta or freedesktop-sdk.** The upstream candidates at the end
  are proposals only (AGENTS.md § Third-party repositories).
- **Portal routing.** The dead `portals/niri.portal` written by `config/xdg-portals.bst`, and
  Umbriel's missing Settings/Wallpaper backends, are real but not GTK3. File them separately.

## Baseline (measured 2026-09-30, `main` @ `88fba34`)

Junctions: fdsdk `freedesktop-sdk-26.08.2-0-g32c5fea7`, gnome-build-meta
`51.0-6-g5ec987b6`. Image: `localhost/krytis:latest` built the same day.

Ship set: runtime closure of `oci/krytis/stack.bst` (634 elements). Its members whose
`runtime-deps` name `gnome-build-meta.bst:sdk/gtk+-3.bst` (fdsdk's `components/gtk3.bst`
resolves to it through `elements/freedesktop-sdk.bst` `overrides:`):

| Element | GTK3-linked ELF in the image | Removed by |
|---|---|---|
| `desktop/zen-browser.bst` | `/usr/lib/zen-browser/{libxul.so,libmozgtk.so,gfxtest,updater}` | floor |
| `desktop/equibop.bst` | `/usr/lib/equibop/equibop` | floor |
| `gnome-build-meta.bst:core-deps/xdg-desktop-portal-gtk.bst` | `/usr/libexec/xdg-desktop-portal-gtk` | floor (#181) |
| `desktop/gnome-disk-utility.bst` | `/usr/bin/gnome-disks`, `/usr/bin/gnome-disk-image-mounter` | step 3 |
| `gnome-build-meta.bst:core-deps/libhandy.bst` | `libhandy-1.so.0` | step 3 (only consumer is gnome-disks) |
| `gnome-build-meta.bst:core-deps/xdg-user-dirs-gtk.bst` | `/usr/bin/xdg-user-dirs-gtk-update` | step 2 |
| `gnome-build-meta.bst:sdk/libportal.bst` | `libportal-gtk3.so.1` (zero consumers) | step 4 |
| `gnome-build-meta.bst:core/gnome-desktop.bst` | `libgnome-desktop-3.so.21` (consumers: only its own `/usr/libexec/gnome-desktop-debug/test-*`) | step 4 |
| `gnome-build-meta.bst:core-deps/libcanberra.bst` | `libcanberra-gtk3.so`, `gtk-3.0/modules/libcanberra-gtk3-module.so`, `/usr/bin/canberra-gtk-play` | step 4 |
| `freedesktop-sdk.bst:components/libdecor.bst` | `libdecor/plugins-1/libdecor-gtk.so` | step 5a |
| `freedesktop-sdk.bst:components/plymouth.bst` | `plymouth/renderers/x11.so` | step 5a |
| `freedesktop-sdk.bst:components/gstreamer-plugins-good.bst` | `gstreamer-1.0/libgstgtk.so` | step 5b |
| `freedesktop-sdk.bst:components/gstreamer-plugins-base.bst` | none (declared edge only, `-Dexamples=disabled`) | step 5b |

GTK3 consumers the graph query does **not** show:

| File | Owner | Why the graph misses it | Handled by |
|---|---|---|---|
| `/usr/lib/proton-pass/Proton Pass` | `desktop/proton-pass.bst` | the element declares only `runtime-gnu.bst`, even though the binary needs GTK3 | step 1 |
| `gstreamer-1.0/libgstgtkwayland.so` | `components/gstreamer-plugins-bad.bst` | finds GTK3 through plugins-base's runtime edge | step 5b |

Build-only, ships nothing: `gnome-build-meta.bst:sdk/libibus.bst`,
`gnome-build-meta.bst:sdk-deps/ibus.bst` (reached only through sdl3's `build-depends`).

The mechanism behind most rows: fdsdk builds with `-Dauto_features=enabled` and
gnome-build-meta with `--auto-features=enabled`. Every GTK3 backend whose meson option
defaults to `auto` is therefore **on** whenever GTK3 is in the sandbox. That covers libportal's
`backend-gtk3`, gstreamer's `gtk3`, libdecor's `gtk` and plymouth's `gtk`. gnome-desktop's
`legacy_library` is a plain boolean that defaults to `true`.

Do not measure with `files/fakecap-manifest.tsv`: it has no rows for
`desktop/gnome-disk-utility.bst` or `core-deps/libcanberra.bst`. Use step 0's task.

## Mechanisms (verified while writing this plan)

**Overriding a gnome-build-meta element works, and a redirect costs no rebuild.** Adding
`core-deps/xdg-user-dirs-gtk.bst: freedesktop-sdk.bst:components/xdg-user-dirs.bst` under
`elements/gnome-build-meta.bst` `config.overrides:` gave these results:

- `bst show --deps run gnome-build-meta.bst:core/nautilus.bst` listed
  `freedesktop-sdk.bst:components/xdg-user-dirs.bst` in place of `xdg-user-dirs-gtk`.
- `%{full-key}` of `core/nautilus.bst` stayed `b9f00495…` (it is a `runtime-depends:` edge).
- `%{full-key}` of `sdk/gtk.bst` stayed `30eb86e1…`, so adding the override entry does not
  perturb keys elsewhere.

This is the first gnome-build-meta-namespace override in krytis. The entry belongs in
`elements/gnome-build-meta.bst`, **not** `elements/freedesktop-sdk.bst`. The old "never in
`elements/gnome-build-meta.bst`" rule in `docs/skills/bst.md` § Mirroring a junction element
to patch its *source* was about systemd-base, which is referenced through the fdsdk namespace.
This plan's PR scopes that rule and adds § Overriding a gnome-build-meta-namespace element
and § Default-`auto` meson features are *on* in both junctions.

**Disabling the option is not enough; the dependency line must go too.** Every mirror in
steps 4–5 must remove `sdk/gtk+-3.bst` / `components/gtk3.bst` from `depends:`. A mirror that
only flips the option stops *linking* GTK3 but keeps it in the runtime closure, so the image
still ships it and step 0's graph half still reports the element.

**Mirror rules already in `docs/skills/bst.md`, all of which apply:**

- Copy the body; never use a cross-junction `(@)` include (§ Mirroring a junction element to
  patch its *source*).
- Re-namespace sibling deps. Replace `buildsystems/meson.bst` /
  `(@): include/gcc-for-recc.yml` the way `desktop/gnome-disk-utility.bst` does. Drop
  `target_arch`/`channel` conditionals (§ Overriding a Single freedesktop-sdk Component
  Element, steps 2–3).
- Keep the artifact layout identical. For each mirror, check whether a `kind: filter` with an
  `overlap-whitelist` consumes it before deciding on `project_licensedir` (§ Moving an element
  between projects moves its licence tree).
- The mirror resolves its variables in *krytis's* project scope. Diff
  `mise run bst -- show --deps none --format '%{vars}'` of the upstream element against the
  mirror, and pin any `meson-global` / `conf-global` difference (the `auto_features` setting
  above is exactly such a value).

**Rebuild cascade per override** (fixpoint over build scope, i.e. `build-depends` plus their
runtime closures, excluding stacks/oci/config; from the same graph dump):

| Override | Dependents that rebuild |
|---|---|
| xdg-user-dirs-gtk (redirect) | 0 |
| libportal | 1 (`core/nautilus.bst`) |
| gnome-desktop | 2 (nautilus, xdg-desktop-portal-gnome) |
| libcanberra | 2 (gnome-disk-utility, seance) |
| plymouth | 1 (`core/initramfs.bst`) |
| libdecor | 7 (sdl3, sdl2-compat, ffmpeg, gstreamer-libav, codecs-extra ffmpeg/libde265/libheif) |
| gstreamer-plugins-good | 1 (`core/gst-thumbnailers.bst`) |
| gstreamer-plugins-bad | 35, incl. `sdk/gtk.bst` |
| gstreamer-plugins-base | 53, incl. `sdk/gtk.bst`, libadwaita, gstreamer-plugins-rs, pipewire, niri, noctalia |
| all of steps 4–5 together | 50 distinct |
| `sdk/gtk+-3.bst` (rejected) | 61 |

No upstream artifact cache can serve krytis keys anyway (`project.conf`, x86_64_v3), so this
is a one-time rebuild into the bow cache, not a permanent cost.

## Step 0 — `mise run gtk3-audit` (measurement and ratchet)

Lands first, so every later step has a before/after and a regression guard.

`mise/tasks/gtk3-audit` (python3, like `mise/tasks/seance-update`):

1. **Graph half.** Run `mise run bst -- --no-colors show --deps all --format
   '%{name}|%{runtime-deps}' oci/krytis/stack.bst`, compute the runtime closure of
   `oci/krytis/stack.bst`, and report every member whose runtime deps include
   `gnome-build-meta.bst:sdk/gtk+-3.bst`.
2. **Image half.** Re-exec under `podman unshare` when not root, then
   `podman image mount ${IMAGE:-localhost/krytis:latest}`. Walk `usr/` (skip `usr/lib/debug`),
   and for each ELF (check the `\x7fELF` magic) read `DT_NEEDED` with `readelf -d`. Flag
   `libgtk-3.so.0`, `libgdk-3.so.0`, `libgailutil-3.so.0`, `libhandy-1.so.0`,
   `libcanberra-gtk3.so.0`, `libportal-gtk3.so.1` and `libgnome-desktop-3.so.*`. Unmount in a
   `finally`.
3. **Two allowlists** in the task, one for elements and one for path globs. Each row carries a
   reason and the step that removes it. The task **fails on any hit not in the allowlist**, and
   **fails on any allowlist row with no hit**. The second rule is the ratchet: a step that
   removes a consumer must delete its row, or the audit goes red.

Initial allowlist = the baseline tables above, so the task passes on `main`. Every later step
deletes its rows in the same PR.

**Verify:** passes against today's image. Delete one row and it fails, naming that row's
file. Add a bogus row and it fails as stale.

**Docs:** row in the `docs/skills/mise.md` task table. A short § in `docs/skills/bst.md`
explaining that a graph query misses undeclared DT_NEEDED consumers (Proton Pass,
plugins-bad) and that an ELF scan does not.

## Step 1 — Proton Pass declares its runtime deps

`elements/desktop/proton-pass.bst` `depends:` is only `runtime-gnu.bst`, yet `Proton Pass`
links:

```
libgtk-3.so.0 libnss3.so libnssutil3.so libsmime3.so libnspr4.so libatk-1.0.so.0
libatk-bridge-2.0.so.0 libatspi.so.0 libcups.so.2 libxkbcommon.so.0 libasound.so.2
libdbus-1.so.3 libudev.so.1 libgbm.so.1 libX11 … libxcb  (RPATH $ORIGIN → libffmpeg.so bundled)
```

It is the same set as Equibop's. Copy `elements/desktop/equibop.bst`'s `depends:` block and
its comments: gtk3, nss, at-spi2-core, libxkbcommon, alsa-lib, cups, dbus, systemd, and
`extensions/mesa/mesa.bst` for `libgbm.so.1`. Then apply § Runtime deps: read the ELF, then
add back the dlopens (`docs/skills/bst.md`) to *Proton Pass's* dlopens rather than copying
Equibop's list blind.

**Why now:** Proton Pass is part of the floor either way. Today it would break silently the
day zen-browser and Equibop stop pulling in GTK3.

**Verify:** `mise run bst -- show --deps run desktop/proton-pass.bst` lists the new deps;
`mise run build`; launch Proton Pass on a booted image. Graph half now reports
`desktop/proton-pass.bst` as a declared consumer: move its allowlist row from "undeclared" to
"floor".

**Cost:** rebuilds `desktop/proton-pass.bst` only (`kind: manual`).

## Step 2 — Drop `xdg-user-dirs-gtk`

It ships, but nothing ever runs it:

- the autostart entry is `OnlyShowIn=GNOME;LXDE;Unity;` + `X-systemd-skip=true`;
- `user-dirs-update-gtk.service` is `static`, and nothing in the image wants it;
- `~/.config/gtk-3.0/bookmarks`, which the program always creates when missing, does not
  exist on a krytis host in use since 2026-08-07.

The directories themselves come from `xdg-user-dirs.service` (fdsdk `components/xdg-user-dirs.bst`,
`WantedBy=graphical-session-pre.target`). Nautilus does not call the program; its only link
to it is gnome-build-meta's `runtime-depends:`.

**Change:** `elements/gnome-build-meta.bst` `config.overrides:` gets
`core-deps/xdg-user-dirs-gtk.bst: freedesktop-sdk.bst:components/xdg-user-dirs.bst`, with a
comment giving the reasons above. That is a redirect to the package it already depends on,
so no new element.

**Verify:** the key checks from *Mechanisms* (nautilus `%{full-key}` unchanged).
`mise run build`, then check that the image has no `/usr/bin/xdg-user-dirs-gtk-update` and no
`/etc/xdg/autostart/user-dirs-update-gtk.desktop`. `mise boot-test`, then on the VM: a fresh
user's login creates `~/.config/user-dirs.dirs` and `xdg-user-dirs.service` ran. Delete the
allowlist rows.

**Lost:** the "rename folders to the new language?" dialog after a locale change, and the
default GTK3 file-chooser bookmarks. Neither works today.

**Removal condition:** delete the override if gnome-build-meta drops the `runtime-depends:`.
If upstream renames the path, the override silently matches nothing (the same failure mode as
the systemd-base privatisation). Step 0's audit catches that: the element reappears in the
graph half.

**Docs:**

- `docs/skills/bst.md` § Overriding a gnome-build-meta-namespace element (added with this
  plan): swap the test entry for the real one and record the boot-test result.
- `docs/skills/desktop.md`: the autostart § (~line 1060) lists
  `core-deps/xdg-user-dirs-gtk.bst` as shipping an autostart entry. Remove it.

## Step 3 — gnome-disk-utility 51.beta

No stable 51 exists: `download.gnome.org/sources/gnome-disk-utility/` has `46/` then `51/`,
and `51/` has only `51.beta` (2026-07-30). gnome-build-meta's `gnome-51` stable arm keeps
46.1 ("until there is a release, we ship the gtk3 version"). The mirror therefore runs
**ahead** of the junction on purpose. The user asked for this explicitly.

**Tarball facts (downloaded and inspected):**

- `gnome_downloads:gnome-disk-utility/51/gnome-disk-utility-51.beta.tar.xz`, sha256
  `f181d793f0684f399bf76d297c0e3716849c78fa67292b765dbd9ec3dfa5c800`.
- Ships `vendor/` (247 crates) and `.cargo/config.toml` with `replace-with =
  "vendored-sources"`, covering the `udisks-rs` git dependency too. No `cargo2` source should
  be needed; the first sandbox build confirms that.
- `meson.build` requires `gtk4 >= 4.15.2`, `libadwaita-1 >= 1.8.alpha` (junction: 1.10.0),
  cargo, and `blueprint-compiler >= 0.19.0` (junction: 0.22.2). It also requires `dvdread`,
  `gio-unix`, `gmodule`, `liblzma`, `libnotify`, `libsecret`, `pwquality`, `udisks2` and
  `libsystemd` (logind). `Cargo.toml`: `rust-version = "1.85"`, `edition = "2024"`; check
  fdsdk's rust meets that.
- **No** `libcanberra`, `libhandy` or `gtk+-3` dependency anywhere.
- `-Dgsd_plugin=false` stays. In 51 the notifier is GTK4 and a systemd user unit,
  `gnome-disk-utility-notify.service`, with `PartOf=gnome-session.target` and no
  `[Install]`, so it still cannot start under niri. #726's decision stands.

**Change `elements/desktop/gnome-disk-utility.bst`:**

- the source (url/ref above);
- drop `core-deps/libcanberra.bst`, `core-deps/libhandy.bst` and `sdk/gtk+-3.bst`;
- add `gnome-build-meta.bst:sdk/gtk.bst` and `gnome-build-meta.bst:sdk/libadwaita.bst`;
- build-deps `gnome-build-meta.bst:sdk/blueprint-compiler.bst` and
  `freedesktop-sdk.bst:components/rust.bst`;
- reconcile against gnome-build-meta **master**'s element (its unconditional list plus the
  `nightly` arm) and the tarball's `meson.build`, per § A junction app can encode a feature you
  cannot run's "declare every `dependency()`" rule.

Also rewrite the header:

- The "Removal condition" paragraph is wrong. It implies the nightly arm is free of
  gnome-settings-daemon, but `core/gnome-settings-daemon.bst` sits in the **unconditional**
  `depends:` at `5ec987b6`.
- The libcanberra paragraph no longer applies.

**Update path** (AGENTS.md § Update path gate). Tying the source to the junction ref no longer
holds.

- `mise/tasks/tarball-update` gets a `gnome-downloads` provider. It reads
  `https://download.gnome.org/sources/<module>/cache.json` and is locked to one series, like
  `zig-series`, ordering `alpha < beta < rc < 0 < 1 …`.
- Add the row `gnome-disk-utility|elements/desktop/gnome-disk-utility.bst|gnome-downloads|gnome-disk-utility|51`,
  and `gnome-disk-utility` to the `track-tarball` matrix in
  `.github/workflows/track-bst-sources.yml`.
- Bump the series by hand with the junction's major.

**Rework `mise/tasks/gnome-disk-utility-check`:**

- **Source:** the equality check becomes "mirror version ≥ junction's pinned version". Fail
  when the junction catches up: then return to lockstep and delete the tarball-update row.
- **Deps:** `flatten_channel_block` selects the `nightly` arm instead of `stable`.
- **Ignore lists:** remove `sdk/blueprint-compiler.bst` from `UPSTREAM_IGNORES` (it is now a
  real dep) and `core-deps/libcanberra.bst` from `LOCAL_ADDITIONS`.
- The exit condition (upstream loses `core/gnome-settings-daemon.bst`) is unchanged.

**Beta risk.** This app partitions, formats and resizes disks. Before merging, read the 51.beta
NEWS and the upstream issue tracker for open data-loss or destructive-operation bugs, and note
the result in the PR.

**Verify:** `mise run build`, then `mise boot-test`. On the VM:

- `gnome-disks` opens (GTK4) and lists the virtio disk;
- a partition's details render;
- `gnome-disk-image-mounter <iso>` mounts;
- `mise run gnome-disk-utility-check` passes;
- `mise run tarball-update gnome-disk-utility` is a no-op.

Delete the allowlist rows for gnome-disk-utility and libhandy, which leaves the graph with the
mirror.

**Docs:**

- `docs/skills/bst.md` § A junction app can encode a feature you cannot run: the
  46.1-specific trap (`libcanberra-gtk3` at top level) becomes history, and the check-task
  notes change from "stable arm" to "nightly arm".
- `docs/skills/mise.md`: `gnome-disk-utility-check` row.

## Step 4 — gnome-build-meta mirrors: libportal, gnome-desktop, libcanberra

Depends on step 3: 46.1 needs `libcanberra-gtk3` at `meson setup`.

All three are override-target mirrors in `elements/overrides/<name>.bst`, wired through
`elements/gnome-build-meta.bst` `config.overrides:`. The body is copied verbatim from
gnome-build-meta at the junction SHA, plus the delta:

| Mirror | Remove | Add |
|---|---|---|
| `overrides/libportal.bst` | `sdk/gtk+-3.bst` | `-Dbackend-gtk3=disabled` in `meson-local` |
| `overrides/gnome-desktop.bst` | `sdk/gtk+-3.bst` | `-Dlegacy_library=false`. Keep the `qrcodegen` `git_repo` source and the `meson subprojects packagefiles --apply` configure command verbatim. |
| `overrides/libcanberra.bst` | `sdk/gtk+-3.bst`; the `libcanberra-gtk3.so` split-rule line | `conf-local: --disable-gtk3`. `runtime-depends: core-deps/xdg-sound-theme.bst` stays; seance needs plain `libcanberra.so.0`. |

**Drift check.** Add one table-driven `mise/tasks/gtk3-mirror-check` for all eight GTK3-strip
mirrors in steps 4–5, not eight near-identical `*-check` tasks.

- **Row:** `mirror|junction|upstream path|removed dep lines|added option tokens`.
- **Fetch:** the upstream element at the junction SHA (the gnome-build-meta ref from
  `elements/gnome-build-meta.bst`, the fdsdk ref from `elements/freedesktop-sdk.bst`).
- **Assertions:**
  1. source `url`/`ref` equal;
  2. upstream dep set minus the removed lines equals the mirror's set, normalised as in
     `gnome-disk-utility-check`;
  3. upstream `meson-local`/`conf-local` tokens plus the added tokens equal the mirror's;
  4. **exit condition:** if upstream already lacks the GTK3 dep or already sets the option,
     fail with "delete this mirror".
- Copy the three `grep`/`awk` lessons from § A junction app can encode a feature you cannot run.

**Verify:**

- `bst show` confirms each override resolves;
- the `%{vars}` diff is clean apart from the intended flag;
- `mise run build`, then `mise boot-test`. On the VM:
  - Nautilus opens and thumbnails;
  - a Flatpak or portal file chooser opens (niri routes FileChooser to xdp-gnome, which
    links `libgnome-desktop-4`);
  - seance launches (it links plain `libcanberra.so.0`, confirmed with `readelf`);
  - gnome-disks still opens.
- The image contains no `libportal-gtk3`, `libgnome-desktop-3` or `libcanberra-gtk3`.
- `mise run gtk3-mirror-check` passes. Delete the allowlist rows.

## Step 5a — freedesktop-sdk mirrors: libdecor, plymouth

**Breakage Gate (AGENTS.md):** plymouth is a build-dep of `core/initramfs.bst` and draws the
boot splash. Stop for human sign-off before merging.

Both mirrors go in `elements/overrides/`, wired through `elements/freedesktop-sdk.bst`
`config.overrides:`:

| Mirror | Remove | Add |
|---|---|---|
| `overrides/libdecor.bst` | `components/gtk3.bst` | `-Dgtk=disabled`. `libdecor-cairo.so` already ships as the fallback plugin. |
| `overrides/plymouth.bst` | `components/gtk3.bst` | `-Dgtk=disabled` (upstream: "if disabled, there is no X11 support"). This only drops `renderers/x11.so`; `drm.so` and `frame-buffer.so` don't link GTK3. |

Plymouth caveats:

- Its `kind: local` source `files/plymouth/plymouthd.defaults` resolves in *krytis's* project,
  so copy that file into this repo (the same reason `overrides/vim.bst` copies its patch).
- Check that a cross-junction reference to its build-dep `components/_private/git-minimal.bst`
  resolves.

Add both rows to `gtk3-mirror-check`.

**Verify:**

- `mise run build`, then `mise boot-test`;
- on a VM with a display, the splash renders at boot and, if the install uses LUKS, the
  passphrase prompt too;
- `/usr/lib/x86_64-linux-gnu/plymouth/renderers/` holds `drm.so` and `frame-buffer.so` and no
  `x11.so`;
- `libdecor-gtk.so` is absent and `libdecor-cairo.so` present.

The image has no SDL3 client to smoke-test client-side decorations with, so say so in the PR
rather than claiming it.

## Step 5b — freedesktop-sdk mirrors: gstreamer-plugins-{base,good,bad}

The expensive step: a one-time rebuild of about 50 elements, including GTK4, libadwaita,
gstreamer-plugins-rs, pipewire, niri and noctalia. It also carries a recurring resync cost,
because fdsdk moves gstreamer often. Consider it the prime upstream candidate. If fdsdk
accepts the change, skip this step.

- **Shared include.** All three fdsdk elements `(@)`-include `elements/include/gstreamer-source.yml`,
  which cannot be included across the junction. Copy it once to krytis
  `include/gstreamer-source.yml`, include it from all three mirrors, and have
  `gtk3-mirror-check` diff it as well.
- **base:** drop `components/gtk3.bst` and drop the `target_arch == "i686"` conditional (recipe
  step 3). No option change is needed: nothing it installs links GTK3.
- **good:** drop `components/gtk3.bst` and add `-Dgtk3=disabled` (removes `gtksink`/`gtkglsink`).
- **bad:** add `-Dgtk3=disabled` (removes `gtkwaylandsink`). It has no declared GTK3 dep to
  drop.

**Verify:**

- `gst-inspect-1.0 gtksink` and `gst-inspect-1.0 gtkwaylandsink` fail, and
  `gst-inspect-1.0 gtk4paintablesink` (gstreamer-plugins-rs) succeeds;
- Nautilus video thumbnails still generate (`core/gst-thumbnailers.bst`);
- screencast through the portal still works (pipewire and xdp rebuilt);
- delete the allowlist rows.

## Step 6 — Floor reached

- Step 0's allowlist equals the floor:
  - **elements:** `desktop/zen-browser.bst`, `desktop/equibop.bst`, `desktop/proton-pass.bst`,
    `gnome-build-meta.bst:core-deps/xdg-desktop-portal-gtk.bst`;
  - **files:** those four apps' ELF files, plus gtk+-3's own (`libgtk-3`, `libgailutil-3`,
    `immodules/*`, `printbackends/*`, `gtk-launch`, `gtk-query-*`,
    `gtk-encode-symbolic-svg`, `broadwayd`).
- `mise run build` and `mise boot-test` pass.
- Update #641's checklist.
- `git mv` this plan to `docs/plans/done/`.

## Why xdg-desktop-portal-gtk stays

Routing in the built image, and live on a krytis host:

- **niri session:** `niri-portals.conf` (niri upstream) is `default=gnome;gtk;` and pins
  `Access=gtk` and `Notification=gtk`. `gnome.portal` implements neither `Inhibit` nor `Email`,
  so those land on gtk too.
- **umbriel session:** `umbriel-portals.conf` is `default=umbriel;gtk`, and `umbriel.portal`
  only implements ScreenCast and Screenshot. Under Umbriel, xdp-gtk **is** the FileChooser,
  and also Print, Notification, Inhibit, Access, Account, Email and DynamicLauncher.
- **Live bus:** xdp-gtk bridges `Notification` to `org.freedesktop.Notifications` (owned by
  noctalia) and `Inhibit` to `org.freedesktop.ScreenSaver` (owned by niri). Nothing else in the
  image implements `org.freedesktop.impl.portal.Inhibit`.

Unblocking #181 needs a non-GTK3 backend for Inhibit and Notification that works under both
sessions, plus Umbriel routing that sends FileChooser, Print and Access to xdp-gnome. That is
a Design Gate decision, not part of this plan.

## Upstream candidates (propose only — Upstream Gate)

Each one accepted upstream deletes a krytis mirror and its `gtk3-mirror-check` row.

- **gnome-build-meta `sdk/libportal.bst`:** `-Dbackend-gtk3=disabled`, if nothing in GNOME OS
  uses `libportal-gtk3`.
- **gnome-build-meta `core/gnome-desktop.bst`:** `-Dlegacy_library=false`, if
  `libgnome-desktop-3` has no consumer left in GNOME OS.
- **freedesktop-sdk `components/gstreamer-plugins-base.bst`:** drop the dead
  `components/gtk3.bst` edge (examples are disabled, nothing links it). The `gtk3` sinks in
  good and bad are a harder sell, since Flatpak runtime users may want them.

## Proposed sub-issues

Each ≤ 5 words, parented to #641, so every step gets a `gh641/<n>-<slug>` worktree:
*Add GTK3 audit task* · *Declare Proton Pass dependencies* · *Drop xdg-user-dirs-gtk* ·
*Bump Disks to 51 beta* · *Strip GTK3 from GNOME mirrors* · *Strip GTK3 from fdsdk mirrors*
(5a and 5b as two PRs).
