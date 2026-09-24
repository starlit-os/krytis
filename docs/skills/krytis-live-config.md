---
name: krytis-live-config
description: "Live-only overrides for krytis's niri/noctalia desktop session (hotkey overlay, first-run popups). Use when editing live/src/configure-live-krytis.sh to suppress a desktop-session UI element for liveuser without changing the installed system's config."
metadata:
  type: reference
---

# krytis live session config overrides

`live/src/configure-live-krytis.sh` layers live-only tweaks on top of the
baked-in krytis image (niri + greetd + noctalia-greeter). The pattern for
suppressing a first-run/onboarding UI element: write to `liveuser`'s home
(`/home/liveuser/...`), never touch the shipped system config — installed
systems must keep default behavior.

### niri hotkey-overlay popup (2026-07-02 — settled image-wide 2026-07-06, no live override left)

**Historical.** krytis once shipped `/etc/niri/config.kdl` with
`hotkey-overlay { // skip-at-startup }` commented out, so the "Important
Hotkeys" cheat-sheet appeared on first niri login — wanted on installed
systems, noise on the live ISO installer — and the live script shadowed it for
`liveuser`. #278 replaced the niri defaults with the dotfiles config, splitting
it into includes and enabling the skip for *everyone*: `files/niri/startup.kdl`
now carries a bare `hotkey-overlay { skip-at-startup }` and is staged to
`/etc/niri/` by `elements/config/niri-config.bst`, pulled in by
`config.kdl`'s `include "startup.kdl"`. Nothing in
`live/src/configure-live-krytis.sh` touches niri at all any more.

**What survives, for the next live-only desktop tweak:** niri's config lookup
order is `$XDG_CONFIG_HOME/niri/config.kdl` → `/etc/niri/config.kdl`
(fallback), so a live-only override belongs in `liveuser`'s XDG config —
editing `/etc/niri/config.kdl` in the live script would have to be reverted for
the installed system. And compose with the shipped config (copy it, `sed` the
one line) rather than hand-rolling a separate minimal config that can drift
from it.

### noctalia welcome/onboarding popup (2026-07-02)

**What:** noctalia-shell shows a first-run welcome popup unless
`~/.local/state/noctalia/.setup-complete` already exists for the user.

**Why:** confirmed via upstream noctalia state-file convention (not
guessable from the krytis repo alone — see
[krytis#236](https://github.com/starlit-os/krytis/issues/236#issuecomment-4862419237)).

**Fix:** pre-seed the marker for `liveuser`, mirroring how
`gnome-initial-setup-done` is pre-seeded for GNOME-based live images upstream —
`projectbluefin/dakota-iso`'s own `live/src/configure-live.sh` and
`dakota/src/configure-live.sh`. Both are upstream-only paths: neither exists in
this tree, whose equivalent is `live/src/configure-live-krytis.sh`.

```bash
mkdir -p /home/liveuser/.local/state/noctalia
touch /home/liveuser/.local/state/noctalia/.setup-complete
chown -R liveuser:liveuser /home/liveuser/.local
```

### "Unlock Keyring" dialog in the live session (2026-09-22)

**What:** the live ISO pops an *Unlock Keyring* dialog at the desktop. Found on a
metal test, reproduced in QEMU ([krytis#911](https://github.com/starlit-os/krytis/issues/911)).

**Why:** greetd's `initial_session` is an autologin, so no password is ever
collected and `session optional pam_oo7.so auto_start`
(`elements/config/greetd-config.bst`) has nothing to stash. `oo7-daemon` finds a
secret from none of its three sources and logs:

```
INFO oo7_daemon::service: No default collection found, creating 'Login' keyring
INFO oo7_daemon::service: Created default 'Login' collection (locked)
```

noctalia is both a secret-service **client** (it opens sessions `s0`/`s1` about
25 s into the session) and the owner of `org.gnome.keyring.SystemPrompter`, so
its own access to the locked collection raises its own prompt. #585 does not
mask this: that bug makes locked *items* read back as absent, while a
collection **unlock** request still prompts.

**Fix:** hand oo7 the secret as a systemd credential, live-squashfs only.
`oo7-daemon.service` already carries `ImportCredential=oo7.keyring-encryption-password`
upstream, and `read_secret_from_credentials_directory()` (oo7's own
`server/src/main.rs`, not this tree) reads
`$CREDENTIALS_DIRECTORY/oo7.keyring-encryption-password` whenever the
login-helper socket yields nothing — so a drop-in is enough:

```bash
install -d /etc/systemd/user/oo7-daemon.service.d
cat > /etc/systemd/user/oo7-daemon.service.d/20-live-keyring-unlock.conf <<'EOF'
[Service]
SetCredential=oo7.keyring-encryption-password:live
EOF
```

The daemon then logs `Created default 'Login' collection (unlocked)` and
`Locked` reads `b false`. A constant passphrase is correct here: the live
keyring lives in tmpfs for one boot, holds nothing the user typed, and dies at
poweroff. The drop-in is written by `live/src/configure-live-krytis.sh`, so it
cannot reach an installed system — installed systems keep the PAM unlock path.

**Debugging handle** (live VM, over the DEBUG ISO's ssh):

```bash
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked
busctl --user list | grep -i prompt   # noctalia owns org.gnome.keyring.SystemPrompter
journalctl --user -u oo7-daemon
```

### Sealed (UKI) payloads must be embedded byte-identically (2026-08-01)

**What:** krytis's `mise run build-iso --sealed` embeds `ghcr.io/starlit-os/krytis:sealed`,
whose UKI has a `composefs=<sha512>` digest baked into its frozen kernel cmdline at seal
time. `bootc install` recomputes that digest over the image it installs and aborts with
"The UKI has the wrong composefs= parameter" on any mismatch.

**Why it bites here:** `live/iso-tools/payload-prep.sh` mutates every payload it embeds —
`00-defaults.toml`, `/etc/containers/storage.conf`, and two `buildah commit --squash`
round trips whose only observable effect can be a `/tmp` + `/var/tmp` mtime bump. All
three invalidate the digest. Harmless for unsealed payloads (no digest to invalidate),
which is why it went unnoticed until krytis became the first sealed payload.

**Fix:** `PAYLOAD_SEALED=1` makes `scripts/iso-sd-boot.sh` skip payload prep entirely, and
`live/iso-tools/payload-prep.sh` honours the same flag, so the store receives the image
byte for byte. `PAYLOAD_REF` moves the store key and recipe.json's
imgref/targetImgref/image/local_imgref together — moving only one breaks either the
install (local_imgref unresolvable) or the first `bootc upgrade` (targetImgref points at
the unsigned image, which the enrolled firmware then refuses).

**Aside, unrelated to sealing:** on the *unsealed* path that `/etc/containers/storage.conf`
injection goes into the payload, so every system installed from an unsealed ISO carries it
and has its podman pinned to the vfs driver. Inherited from upstream dakota-iso and
probably not intended; not changed during the port, which deliberately left unsealed
behaviour byte-identical.

### DEBUG ISOs need an sshd drop-in — krytis is pubkey-only (2026-08-01)

**What:** `mise run build-iso --debug` produced an ISO whose live session
refused every password login, so `mise run iso-install-test` timed out
waiting for SSH and looked like a boot failure. The guest was fine the whole
time:

```
$ ssh -o PreferredAuthentications=none liveuser@127.0.0.1 -p 2224
Remote protocol version 2.0, remote software version OpenSSH_10.3
Authentications that can continue: publickey
Permission denied (publickey).
```

**Why:** the krytis image ships `/etc/ssh/sshd_config.d/10-krytis-auth.conf`
with both `PasswordAuthentication no` and `KbdInteractiveAuthentication no` —
deliberately pubkey-only, with sk-* keys as the second factor. The DEBUG block's
`echo "liveuser:live" | chpasswd` sets a password that sshd will never accept, and
`iso-install-test`'s readiness probe is a real ssh login, not a port check.
This is krytis-specific: dakota/bluefin/stable/lts ship no such drop-in, which is
why debug ISOs for those variants always worked.

**Fix:** the hardened config names its own escape hatch — override it with a
lower-numbered drop-in. `Include /etc/ssh/sshd_config.d/*.conf` sits at the top of
`sshd_config` and sshd takes the *first* value obtained for a keyword, so `05-`
wins over `10-`. `configure-live-krytis.sh`'s DEBUG block now writes:

```
/etc/ssh/sshd_config.d/05-live-debug.conf
  PasswordAuthentication yes
  KbdInteractiveAuthentication yes
```

Both keywords are required: krytis sets `UsePAM yes`, so with
`KbdInteractiveAuthentication no` the PAM-driven prompt stays disabled even after
`PasswordAuthentication yes`.

The file goes into the live squashfs, never into the payload image, so it cannot
reach an installed system — and `DEBUG=0` production ISOs never get it at all.
Verify with `mise run iso-container-build --debug` then
`podman run --rm --entrypoint="" localhost/krytis-installer:latest cat
/etc/ssh/sshd_config.d/05-live-debug.conf` (and confirm it is absent at
`debug=0`).

### ISO build pipeline now native in krytis (2026-09-14)

**What:** the whole ISO build lives in this repo. It used to require a sibling
`kitten-lily/dakota-iso` checkout and shell out to `just` via `DAKOTA_ISO_DIR`; the build
moved in-tree in #838, the test path in #839, and #840 removed the last references — no
task resolves `DAKOTA_ISO_DIR` any more, and `just` is not even a `[tools]` entry in
`mise.toml`.

**Structure:**

```
live/
  Containerfile              # 3-stage build (ref → Debian initramfs-builder → final)
  iso-tools/
    Containerfile            # Fedora-based: xorriso, mtools, buildah, skopeo, isomd5sum
    payload-prep.sh          # injects bootc install defaults; passes sealed payloads through
  src/
    configure-live-krytis.sh # live-env setup: liveuser, greetd autologin, polkit, installer
    install-flatpaks.sh      # bootc-installer flatpak + Flathub reconcile
    flatpaks                 # Flathub app IDs to pre-install
    build-iso.sh             # xorriso/mtools ESP assembly
    krytis/
      composefs              # "true" — tells iso-sd-boot.sh to use VFS storage
      images/
        krytis-logo.png      # tour image for the installer UI
    etc/bootc-installer/
      recipe.json            # shared template; configure-live-krytis.sh overwrites with krytis branding
krytis/
  payload_ref                # ghcr.io/starlit-os/krytis:latest
  live_target                # krytis
  live_title                 # Krytis Live
  live_label                 # KRYTIS_LIVE
  tag                        # latest
  registry                   # starlit-os
scripts/
  iso-sd-boot.sh             # squashfs assembly + ISO assembly driver
mise/tasks/
  iso-container-build        # builds localhost/krytis-installer from live/Containerfile
  build-iso                  # end-to-end: iso-tools → live container → squashfs → ISO
  verify-iso-payload         # asserts the finished ISO embeds the expected image
```

**The live installer container is the caller's job:** `scripts/iso-sd-boot.sh` does not
build `localhost/krytis-installer` — it must already exist before the script is invoked.
`build-iso` builds it with an inline `podman build` (after building the `iso-tools`
image) and only then calls `iso-sd-boot.sh`; `iso-container-build` builds the same
container independently for iteration.

**payload-prep.sh is in-tree** at `live/iso-tools/payload-prep.sh`. The gate is the
`ISO_TOOLS_IMAGE` env var, not a buildah probe: when it is set `iso-sd-boot.sh`
bind-mounts the script into that container (`-v …/payload-prep.sh:/payload-prep.sh:ro`,
`STORAGE_DRIVER=vfs`) so the whole `buildah from → copy → commit` sequence survives in
one `podman run`; unset, it runs on the host, which then needs buildah + skopeo +
python3 itself. `build-iso` always sets it (defaulting to `localhost/iso-tools:latest`,
which it builds first), so the host path only happens when `iso-sd-boot.sh` is
driven by hand. Sealed payloads (`PAYLOAD_SEALED=1`) skip it entirely — see
`docs/skills/secure-boot.md` § A sealed ISO payload must be embedded
byte-identically.

### ISO test path now native in krytis (2026-09-14)

**What:** `mise run iso-install-test` and `mise run luks-install-test` previously
delegated to `just sealed-test-qemu krytis` in a sibling `kitten-lily/dakota-iso`
checkout. That delegation is removed (issue #839). The full test path is now native
mise tasks in this repo.

**9-item BOM ported** (8 survive; `scripts/fisherman-install.sh` was deleted once
tuna-os/fisherman#219 landed — see the installer-source note below):

| File | Purpose |
|---|---|
| `scripts/e2e-lib.sh` | Shared QEMU E2E library (ssh auth, monitor, teardown, port check) |
| `scripts/show-screenshot.sh` | Display PPM screendump inline (Kitty/iTerm2) |
| `scripts/iso-install-fisherman.sh` | Drives fisherman over SSH: builds recipe.json, uploads, patches BLS |
| `mise/tasks/iso-boot-live` | Phase 1: boot live ISO with plain OVMF, wait for SSH |
| `mise/tasks/iso-boot-installed` | Phase 3: boot installed disk (optionally under secboot enforcement) |
| `mise/tasks/iso-verify-boot` | Phase 4: grep serial log; `--expect-fail` inverts verdict |
| `mise/tasks/iso-e2e-test` | Orchestrator: phases 0-4 (or 0-2 with `--install-only`) |
| `mise/tasks/iso-install-test` | Top-level gate: calls `iso-e2e-test --install-only`, then `boot-test` |

**Composefs-only simplification:** upstream dakota-iso's `plain-install-qemu.sh` had two
branches, composefs (VFS) and ostree/bootcDirect. Krytis is always composefs
(`live/src/krytis/composefs` = `true`), so only the composefs branch was ported into
`scripts/iso-install-fisherman.sh`, which therefore takes just
`<target> <ssh_port> <monitor_live_socket>` — no `<fisher_repo>` argument, because there
is no go binary to build.

**INSTALL_ONLY=1 pattern for sealed systems:** sealed UKIs have frozen cmdlines, so
`console=ttyS0` cannot be injected — `iso-verify-boot`'s serial grep can never match.
Instead, `iso-e2e-test --install-only` is called (phases 0-2 only) and `boot-test`
provides the verdict via SMBIOS credentials, which work on sealed systems because
systemd reads them from firmware tables, not kernel args.

**argc-fallback pattern:** tasks called by other tasks (not via `mise run`) need both
`#USAGE` annotations (for `mise run`) and a `while case "$1"` argv parser (for direct
invocation). Every new task in this BOM implements both. See `docs/skills/mise.md`
§ Propagating flags through tasks that call other tasks.

**Disk handover between phases 2 and 3:** `iso-install-fisherman.sh` asks the live VM
to power down at the end of install, but an early exit can leave it still holding the
disk. `iso-e2e-test` calls `e2e_qemu_stop` explicitly between phases 2 and 3 so the
disk is always released before the installed VM tries to open it.

**Scratch paths:** the QEMU phases use `/tmp/krytis-qemu-live.sock`,
`/tmp/krytis-qemu-live-serial.log`, `/tmp/krytis-qemu-installed.sock`,
`/tmp/krytis-qemu-installed-serial.log`, `/var/tmp/krytis-qemu-live-vars.fd`,
`/var/tmp/krytis-qemu-installed-vars.fd`, `/var/tmp/krytis-install.img` (the install
target) and `/var/tmp/krytis-scratch.img` (the live VM's `/var/tmp`). The old
delegation's `/tmp/dakota-sealed-qemu-*` and `/var/tmp/dakota-sealed-install.img` names
are gone — a VM left behind by one of those is invisible to `iso-e2e-test`'s phase-0
teardown, which only knows the krytis sockets.

### The payload ref must not name a registry (2026-09-14)

**What:** `mise run build-iso` tags the local build into the published ref
(`podman tag localhost/krytis:latest ghcr.io/starlit-os/krytis:latest`) because
`scripts/iso-sd-boot.sh` exports the offline payload with `podman save
"${PAYLOAD_REF}"`, and `recipe.json` must carry the published name as
`targetImgref`. When `live/Containerfile` also built its stages `FROM
ghcr.io/${REGISTRY}/${TARGET}:${TAG}`, `podman build` **pulled that ref from the
registry** — 3.4 GiB, on a ref that was already in local storage, under the
default `--pull=missing`. The completed pull re-points the tag at the published
digest, so the live environment and the embedded offline payload both silently
become the registry's image instead of the one the checkout just built. Nothing
in the output says so; the ISO simply installs the wrong image.

**Why:** podman ≥ 5.7 (reproduced on 6.1.0 / buildah 1.42) re-resolves a
registry-named base image in a **multistage** build against the registry even
when it exists locally and the policy is `missing` —
[containers/podman#27197](https://github.com/containers/podman/issues/27197),
[#27779](https://github.com/containers/podman/issues/27779),
[#28038](https://github.com/containers/podman/issues/28038). Single-stage builds
with the same ref resolve locally, which is why this never showed up in
`mise run lint`.

**Fix:** `live/Containerfile` takes `ARG SOURCE_IMAGE` (default
`ghcr.io/${REGISTRY}/${TARGET}:${TAG}`) and every krytis-based stage builds
`FROM ${SOURCE_IMAGE}`. `build-iso` passes `SOURCE_IMAGE=${LOCAL_IMAGE}`
(`localhost/krytis:latest`, or `:sealed` / the `:iso-payload` alias);
`iso-container-build` defaults to `localhost/krytis:<tag>` when it exists and
accepts `--source-image`. A `localhost/` ref has no registry to consult, so the
bug cannot fire and the `ghcr.io/...` tag survives untouched for `podman save`.
`PAYLOAD_REF` still carries the published name — build source and payload
identity are now separate knobs.

**Reproducing it:** any multistage Containerfile whose base is a locally tagged
registry ref shows it; `--pull=never` also avoids it but then blocks the
legitimate `debian:bookworm` fetch in stage 2b.

```console
$ podman build --pull=missing live/     # base already local
[1/4] STEP 1/1: FROM ghcr.io/starlit-os/krytis:latest AS ref
Trying to pull ghcr.io/starlit-os/krytis:latest...
```

### krytis's own dracut must not build the live initramfs (2026-09-14)

**What:** `live/Containerfile` stage 2a builds the initramfs *natively* when the
source image can do it, and falls back to the Debian cross-build stage (2b)
otherwise. Its condition was `command -v dracut || command -v dnf ||
command -v rpm`. krytis ships `/usr/sbin/dracut` from freedesktop-sdk, and on
`localhost/krytis:sealed` that dracut's `--list-modules` *does* report
`dmsquash-live` — so a sealed ISO took the native path, produced a 221 MiB
initramfs, and the live ISO hung with the serial console silent after
`Run /init as init process` until `iso-boot-live` timed out. No dracut error, no
panic: just nothing. The unsigned image escaped only by accident — its dracut
cannot list `dmsquash-live`, so the condition fell through to stage 2b.

**Why:** freedesktop-sdk's dracut has no working `dracut-live`/udev/`cdrom_id`
chain for a live CD. Stage 2b (Debian `dracut` + `dracut-live`, cross-built
against krytis's kernel modules) is the path every ISO that has ever booted was
built with.

**Fix:** gate stage 2a on an RPM package manager (`dnf`/`rpm`) — the Fedora /
bluefin case it exists for — not on `dracut` being on `PATH`. A freedesktop
image always takes stage 2b now.

**Related:** `build-iso --sealed` must build the live ENVIRONMENT from the
unsigned `localhost/krytis:latest`, not from `localhost/krytis:sealed`. Sealing
concerns the payload; the live ISO is unsigned by design (#371) and a sealed
rootfs carries a UKI plus a frozen cmdline describing an *installed* system.
Before `SOURCE_IMAGE` existed this held by accident: the Containerfile's
`TAG=latest` ref made podman pull the published `:latest` for the live stages
while the payload came from the local `:sealed`. `build-iso` now sets
`LIVE_SOURCE_IMAGE` explicitly, falling back to the payload image only when
there is no local `:latest` (the `--payload-image` release-validation case).

**Symptom → cause table for a live ISO that never reaches SSH:**

| Serial console shows | Cause |
|---|---|
| Nothing after `Run /init as init process` | Native-dracut initramfs (stage 2a took the wrong branch) |
| dracut messages, then `dracut-initqueue timeout` | Squashfs/label mismatch — check `LiveOS/squashfs.img` and `krytis/live_label` |
| `Permission denied (publickey)` in the harness | ISO built without `--debug` |

### Live media want `dracut --omit shutdown` (2026-09-24, upstream dakota-iso `8ff32cc0`)

**What:** the dracut `shutdown` module re-execs into the initramfs at poweroff/reboot. On a
read-only live root that hangs the shutdown transaction instead of powering the machine off.
Upstream added `--omit "shutdown"` to its Debian cross-build with a comment that the flag
"applies to every ISO, not only test builds" — a production-media fix that a CI gate merely
happened to surface, not a CI workaround.

**krytis exposure:** `live/Containerfile` stage 2b (107-110) runs `DRACUT_NO_XATTR=1 dracut
-v --force --zstd --reproducible --no-hostonly --add "dmsquash-live" --add-drivers "squashfs
overlay loop iso9660 sr_mod cdrom"` with no `--omit`; stage 2a's native invocation (70-72)
has none either.

**Latent rather than observed, and the reason is the interesting part:** krytis's E2E gate
powers the live VM down through the QEMU monitor and then quits it —
`scripts/iso-install-fisherman.sh:121-123`, `system_powerdown`, `sleep 5`, `quit` — and that
`quit` kills QEMU whether or not the guest ever completed its shutdown transaction. The gate
structurally cannot see this hang. A human powering off real live media would.

**Not the same thing as the note at `live/Containerfile:47`.** That comment is about
*native* dracut failing at **build** time because its shutdown module cannot find
poweroff/reboot/halt symlinks in a container build context — a build-time symptom, on a path
krytis never takes. It is also plausibly why the omit was never added to the cross-build:
the word "shutdown" was already in the file, attached to a different problem.

### `iso9660` vs `isofs`, `--filesystems` vs `--add-drivers` (2026-09-24, upstream dakota-iso `8ff32cc0`)

**What:** two things that read as interchangeable and are not.

- `--filesystems "iso9660 squashfs"` is dracut's **filesystem set** — it controls which
  mount helpers and filesystem modules get installed into the initramfs.
- `isofs` is a **driver name**. On kernels that build ISO 9660 support as `isofs` rather
  than `iso9660`, asking for `iso9660` alone installs nothing at all.

After roughly ten CI iterations on "dropped to the dracut shell" / "could not mount the live
image", upstream converged on `--filesystems "iso9660 squashfs" --add-drivers "squashfs
overlay loop iso9660 isofs sr_mod cdrom" --force-drivers "isofs"` on **both** the native and
the cross-build path, plus `instmods loop iso9660 isofs squashfs overlay` in its dracut
module. `--force-drivers` — not `--add-drivers` — is what loads `isofs` during initramfs
startup rather than leaving it to late module discovery.

**krytis exposure:** `live/Containerfile:109` passes `--add-drivers "squashfs overlay loop
iso9660 sr_mod cdrom"`: `iso9660` but no `isofs`, no `--force-drivers`, and no
`--filesystems` on either stage 2a (70-72) or stage 2b (107-110).

**This records a fragile line; it is not an instruction to change it blind.** krytis ISOs
boot, so its kernel currently exposes the module under the name dracut is being asked for
and discovery is fast enough. The exposure is a kernel-config change renaming it — krytis
ships a prebuilt CachyOS kernel (`elements/core/linux-cachyos.bst`), whose config is not
krytis's to freeze. The failure would present as exactly the mute drop to the dracut shell
in the symptom table above, with the `--add-drivers` line still reading as correct. If that
ever appears, check the module name in the reference image's
`/usr/lib/modules/<kver>/modules.builtin` and `modules.dep` before touching anything else.

### The installer flatpak carries fisherman — pull it from tuna-os (2026-09-19)

**What:** `live/src/install-flatpaks.sh` downloads `org.bootcinstaller.Installer.flatpak`
from GitHub Releases, and `configure-live-krytis.sh` then symlinks the `fisherman` binary
out of the installed app dir to `/usr/local/bin/fisherman`. That one asset is therefore
both the GUI installer **and** the install backend: the bundle's age decides which
fisherman bugs the ISO ships.

**Why it mattered:** the script pulled from `projectbluefin/bootc-installer` with
`tuna-os/tuna-installer` as a fallback. Development moved back to the tuna-os org and
**both of those repos are archived** — newest bundles 2026-08-01 and 2026-05-08. So when
`tuna-os/fisherman#219` fixed the unbootable encrypted-sealed install on 2026-09-19, an
ISO built the same day still carried the bug, with nothing in the build log to say so.

**Fix:** `INSTALLER_REPO="tuna-os/bootc-installer"`, and **no fallback** — both former
fallbacks are archived, and quietly installing a months-old bundle is worse than a hard
curl failure. That repo cuts a release per merge (`v2026.09.19-cee9ba29`), so
`releases/latest/download/` moves daily and `latest-dev` still names the Devel asset;
neither URL shape needed changing.

**How to check what a bundle actually contains** — the flatpak is an ostree bundle, so
the binary is two commands away:

```bash
ostree init --repo=repo --mode=archive-z2
flatpak build-import-bundle repo org.bootcinstaller.Installer.flatpak
ostree --repo=repo checkout -U app/org.bootcinstaller.Installer/x86_64/master co
strings -a co/files/bin/fisherman | grep -c 'type=%s, name="root"'   # 1 = has #219
```

**Related:** `scripts/fisherman-install.sh` is gone with the same change. It wrapped
fisherman to finish a hostname write that used to fail on composefs sysroots; upstream's
`post.WriteHostname` now resolves the deploy `etc` from the BLS entry's `composefs=<hash>`
and writes `state/deploy/<hash>/etc/hostname` directly — confirmed in the install log.
Its only other action patched Universal Blue's `rechunker-group-fix.service`, which
krytis has never shipped, and which had been printing "deployment etc/ not found" on
every run instead of patching anything.
