# Carried patches and fork pins

Status: **current as of 2026-10-20**. Every patch krytis carries against a source it
does not own, and every element built from a fork, has one row in the
[Inventory](#inventory). `mise run patch-inventory-check` fails when an element and this
file disagree, and `checks.yml` runs it on every PR. Moved here from the body of
[#483](https://github.com/starlit-os/krytis/issues/483) in #1070. #483 stays open as the
tracking issue for work that may end up as a carried patch.

The table lived in the issue body until 2026-10-11, where no PR diff showed it and no
check could read it. The 2026-10-02 refresh (#1056 item 19) found six of nine carries
missing: efitools, ananicy-cpp, ghostty, oo7, xwayland-satellite and the
`kitten-lily/noctalia` fork pin. Every removal had been recorded (#1062, #1063), but no
addition had.

## Policy

A **carry** is any change krytis makes to a source it does not own. It is one of:

- a `kind: patch` or `kind: patch_queue` source on any element, including a junction
  element or a mirror under `elements/overrides/`;
- a fork pin: a source `url:` pointing at a fork in an org krytis owns (`kitten-lily/*`,
  `starlit-os/*`) instead of the upstream repo.

The reason for the carry doesn't matter. It can be a krytis-only bugfix that was never
upstreamed, a backport of a merged upstream commit that hasn't reached a release yet, or
a feature carried on a fork while upstream reviews it.

When a change adds or removes a carry, add, edit or delete its row **in the same PR**.
The check enforces that the row exists. It can't check that the row's *Why* or
*Removal condition* is still true; that stays a review question.

A new carry also needs its upstream's row in
[`upstream-ai-policies.md`](upstream-ai-policies.md), which records whether that project
accepts AI-assisted patches at all. `mise run upstream-policy-check` fails until the row
exists.

## Inventory

The check reads the first two columns, so keep their format:

- **Element**: one backticked repo-relative path to the element, `elements/….bst`.
- **Carry**: every backticked span is one carry. It is either a patch path, exactly as
  written in the element's `path:`, or a fork pin's source URL, exactly as written in
  the element's `url:`. Don't backtick anything else in this column. Put branch names
  and dates in *Nature*.

| Element | Carry | Nature | Why | Removal condition |
|---|---|---|---|---|
| `elements/overrides/vim.bst` | `patches/vim/vim-not-show-in-gnome.patch`, `patches/vim/gvim-not-show-in-gnome.patch` | Own patch | Sets `NoDisplay=true` on `vim.desktop`/`gvim.desktop`. This is a krytis preference, not an upstream bug: neither the terminal editor nor its GUI variant should appear in the app grid. | Not upstreamable (krytis-specific policy). Permanent unless the preference changes. |
| `elements/desktop/greetd.bst` | `patches/greetd/drop-agreety-workspace-member.patch`, `patches/greetd/bump-tokio-bytes-drop-agreety-deps.patch`, `patches/greetd/bump-tokio-1.43.1.patch` | Own patch (vuln remediation) | Drops `agreety` from `[workspace] members`. It is greetd's unused reference text greeter (krytis ships `noctalia-greeter-session`) and the only consumer of `rpassword` 5.0.1 (GHSA-2p6r-x3vv-xqm2). Paired with `cargo update -p bytes` (1.6.0->1.12.1, fixes GHSA-434x-w66g-qw3r) on the same element. **Correction, 2026-09-01:** the original `bump-tokio-bytes-drop-agreety-deps.patch` (#501) bumped `tokio` 1.37.0->1.42.1 to fix GHSA-rr8g-9fpq-6wmg, and it didn't. The advisory's patched range is `>=1.39.0, <1.43.1`, so 1.42.1 was still vulnerable. A fresh `mise run vuln-scan` after the 26.08rc merge caught it. `bump-tokio-1.43.1.patch` bumps `tokio` 1.42.1->1.43.1 and `tokio-macros` 2.4.0->2.5.0 (tokio 1.43.1 requires `~2.5.0`), which clears it. | Not upstreamable as a "fix": `agreety` isn't broken, krytis just doesn't use it. Permanent unless krytis starts shipping `agreety`. The patches also become redundant if greetd's own upstream Cargo.lock ever refreshes these crates. It has been stalled at 0.10.3 since Jun 2024 (per #496's investigation). |
| `elements/overrides/rust-bindgen.bst` | `patches/rust-bindgen/drop-quickchecking-workspace-member.patch`, `patches/rust-bindgen/drop-quickchecking-lockfile.patch` | Own patch (vuln remediation, mirrored element) | Mirrors freedesktop-sdk's `components/rust-bindgen.bst` and drops `bindgen-tests/tests/quickchecking` from `[workspace] members`. That crate is bindgen's own unused fuzz-testing crate, outside `default-members`, and the only path to `quickcheck` -> `rand` 0.8.5 (GHSA-cq8v-f236-94qc). The alternative was crossing rand's 0.8.x -> 0.9.x major bump, which has no compatible semver range. Paired with a regenerated `Cargo.lock`/`cargo2` block on the same element. Closes #498. | Delete the override and patches once freedesktop-sdk's own rust-bindgen ref drops quickchecking (or bumps its rand pin) upstream. Drift-checked by `mise run rust-bindgen-check`. |
| `elements/overrides/btrfs-progs.bst` | `patches/btrfs-progs/flush-zeroing-before-discard.patch` | Own patch (mirrored element), not yet proposed upstream | Since v6.16.1 (kdave/btrfs-progs `d50769a4`) `mkfs.btrfs` zeroes old signatures with buffered writes and then issues `BLKDISCARD`, which drops those writes from the page cache. A device that ignores the discard keeps the old signatures. A reinstall over an encrypted disk then kept both LUKS2 headers and failed at fisherman's remount with `unknown filesystem type 'crypto_LUKS'` (#1294). The patch adds an `fsync()` between the zeroing and the discard. Gated by `mise run mkfs-reformat-test`. | The junction's btrfs-progs persists the zeroing before it discards (#1302). Proposing it upstream is an Upstream Gate decision. Drift-checked by `mise run btrfs-progs-check`. |
| `elements/core/efitools.bst` | `patches/efitools/c99.patch`, `patches/efitools/gcc15.patch` | Downstream carry of fdsdk's patches (vendored element) | fdsdk deleted its EFI element family in 26.08 (`b39e7194`). krytis vendors only `sign-efi-sig-list`, which it needs to sign the `.auth` files (sbsigntools' `sbvarsign` writes a 0-based `EFI_TIME` month). It keeps two of fdsdk's four patches: `-D_GNU_SOURCE` plus the missing `strings.h`, and the lib/asn1 typedefs vs C23 `bool` fix for GCC 15. | Upstream efitools releases with the fixes. It has been dormant since 2018 (v1.9.2 plus four commits), so in practice this is permanent while krytis signs with it. |
| `elements/desktop/ananicy-cpp.bst` | `patches/ananicy-cpp/glibc-2.42-missing-headers.patch` | Pre-release backport | GCC 16 (fdsdk's compiler) rejects v1.2.0 because it is missing `<cstring>`/`<cstdint>` includes. The patch is upstream's own fix, cherry-picked verbatim. | Upstream tags a release after v1.2.0 that contains the fix. None existed as of 2026-10-01. |
| `elements/desktop/ghostty.bst` | `patches/ghostty/allow-shlib-undefined.patch` | Own patch | Zig 0.15.2's stub libc stops at glibc 2.42, but fdsdk 26.08 ships 2.44, so `ld.lld` refuses libgraphene's `@GLIBC_2.43` references. The patch sets `exe.allow_shlib_undefined`, and the real glibc resolves the symbols at load time (#305). | Ghostty tags a release built with a Zig that knows glibc ≥ 2.43. |
| `elements/desktop/oo7.bst` | `patches/oo7/login-helper-connect-retry.patch` | Own patch, not yet proposed upstream | The daemon reads the login helper's socket once, about 37 ms before the helper binds it, so the login collection stays locked for the whole session (#806). The patch adds a bounded 500 ms retry. Paired with an `ExecStartPre` drop-in and gated by `mise run oo7-login-race-test`. | Upstream oo7 adds its own retry. Filing it upstream is an Upstream Gate decision. |
| `elements/desktop/xwayland-satellite.bst` | `patches/xwayland-satellite/bump-time-ghsa-r6v5-fh4h-64xc.patch` | Own patch (vuln remediation, first-party element) | Bumps `time` past 0.3.44 for GHSA-r6v5-fh4h-64xc. Upstream's own lock is still on 0.3.44 (#499, #869). | The patch goes once upstream's `Cargo.lock` reaches `time` ≥ 0.3.47. The whole element goes once `gnome-build-meta.bst:sdk/xwayland-satellite.bst` does too. |
| `elements/desktop/noctalia.bst` | `github:kitten-lily/noctalia.git`, `patches/noctalia/launch-apps-as-systemd-services-by-default.patch` | Fork pin: branch feat/system-prompter, on v5.3.0 as of 2026-10-20. Carries one feature, not proposed upstream (Upstream Gate). Plus an own patch (krytis policy, #1253). | (1) Adds the native `org.gnome.keyring.SystemPrompter` provider, which oo7 needs for every unlock prompt. (2) The patch flips `launch_apps_as_systemd_services` to default `true`. noctalia runs in `session.slice` as `noctalia.service` (#1253), and with `false` every launched app would be its child there: out of systemd-oomd's reach and killed on every noctalia restart. The `/etc/skel` seed only reaches new accounts (`docs/skills/desktop.md` § noctalia runs as a user service). The v5.3.0 rebase dropped two fork carries because v5.3.0 ships upstream's own version of each: the lockscreen fix `1047f8fd8`, superseded by upstream `c83fb9b9c` (`docs/skills/desktop.md` § The last frame before sleep is what resume shows), and `07c8bc7f9`, the backport of upstream `fbf410e2` (#999). | Once (1) lands upstream (or is dropped), revert to `github:noctalia-dev/noctalia.git` with `track: v*`. Until then `track:` follows the branch, so each release needs a manual rebase and re-track. (2) is krytis policy and stays while noctalia runs as a service, unless upstream flips the default itself. |
| `elements/desktop/noctalia-plugin-mx-control.bst` | `patches/noctalia-plugin-mx-control/accept-pro-device-names.patch`, `patches/noctalia-plugin-mx-control/tooltip-all-devices.patch`, `patches/noctalia-plugin-mx-control/retry-empty-settings.patch`, `patches/noctalia-plugin-mx-control/lightspeed-asleep-is-offline.patch`, `patches/noctalia-plugin-mx-control/stop-serve-by-interpreter-path.patch` | Own patches: three fixes proposed upstream, a feature not proposed, and a pre-release backport | (1) The MX Control backend keeps a device only if `is_mx_name()` matches. Its G-series token `\bg ?pro\b` misses Solaar's names for current PRO mice ("PRO X Wireless"), so the panel never lists them and never shows DPI (#1220). The patch makes the G optional. Proposed as zachwilke/omarchy-mxcontrol#18 (issue zachwilke/omarchy-mxcontrol#17), open as of 2026-10-20. (2) The bar tooltip showed only `pickDevice()`'s device. It now lists every device's battery, then each distinct connection once. (3) After a receiver replug, a device whose HID++ link came up after serve's re-read stayed at `settings: []` (#1292). This backports zachwilke/omarchy-mxcontrol#16's `mxctl.py` hunk unchanged. That PR was open as of 2026-10-20. It retries empty settings every 2 s. (4) On top of (3): a Lightspeed receiver answers an asleep device's ping with `UNKNOWN_DEVICE`. Solaar raises that as `NoSuchDevice`, and zachwilke/omarchy-mxcontrol#16 then fell back to the cached `online=True`, which re-read an asleep keyboard every tick. The patch treats `NoSuchDevice` as offline. Proposed on 2026-10-17 as suggested changes, with a test, in a review on zachwilke/omarchy-mxcontrol#16 ([review](https://github.com/zachwilke/omarchy-mxcontrol/pull/16#pullrequestreview-5558966452)). The PR took both verbatim on 2026-10-19 as `7432d3e`, and its `mxctl.py` then matched (3) plus (4) in code. (5) `onExit`'s `pkill` pattern was anchored at `^python3`, but serve shows up as `/usr/bin/python3`, so disabling the plugin never stopped serve (#1313). Proposed on 2026-10-19 as noctalia-dev/community-plugins#1073 (plugin 0.2.3, from `kitten-lily/community-plugins` branch `fix/mx-control-stop-pattern`). A bot kept it a draft until the plugin's author, gamaraan, replied. gamaraan approved it on 2026-10-20, and it was open and ready for review as of 2026-10-20. The element exists for these patches: it ships the plugin from the image through the `krytis` path source in `files/noctalia-skel/settings.toml`, which outranks `community`. | (1) goes when community-plugins' mx-control ships a backend with zachwilke/omarchy-mxcontrol#18, or an equivalent fix. That PR merging upstream is not enough until community-plugins re-copies the backend. (2) goes when the plugin's tooltip lists every device. (3) and (4) go together, on the same terms as (1), once a backend containing zachwilke/omarchy-mxcontrol#16 with `7432d3e` is re-copied. If the PR drops `7432d3e` before merge, (4) stays. (5) goes when community-plugins' `HELPER_PATTERN` matches an interpreter path, through noctalia-dev/community-plugins#1073 or an equivalent fix. The Luau UI belongs to noctalia-dev/community-plugins, and filing (2) there is an Upstream Gate decision. Once nothing is patched, drop the element and the path source, and let `community` serve the plugin again. |

## Not carries

These look like carries but are out of scope for this file and its check:

- **First-party repos in an owned org.** `github:kitten-lily/presence-bridge.git`
  (`elements/desktop/presence-bridge.bst`) is krytis's own project
  (`docs/design/presence-bridge.md`), not a fork. `gh api repos/kitten-lily/presence-bridge --jq .fork`
  returns `false`. The check runs without network access, so it can't ask GitHub
  whether a repo is a fork. It assumes every `kitten-lily/*` or `starlit-os/*` source is
  a fork pin unless the repo is in `FIRST_PARTY` in `mise/tasks/patch-inventory-check`,
  where each entry needs a reason. An entry that no element uses fails the check.
- **Patch-less mirrors under `elements/overrides/`.** These replace a junction element
  with a krytis copy but carry no patch. Each one is a deliberate build-config
  divergence, and its own task, not this file, checks it against upstream (verified
  2026-10-11):
  - `overrides/gnome-desktop.bst`, `overrides/libdecor.bst`, `overrides/libportal.bst`:
    GTK3-free mirrors. `mise run gtk3-mirror-check` checks their drift from upstream and
    fails once upstream lets the mirror go.
  - `overrides/libdisplay-info.bst`: holds the 0.3.0 version. `mise run libdisplay-info-check`
    is an exit-condition check, not a drift check, by design. It fails when niri's
    vendored `libdisplay-info-sys` stops capping below 0.4.0.
  - `overrides/frei0r.bst`: disables SSE 4.1 on x86_64 (`-mno-sse4.1`) for
    dyne/frei0r#228/#239. **It has no check task**, so nothing flags drift or tells you
    when it can be dropped. Its exit condition lives only in the element's comment.
- **Fork pins outside the owned orgs.** A `url:` that names somebody else's fork looks
  the same as any upstream URL, so the check can't detect it. It still needs a row.
  Add it by hand.

## Historical carries

Worked examples of the full lifecycle this inventory tracks:

- `0001-show-pam-info-cue.patch` (under files/noctalia-greeter/) fixed the display of
  PAM_TEXT_INFO messages until upstream noctalia-greeter merged the equivalent logic in
  `26865dae`. The patch and the fork pin were then removed. See `docs/skills/pam.md`.
- `overrides/systemd-base.bst` and `update-utmp-shorten-comm.patch` backported systemd
  `b8968c49` (#417, #425). Dropped in #1062 once gnome-build-meta pinned v261.3, which
  includes the stable backport `40d1c21160`. The junction override was **retargeted** to
  `gnome-build-meta.bst:core-deps/systemd-base.bst`, not deleted. Deleting it falls back
  to fdsdk's own v261.2, which still has the bug.
- `overrides/abseil-cpp.bst` and `bmi2intrin-via-immintrin.patch` fixed abseil
  20260526.0's direct `<bmi2intrin.h>` include on x86_64_v3 (#305). It never had a row
  in #483's table. Dropped in #1063: since 26.08.0, fdsdk pins 20260817.0, which has no
  such include.
- Two commits on the `kitten-lily/noctalia` fork pin went in the 2026-10-20 rebase onto
  v5.3.0, both because the release shipped upstream's own version. The `fbf410e2`
  backport `07c8bc7f9` (#999) was the planned case. The lockscreen fix `1047f8fd8`, never
  proposed upstream, was not: upstream fixed the same resume flash independently in
  `c83fb9b9c` (noctalia#4829). Literally rebasing the fix would have conflicted with that
  code rather than revealing it, so read upstream's log for the carried files before
  rebasing an own fix (`docs/skills/bst.md` § Temporary fork pins for tarball-pinned
  elements, "Retiring the pin").
