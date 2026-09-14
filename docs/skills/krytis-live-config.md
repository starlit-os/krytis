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

### niri hotkey-overlay popup (2026-07-02)

**What:** krytis ships `/etc/niri/config.kdl` (from `files/niri/config.kdl`
in the krytis repo) with `hotkey-overlay { // skip-at-startup }` commented
out, so the "Important Hotkeys" cheat-sheet shows on first niri login —
desired on installed systems, noise on the live ISO installer.

**Why:** niri's config lookup order is `$XDG_CONFIG_HOME/niri/config.kdl` →
`/etc/niri/config.kdl` (fallback). Editing `/etc/niri/config.kdl` in the live
script would also require reverting it for the installed system — messier
than just shadowing it for `liveuser`.

**Fix:** copy the shipped `/etc/niri/config.kdl` into `liveuser`'s XDG config
and uncomment `skip-at-startup` via `sed`, so the live override composes with
the shipped config instead of hand-rolling a separate minimal one that could
drift from it:

```bash
mkdir -p /home/liveuser/.config/niri
sed 's/^    \/\/ skip-at-startup$/    skip-at-startup/' \
    /etc/niri/config.kdl > /home/liveuser/.config/niri/config.kdl
chown -R liveuser:liveuser /home/liveuser/.config
```

### noctalia welcome/onboarding popup (2026-07-02)

**What:** noctalia-shell shows a first-run welcome popup unless
`~/.local/state/noctalia/.setup-complete` already exists for the user.

**Why:** confirmed via upstream noctalia state-file convention (not
guessable from the krytis repo alone — see
[krytis#236](https://github.com/starlit-os/krytis/issues/236#issuecomment-4862419237)).

**Fix:** pre-seed the marker for `liveuser`, mirroring how
`gnome-initial-setup-done` is pre-seeded for GNOME-based live images
elsewhere in this repo (`dakota/src/configure-live.sh`,
`live/src/configure-live.sh`):

```bash
mkdir -p /home/liveuser/.local/state/noctalia
touch /home/liveuser/.local/state/noctalia/.setup-complete
chown -R liveuser:liveuser /home/liveuser/.local
```

### Sealed (UKI) payloads must be embedded byte-identically (2026-08-01)

**What:** krytis's `mise run build-iso --sealed` embeds `ghcr.io/starlit-os/krytis:sealed`,
whose UKI has a `composefs=<sha512>` digest baked into its frozen kernel cmdline at seal
time. `bootc install` recomputes that digest over the image it installs and aborts with
"The UKI has the wrong composefs= parameter" on any mismatch.

**Why it bites here:** the payload pipeline mutates every payload it embeds —
`00-defaults.toml`, `/etc/containers/storage.conf`, and two `buildah commit --squash`
round trips whose only observable effect can be a `/tmp` + `/var/tmp` mtime bump. All
three invalidate the digest. Harmless for unsealed payloads (no digest to invalidate),
which is why it went unnoticed until krytis became the first sealed payload.

**Fix:** `PAYLOAD_SEALED=1` makes `scripts/iso-sd-boot.sh` skip payload prep entirely and
`payload-prep.sh` pass the archive through, so the store receives the exported image
byte for byte. `PAYLOAD_REF` moves the store key and recipe.json's
imgref/targetImgref/image/local_imgref together — moving only one breaks either the
install (local_imgref unresolvable) or the first `bootc upgrade` (targetImgref points at
the unsigned image, which the enrolled firmware then refuses).

**Aside, unrelated to sealing:** the `/etc/containers/storage.conf` injection lands on
every *installed* dakota system too, pinning its podman to the vfs driver. Probably not
intended; not changed here because unsealed behaviour is deliberately left byte-identical.

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

**What:** `mise run build-iso` previously required a sibling `kitten-lily/dakota-iso`
checkout and called `just` into it via `DAKOTA_ISO_DIR`. The pipeline is now native in
this repo (issue #838).

**Structure:**

```
live/
  Containerfile              # 3-stage build (ref → Debian initramfs-builder → final)
  iso-tools/
    Containerfile            # Fedora-based: xorriso, mtools, buildah, skopeo, isomd5sum
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
```

**Key difference from dakota-iso:** `scripts/iso-sd-boot.sh` here does NOT call
`just ... container` to build the live installer — that container must already
exist (`localhost/krytis-installer`) before this script is invoked. `build-iso`
handles the container build via the inline `podman build` step before calling
`iso-sd-boot.sh`. `iso-container-build` can build it independently for iteration.

**payload-prep.sh** lives only in `kitten-lily/dakota-iso` and is referenced via
`ISO_TOOLS_IMAGE` bind-mount — it is not copied here because sealed payloads
(`PAYLOAD_SEALED=1`) skip it entirely, and `kitten-lily/dakota-iso` is still used
for test path tasks (issues #839, #840). When #840 lands, revisit whether to inline it.
