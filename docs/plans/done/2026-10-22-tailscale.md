# Tailscale in the image — implementation plan (#1384)

**Goal:** ship `tailscale` + `tailscaled` in the image, **disabled by default**, with a
`mise tailscale:setup` system task that opts a user in (enables the daemon, makes them
operator, starts browser sign-in), and an update path that verifies Tailscale's own
checksum and distsign signature on every bump.

**Out of scope:** the GUI setup flow (polkit action, `pkexec`, GTK app) — deferred to
#1385. No noctalia plugin ships or is enabled (decision 3 in #1384). No auth keys, node
identity, exit-node choice or `--no-logs-no-support` default in the image.

**Branch / worktree:** `1384-add-tailscale-to-the-image` at
`krytis.worktrees/feat/gh1384-add-tailscale-to-the-image`, based on `origin/main` `8359853`.

All decisions referenced below are recorded in #1384 § Decisions (2026-10-22). Facts marked
**[measured]** were observed on 2026-10-22 on a live krytis host (`7.2.11-1-cachyos`) or
against upstream; **[verify]** marks a claim that a step below must confirm before relying on it.

**Review:** this plan was reviewed by GPT-5.6 Sol on 2026-10-22 (read-only, against this
worktree, dakota and Tailscale upstream). All twelve findings are folded in below.

---

## Facts the plan depends on

| Fact | Evidence |
|---|---|
| The stable Linux tarballs this element uses are published at `pkgs.tailscale.com/stable/`; GitHub release v1.104.2 has no assets | **[measured]** `gh api repos/tailscale/tailscale/releases/latest` → v1.104.2, 0 assets; `https://pkgs.tailscale.com/stable/?mode=json` → `Tarballs.amd64 = tailscale_1.104.2_amd64.tgz`, `Tarballs.arm64 = tailscale_1.104.2_arm64.tgz` |
| The signing-key bundle lives at the **host root**, not under `/stable/` | **[measured]** `https://pkgs.tailscale.com/distsign.pub` 200 (113 B), `distsign.pub.sig` 200 (64 B); `/stable/distsign.pub` 404. Upstream `clientupdate/distsign/url.go` splits the package URL at the host for this reason |
| Tarball layout: `tailscale_<v>_<arch>/{tailscale,tailscaled,systemd/{tailscaled.service,tailscaled.defaults,tailscale-online.target,tailscale-wait-online.service}}` | **[measured]** `tar tzvf` on 1.104.2 amd64 |
| Upstream unit: `EnvironmentFile=/etc/default/tailscaled`, `ExecStart=/usr/sbin/tailscaled … --port=${PORT} $FLAGS`, `ExecStopPost=/usr/sbin/tailscaled --cleanup`, `[Install] WantedBy=multi-user.target` | **[measured]** |
| Both binaries are statically linked Go executables | **[measured]** `file` on 1.104.2 amd64 |
| `kind: manual` needs `runtime-gnu.bst` for a shell and `install`; `runtime-gnu` has neither `grep` nor `sed` | `docs/skills/bst.md` § `kind: manual` sandbox commands need `runtime-gnu.bst`, not bare `runtime-minimal.bst`; § Prebuilt Binary Elements — Sandbox Tool Availability |
| `%{install-extra}` must be the last install command | `docs/skills/bst.md` § Common mistakes |
| Unmatched units with `[Install]` are enabled by the image's global preset step, so "off" needs an explicit `disable` rule | `docs/skills/bst.md` § The fall-through applies to the package's other units too, not just the template; `desktop/presence-bridge.bst` (#1152) |
| System mise tasks are discovered from `/etc/mise/conf.d/*.toml` (not by scanning `/etc/mise/tasks/`), and the element needs `runtime-gnu.bst` + `core/mise.bst` | `docs/skills/bst.md` § System-wide mise tasks via BST element; `elements/config/fido2-tasks.bst:14-15`, `elements/desktop/presence-bridge.bst:33-34` |
| `tailscale up` prints the auth URL and then **blocks** until the backend is `Running` | tailscale `cmd/tailscale/cli/up.go` (prints `BrowseToURL`, then waits on `upComplete`); dakota's `files/tailscale/dakota-tailscale-setup` streams `--json` output for this reason |
| `/usr/bin/iptables` → `xtables-legacy-multi` (legacy); netavark uses nftables; tailscaled logs `router: default choosing iptables` | **[measured]** idle run, #1384 § Idle daemon check |
| tailscaled honours `TS_DEBUG_FIREWALL_MODE` | **[measured]** string `TS_DEBUG_FIREWALL_MODE set, overriding firewall mode from %s to %s` in the 1.104.2 binary. Behaviour with a logged-in node: **[verify]** in Task 6 |
| Idle tailscaled writes `/var/lib/tailscale/tailscaled.log*` regardless of `--state` | **[measured]** |
| Operator lookup falls back to `getent passwd` (works for systemd-homed users) | tailscale `util/osuser/user.go` (main, 2026-10-22). Live: **[verify]** in Task 6 |
| `sudo-rs` sets `SUDO_UID` from the authenticated caller and does not let the caller override it | sudo-rs source (context `current_user.uid`; default `env_keep` excludes `SUDO_*`), per the review. Live: **[verify]** in Task 3 |
| distsign: `distsign.pub` (PEM `SIGNING PUBLIC KEY` blocks, each a raw 32-byte ed25519 key) is signed by a root key (`distsign.pub.sig` = ed25519 over the raw bundle bytes); a package `.sig` = ed25519 over `BLAKE2s-256(file) ‖ uint64_le(len(file))` | tailscale `clientupdate/distsign/distsign.go` (`SignSigningKeys`, `SignPackageHash`, `ValidateLocalBinary`) |
| The verification works with `openssl` alone (raw key wrapped as SPKI DER with prefix `302a300506032b6570032100`) | **[measured]** throwaway prototype, OpenSSL 3.5.8: bundle verified by `crawshaw-root.pem` (not `distsign-prod-root-1-pub.pem`), 1.104.2 **amd64** tarball verified by the single signing key; one appended byte to either the tarball or the bundle → rejected. arm64 not yet verified (Task 2 `--verify-current`). Hosted-runner OpenSSL: **[verify]** in Task 2's branch dispatch |
| `/etc` changes, including enablement symlinks, carry across `bootc upgrade` | `docs/skills/bootc-vm.md` § `/etc` changes DO reach existing deployments on `bootc upgrade` — don't assume otherwise. Live: **[verify]** in Task 6 |
| `mise run boot-test` generates its own disk unless `--reuse-disk` is given | `mise/tasks/boot-test` (calls `./mise/tasks/generate-disk` in its normal path) |
| `python3` is in the image | `files/fakecap-manifest.tsv` has `/usr/bin/python3` |

---

## Task 1 — source alias and the binary element

**Files:** `include/aliases.yml`, `elements/core/tailscale.bst` (new),
`elements/stacks/base-system.bst`.

- [x] Add `tailscale_pkgs: https://pkgs.tailscale.com/stable/` to the file-alias block of
  `include/aliases.yml`.
- [x] Create `elements/core/tailscale.bst`, `kind: manual`, modelled on
  `elements/core/pangolin-cli.bst` (header comment carries the why, the update path and
  `Closes #1384`). Keep version strings **out of the header comment**: the updater reads
  only `url:` lines, but a stale version in a comment still misleads readers.
  - Sources: `kind: tar`, arch-conditional (`arch == "x86_64"` → `tailscale_<v>_amd64.tgz`,
    `arch == "aarch64"` → `_arm64.tgz`), `ref:` = sha256 of each tarball. `kind: tar`
    strips the top-level directory, so files land at `./tailscale`, `./tailscaled`,
    `./systemd/…`.
  - `build-depends:` `freedesktop-sdk.bst:public-stacks/runtime-gnu.bst` (shell +
    `install`), `freedesktop-sdk.bst:components/sed.bst` and
    `freedesktop-sdk.bst:components/grep.bst` (neither is in `runtime-gnu`).
    `variables: strip-binaries: ''`.
  - Runtime `depends:` none beyond what `base-system.bst` already brings: both binaries are
    static. The `nftables` firewall mode drives netlink directly; it needs the
    `nf_tables`/`nft_*` kernel modules, not the `nft` binary **[verify]** in Task 6.
  - install-commands, in this order:
    1. `install -Dm755 -t "%{install-root}%{bindir}" tailscale tailscaled`
    2. Unit: `sed` the upstream `systemd/tailscaled.service` →
       - `s|/usr/sbin/tailscaled|%{bindir}/tailscaled|g` (both `ExecStart` and `ExecStopPost`)
       - delete `^EnvironmentFile=` (krytis ships no `/etc/default`; `docs/skills/bst.md`
         § Common mistakes row "`EnvironmentFile=/etc/default/...`")
       - after `[Service]`, add `Environment=PORT=41641`, `Environment=FLAGS=` (dakota
         `4940fa6`: without them `--port=${PORT}` expands empty) and
         `Environment=TS_DEBUG_FIREWALL_MODE=nftables`
       - install to `%{indep-libdir}/systemd/system/tailscaled.service`.
       Write files with `install -Dm644 /dev/null …` + `cat >` / redirect — never `/dev/stdin`
       (dakota `256981a`).
    3. Preset `%{indep-libdir}/systemd/system-preset/80-tailscale.preset` containing
       `disable tailscaled.service` (decision 1).
    4. Assertions on the installed unit, so an upstream unit change fails the build instead
       of shipping a broken unit: `grep -c` counts exactly 0 `/usr/sbin`, 0
       `EnvironmentFile=`, 2 `%{bindir}/tailscaled` (ExecStart + ExecStopPost), and exactly
       one each of the three `Environment=` lines.
    5. `%{install-extra}` — last.
  - Do **not** install `tailscaled.defaults`, `tailscale-online.target` or
    `tailscale-wait-online.service` (nothing orders after the tailnet). Do not create
    anything under `/var/lib/tailscale`.
- [x] Add `core/tailscale.bst` to `elements/stacks/base-system.bst` directly after
  `core/pangolin-cli.bst`.

## Task 2 — `tailscale-update` with checksum + distsign verification

**Files:** `mise/tasks/tailscale-update` (new), `mise/lib/tailscale-distsign-roots.pem`
(new), `.github/workflows/track-bst-sources.yml`.

- [x] `mise/lib/tailscale-distsign-roots.pem`: both root public keys copied from tailscale
  `clientupdate/distsign/roots/` (`distsign-prod-root-1-pub.pem`, `crawshaw-root.pem`),
  with a header comment naming the upstream path + commit they were copied from. A root
  rotation upstream must surface as a verification failure and a reviewed edit to this
  file, never as a silent trust change.
- [x] `mise/tasks/tailscale-update` (bash, `set -euo pipefail`, `#MISE hide=true`, same
  shape as `mise/tasks/pangolin-update`). Two explicit constants, never derived from the
  feed or the alias:
  ```text
  DIST_BASE=https://pkgs.tailscale.com          # distsign.pub, distsign.pub.sig
  ASSET_BASE=https://pkgs.tailscale.com/stable  # feed, tarballs, .sha256, .sig
  ```
  Every fetch uses `curl -fsSL --retry 3 --retry-delay 10`. Flow:
  1. **Current pin:** read only lines matching `^[[:space:]]*url:` in
     `elements/core/tailscale.bst`; require exactly one `tailscale_<v>_amd64.tgz` and one
     `tailscale_<v>_arm64.tgz`, with the same `<v>` (`docs/skills/ci-runner.md` records the
     `tarball-update` break a stale header comment caused).
  2. **Target:** without flags, read `$ASSET_BASE/?mode=json`, take `.Tarballs.amd64` and
     `.Tarballs.arm64`; require both to match
     `^tailscale_([0-9]+\.[0-9]+\.[0-9]+)_(amd64|arm64)\.tgz$` with the **same** version, and
     build URLs from the validated filename on `ASSET_BASE` only (dakota
     `scripts/update_sources.py` `tailscale_release_tag`). With `--verify-current`, the
     target is the current pin and the task never edits the element.
  3. Without `--verify-current`: refuse to move backwards (`sort -V`); exit 0 if equal.
     (Covers dakota `865e340`'s ≥1.96.4 floor without hard-coding it.)
  4. **Signing keys:** fetch `$DIST_BASE/distsign.pub` + `.sig`; require the signature to be
     exactly 64 bytes; verify the bundle against any pinned root; split the bundle and
     require every block to be labelled `SIGNING PUBLIC KEY` and decode to exactly 32 bytes,
     with no trailing data. Same strictness for the pinned `ROOT PUBLIC KEY` blocks.
  5. **Each arch:** download the tarball, `.sha256` and `.sig` into one temp dir; require
     `.sha256` to match `^[0-9a-f]{64}$` exactly and to equal `sha256sum` of the file;
     require `.sig` to be exactly 64 bytes and to verify against a signing key.
  6. **Only after both arches verify:** compute each `ref:` from the same downloaded bytes
     that were verified. With `--verify-current`, require each computed digest to equal the
     element's existing `ref:` and exit non-zero otherwise. Otherwise rewrite the two `url:`
     version strings and the two `ref:` lines (pangolin-update's `sed` pattern, keyed on the
     `x86_64` / `aarch64` blocks). Any failure → non-zero exit, element untouched.
  - Verification implementation: `openssl pkeyutl -verify -pubin -keyform DER -rawin`, keys
    wrapped as SPKI DER, BLAKE2s via `openssl dgst -blake2s256 -binary`, length via
    `python3 -c 'struct.pack("<Q", …)'` — the exact recipe the prototype proved.
- [x] Run `mise run tailscale-update --verify-current` against the initial 1.104.2 pin
  **before the first commit**: this is the only positive evidence for the arm64 tarball,
  since a scheduled run on an unchanged version exits before verifying anything.
- [x] `track-bst-sources.yml`: add `tailscale` to the `workflow_dispatch` `group` options
  and a `track-tailscale` job copied from `track-pangolin` (same pinned action SHAs, same
  `scripts/tracking-cooldown.sh`, `scripts/commit-tracking-update.sh`,
  `scripts/tracking-pr.sh` calls). Read the version for the PR title with the same
  `url:`-line extraction as step 1, not a whole-file grep. The PR body links
  `https://tailscale.com/changelog`.
- [x] Negative check (throwaway, not committed): run the verification against a tampered
  tarball copy and a tampered `distsign.pub` copy and confirm a non-zero exit with the
  element untouched.
- [x] Branch smoke of the CI job (`docs/skills/bst.md` § Verifying the CI job before merge):
  ```sh
  gh workflow run track-bst-sources.yml --ref 1384-add-tailscale-to-the-image --field group=tailscale
  gh run watch <run-id> --exit-status
  ```
  Expect the updater step to pass on the hosted runner's OpenSSL, `has_changes=false`, and
  the cooldown / commit / PR steps to be skipped off `main`.

## Task 3 — `mise tailscale:setup` (decision 2, option b)

**Files:** `elements/config/tailscale-setup.bst` (new), `files/tailscale/` (new:
`krytis-tailscale-authorize`, `setup`, `tailscale.toml`), `elements/stacks/base-system.bst`.

Kept out of `core/tailscale.bst` so the tracked element only ever changes by
`tailscale-update`'s `url`/`ref` edits (mirrors dakota's `tailscale.bst` /
`tailscale-setup.bst` split).

- [x] **[verify]** `sudo env | grep '^SUDO_'` on krytis lists `SUDO_UID` and `SUDO_USER`.
- [x] `files/tailscale/krytis-tailscale-authorize` → `/usr/libexec/krytis-tailscale-authorize`
  (mode 0755, `#!/usr/bin/python3 -I`, stdlib only), a port of dakota's
  `files/tailscale/dakota-tailscale-authorize`:
  - refuse unless `euid == 0`, no arguments, and `SUDO_UID` is a positive integer;
    resolve the name with `pwd.getpwuid` (NSS → works for homed users).
  - take an exclusive `fcntl.flock` on a root-owned lock file under `/run` (e.g.
    `/run/krytis-tailscale-authorize.lock`) and hold it through the final re-read, so two
    concurrent setups can't both see an empty operator and overwrite each other.
  - absolute paths (`/usr/bin/systemctl`, `/usr/bin/tailscale`) and a bounded timeout on
    every subprocess.
  - `systemctl enable --now tailscaled.service` (dakota only `start`s; krytis ships it
    disabled, so the opt-in must persist across reboots).
  - read `OperatorUser` from `GET /localapi/v0/prefs` over `/run/tailscale/tailscaled.sock`,
    with a bounded retry while the socket appears (`Type=notify` should make `--now` return
    after readiness **[verify]**).
  - if `OperatorUser` is set to someone else → exit 1 with dakota's message; never replace it.
  - `tailscale set --operator=<name>`, then re-read prefs and require
    `OperatorUser == <name>`.
- [x] `files/tailscale/setup` → `/etc/mise/tasks/tailscale/setup` (mode 0755, bash,
  `set -euo pipefail`, `#MISE description=…` header):
  1. Refuse to run as root.
  2. `sudo /usr/libexec/krytis-tailscale-authorize`.
  3. As the user, start `tailscale up --timeout=5m` **in the background** (it blocks until
     sign-in completes) with a `trap` that kills it on interrupt/exit.
  4. Poll `tailscale status --json` for a non-empty `AuthURL` (bounded); require it to
     start with `https://`; always print it; call `xdg-open` only when `$WAYLAND_DISPLAY`
     is set and `xdg-open` exists. If the node is already `Running`, skip to step 6.
  5. `wait` for `tailscale up` and propagate its exit status.
  6. Print `tailscale status` and a one-line pointer to the `davemhammer/tailscale`
     community plugin (decision 3).
- [x] `files/tailscale/tailscale.toml` → `/etc/mise/conf.d/tailscale.toml` declaring
  `[tasks."tailscale:setup"]` with `run = "/etc/mise/tasks/tailscale/setup"` and
  `description =`. Do not touch `/etc/mise/config.toml` (owned by `config/fido2-tasks.bst`).
- [x] `elements/config/tailscale-setup.bst`: `kind: manual`, `kind: local` source
  `files/tailscale`, and
  ```yaml
  depends:
  - freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - core/mise.bst
  - core/tailscale.bst
  - freedesktop-sdk.bst:components/python3.bst
  ```
  Installs the three files, `%{install-extra}` last. Add it to `base-system.bst` after
  `core/tailscale.bst`.
- [x] `docs/skills/bst.md`: an entry next to § sudo-rs Cmnd Args matching has no
  substring/glob support inside a single arg / § Passwordless sudo for a client that
  self-elevates — the root-only helper pattern: identity from the authenticated
  `SUDO_UID`, homed-aware `pwd.getpwuid`, read/check/set serialized under a lock, the
  no-replace rule, and why it needs no sudoers carve-out (unlike `core/pangolin-cli.bst`).
  Same commit as this task.

## Task 4 — build gates

- [x] `mise run build` (ends with lint, `umbriel-config-validate`, `cracklib-dict-check`,
  `portal-routing-check`). Stop and ask if it starts compiling the toolchain (Toolchain Gate).
- [x] Inside `localhost/krytis:latest`:
  - `systemctl is-enabled tailscaled.service` → `disabled`; no
    `/etc/systemd/system/multi-user.target.wants/tailscaled.service`.
  - `/var/lib/tailscale` absent; `tailscale version` matches the pin.
  - `mise tasks ls` (system) lists `tailscale:setup`.
- [x] `mise run generate-fakecap-manifest`, `mise run vuln-scan --fail-on critical`.

## Task 5 — `boot-test` assertion

**File:** `mise/tasks/boot-test`.

- [x] Next to the polkit/Bazaar assertions, assert all three, with a failure message naming
  #1384 and the preset fall-through:
  - `systemctl is-enabled tailscaled.service` → `disabled`
  - `systemctl is-active tailscaled.service` → `inactive`
  - `ss -H -lun 'sport = :41641'` → no rows
- [x] `mise run boot-test` (pty; FIDO2 PIN at the sudo prompt). It builds its own disk.

## Task 6 — live acceptance on real hardware (homed user)

Install the built image on a krytis machine (`bootc switch`/`upgrade` to the local image)
and walk #1384 § Acceptance:

- [x] Fresh boot: daemon disabled + inactive, UDP 41641 closed.
- [x] `mise tailscale:setup` as the homed user: FIDO2 sudo prompt → operator set → URL
  printed and opened → sign-in → `tailscale status` works **without sudo**.
- [x] `journalctl -u tailscaled`: `TS_DEBUG_FIREWALL_MODE set, overriding firewall mode`,
  no `kernel does not support IPv6 policy routing`; with the node up, `ts-*` chains appear
  in `nft list ruleset` and `iptables-legacy-save | grep -c ts-` is `0`.
  **Correction:** the `set, overriding` line never appeared. The evidence line is
  `router: netfilter running in nftables mode, v6 = true`; see Results.
- [x] MagicDNS name of a peer resolves (`resolvectl query <peer>`), via resolved.
- [x] Second account runs `mise tailscale:setup` → refused, operator unchanged.
- [x] Reboot → daemon comes back enabled and connected.
- [ ] **bootc update:** record the `multi-user.target.wants/tailscaled.service` symlink,
  deploy a subsequent local image, reboot, re-check the symlink, `is-enabled` and the
  connection. If this step is skipped, the PR says update persistence is **[unverified]**
  and cites the `/etc` merge mechanism instead of claiming it was tested.
  **Skipped, [unverified]:** only reboot persistence was tested.

## Task 7 — docs (same commits as the code they describe)

- [x] `docs/design/deferred-from-dakota.md`: `tailscale.bst` row → **ported**, pointing at
  `core/tailscale.bst` + `config/tailscale-setup.bst`, noting the deliberate differences
  (disabled preset, nftables mode, mise task instead of GTK app → #1385).
- [x] `docs/skills/bst.md`: new entries —
  - vendor prebuilt that ships a systemd unit: rewrite checklist (`/usr/sbin`,
    `EnvironmentFile`, defaults the removed file used to supply, in-element assertion);
  - `/usr/bin/iptables` is legacy on krytis → daemons that program netfilter must be told
    to use nftables (tailscaled: `TS_DEBUG_FIREWALL_MODE`, a `DEBUG`-named knob that could
    be renamed upstream);
  - verifying a vendor's own signature in an update task (distsign recipe, pinned roots in
    `mise/lib/`, `--verify-current` for the initial pin, "rotation must fail loudly");
  - extend § Element Update Path with `tailscale-update`;
  - the operator-helper entry (Task 3).
- [x] `docs/skills/dakota.md`: record which dakota lessons were applied and the two places
  krytis deliberately diverges (disabled-by-default after the idle measurement; nftables
  firewall mode — dakota has the same legacy-iptables exposure).
- [x] Image inventory, after every element is wired: `mise run image-inventory --write`,
  fill the new rows' descriptions in `docs/design/image-inventory.md`, then
  `mise run image-inventory --check`.
- [x] Grep open issues for stale statements (`gh issue list --state open --search
  'tailscale in:body'`) and edit any that now state the old version.
- [x] `git mv docs/plans/2026-10-22-tailscale.md docs/plans/done/` in the final commit of
  this PR (AGENTS.md § Plan & Design Docs: archive in the same PR).
- [x] `mise run docs-links` as the last docs check, after the move.

## Commit plan

Commits as landed (all signed):

0. `a65b5d6` `docs(plans): add tailscale implementation plan` — this file.
1. `8c90381` `feat(tailscale): ship tailscale disabled, with mise tailscale:setup` — Tasks 1
   and 3, the bst.md unit / netfilter / operator-helper entries, and the
   deferred-from-dakota row. Planned commits 1 and 3 were merged into this one, because
   `stacks/base-system.bst` names both elements.
2. `a5381a7` `ci(tailscale): track pkgs.tailscale.com with distsign verification` — Task 2,
   the bst.md signature entry, and dakota.md.
3. `46eed45` `test(boot-test): assert tailscaled ships disabled` — Task 5.
4. `9a34339` `chore(tailscale): regenerate fakecap manifest and image inventory`.
5. `565d99d` `fix(tailscale): detach xdg-open in tailscale:setup` — the Task 6 finding
   below, plus the journal-line correction in bst.md.
6. Archive commit: these results, with the plan moved to `docs/plans/done/`.

## Results (2026-10-22)

| Check | Result |
|---|---|
| `tailscale-update --verify-current` | amd64 `512f613e…` and arm64 `5776aaa9…`: sha256 + distsign OK. Also passes in `ubuntu:26.04` (OpenSSL 3.5.5) |
| Negative checks | Tampered tarball (with a consistent `.sha256`) → `distsign signature does not verify`. Tampered `distsign.pub` → `does not verify against any root`. Wrong pinned `ref:` → fails. The element was untouched each time |
| Update path | Element pinned back to 1.104.1 → task rewrote it to 1.104.2, byte-identical to the hand pin |
| `mise run build` | Passed, including every image gate. Image `9dc139065ba2` |
| Image contents | `is-enabled` = `disabled`, no wants symlink, no `/var/lib/tailscale`, 1.104.2, `mise tasks ls` lists `tailscale:setup` |
| `vuln-scan --fail-on critical` | Passed. 0 grype matches under Tailscale paths |
| `boot-test --image localhost/krytis:gh1384` | PASSED: "tailscaled is disabled, inactive and not listening" |
| Branch dispatch | Run 39769484359: `track-tailscale` success, `has_changes=false`, PR steps skipped |
| sudo-rs `SUDO_UID` | `env SUDO_UID=4242 SUDO_USER=mallory sudo env` → `SUDO_UID=60339`, `SUDO_USER=lily` |
| Live, fresh boot (sealed `localhost/krytis:sealed`, homed user `lily`, absent from `/etc/passwd`) | `disabled`, `inactive`, no UDP 41641 listener, no wants symlink |
| Live, after `mise tailscale:setup` | `enabled`/`active`, symlink created, `OperatorUser` = `lily`, `tailscale status` works without sudo |
| Live, firewall | `envknob: TS_DEBUG_FIREWALL_MODE="nftables"`, `router: netfilter running in nftables mode, v6 = true`; 6 `ts-*` chains in nft, 0 legacy rules; IPv6 policy rules present, no policy-routing warning |
| Live, MagicDNS | `resolvectl query work.werewolf-stonecat.ts.net` → `100.114.54.8` on `tailscale0` |
| Live, second user | `sudo env SUDO_UID=65534 /usr/libexec/krytis-tailscale-authorize` → refused, exit 1, operator still `lily` |
| Live, reboot | Still enabled and active, same symlink, nftables mode, node connected |
| Live, bootc update persistence | **[unverified]** |

**Finding fixed during Task 6:** `mise tailscale:setup` did not exit after sign-in. No
browser was running, so `xdg-open` started Zen and blocked until it exited, with Zen in the
task's process group (Ctrl-C would have killed the browser). Fixed in `565d99d` with
`setsid -f xdg-open … </dev/null`. The mechanism was checked (`setsid -f` returns at once
and the child gets its own session), but the fixed script has not been re-run in an
image: the tested image predates the fix.

## Risks

| Risk | Mitigation |
|---|---|
| Critical Go stdlib CVE between Tailscale releases blocks publish (`--fail-on critical`) | hourly `track-tailscale`; `vuln-scan-triage` skill |
| Upstream unit changes shape → `sed` silently misses | in-element assertions (Task 1) |
| distsign root rotation | task fails closed; update `mise/lib/tailscale-distsign-roots.pem` from upstream in a reviewed PR |
| `TS_DEBUG_FIREWALL_MODE` is a `DEBUG` knob and could be renamed | Task 6 log-line check; boot-test can't cover it (no login in the VM); noted in the bst.md entry |
| CachyOS kernel drops `IPV6_MULTIPLE_TABLES` (krytis doesn't own that config) | Task 6 journal check; mention in the element header |
| `/var/lib/tailscale` log-ID files created on first daemon start | runtime-only, by design; image must not contain them (Task 4 check) |
| Concurrent setups race on the operator | `flock` in the helper + post-set re-read (Task 3) |
