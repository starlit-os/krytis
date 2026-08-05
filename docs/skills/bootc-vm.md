# bootc VM Boot Debugging

Load when the VM fails to boot, diagnosing initramfs failures, or working on
`elements/core/initramfs.bst`.

## Composefs boot chain

```
systemd-gpt-auto-generator   ← detects GPT type 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
  └── generates sysroot.mount (mounts btrfs at /sysroot; no root= karg needed)
        └── bootc-root-setup.service
              └── /usr/lib/bootc/initramfs-setup setup-root
                    └── mounts EROFS composefs image over /sysroot
                          └── initrd-switch-root.service
                                └── systemctl switch-root /sysroot
```

`bootc-root-setup.service` has `ConditionKernelCommandLine=composefs` — it only
runs when `composefs=<hash>` is in the kernel command line (set by `bootc install`).
If this service is skipped or absent, `/sysroot` stays as raw btrfs (no `/usr/`),
and `initrd-switch-root.service` fails with "no init found".

## `/etc` changes DO reach existing deployments on `bootc upgrade` — don't assume otherwise

Shipping config to `/etc` (as `config/u2f-config.bst` does for `/etc/pam.d/system-auth`) looks like it might be fresh-install-only on this backend. It isn't. Verified against bootc **v1.16.6** source (`cf828dc1`), composefs-native path:

| question | answer |
|---|---|
| Merge base | The **booted image's own `/etc`**, read by mounting its EROFS/composefs image (`bootc_composefs/finalize.rs::composefs_backend_finalize` → `pristine_etc`). Not `/usr/etc`. Not `/usr/share/factory/etc`. |
| New deployment's `/etc` | Fresh `cp -a --remove-destination <erofs>/etc/.` into `/sysroot/state/deploy/<digest>/etc` (`bootc_composefs/state.rs::initialize_state`), then local modifications re-applied at finalize. |
| Unmodified image file, new image changes it | **Gets the new content.** It is byte-identical to the base, so it never lands in `diff.modified` and the freshly copied version survives. |
| Locally modified file | Frozen at the local version — `merge_leaf` deletes the new image's copy and writes the live one back. |

Two traps that make this easy to get wrong from the outside:

- **No `/usr/etc` on a booted krytis is the expected signature of the composefs-native backend, not evidence that `/etc` merging is off.** The `etc` → `usr/etc` remap (`ostree-ext/src/tar/write.rs::remap_etc_path`) is the *ostree-backed* path only; composefs-native reads `<image>/etc` directly and has its own Rust implementation in `crates/etc-merge`.
- **`/usr/share/factory/etc` is never read by bootc** — zero hits across `crates/lib/src`, `crates/etc-merge`, `crates/tmpfiles`, `crates/sysusers`. It is purely systemd's (`tmpfiles.d` `C`/`C+`, `systemd-firstboot`). So `image.bst` stripping `/usr/share/factory/etc/pam.d/*` cannot affect the merge, and an empty factory `pam.d/` proves nothing about upgrade reach. (Only `/var` has a factory remap, in the ostree tar importer.)

The reproducible build timestamp is also a red herring: `stat_eq_ignore_mtime` compares uid/gid/mode/xattrs only, and content is compared by SHA-256 / fs-verity digest. A pristine `/etc` file still stamped `2011-11-11 12:11:11` reads as unmodified, which is what you want.

Consequences worth designing around:

- **`bootc upgrade` hard-fails** — `anyhow::bail!("Merge conflicts found in etc")` in `bootc_composefs/update.rs` — if any path is unmergeable (a file↔directory type flip between live and new `/etc`). Never turn a shipped `/etc` file into a directory, or vice versa, without a migration.
- **uid/gid/mode/xattr changes count as modification**, not just content. A user who `chmod`s a shipped `/etc` file freezes it against all future image updates.
- **A file the admin deleted from `/etc` stays deleted** even if a new image ships it again (`diff.removed` is re-applied to the new tree).
- A user who hand-edited a file you are fixing keeps their version and will **not** receive the fix. That population needs to be told, not silently assumed covered.

The merge runs at *finalize* time (shutdown, or `bootc upgrade --apply`), not at stage time — a download-only staged deployment hasn't merged yet.

## `/etc` and `/var` need the `rw` karg

*Fixed in #396. Symptom set is broad — recognise it fast.*

krytis passes no `root=` karg, so `systemd-gpt-auto-generator` mounts the root
partition at `/sysroot`. It only passes `MOUNT_RW` when a bare **`rw`** is on the
kernel command line — in `gpt-auto-generator.c`, `arg_root_rw` starts at `-1` and
only `rw`/`ro` ever set it:

```c
(arg_root_rw > 0 ? MOUNT_RW : 0)
```

bootc's composefs `setup-root` then derives `/etc` and `/var` as `open_tree()`
bind clones of that mount (`crates/initramfs/src/lib.rs`, `mount_subdir` →
`bind_mount`), so **both inherit the read-only superblock**. Only the `/sysroot`
clone and the composefs `/` are read-only *deliberately*
(`set_mount_readonly()`); `/etc` and `/var` being read-only is a bug.

Nothing repairs it on the composefs path:

- `ostree-remount.service` — which does exactly this job under classic ostree —
  is `ConditionKernelCommandLine=ostree`, and the composefs backend puts
  `composefs=<digest>` on the cmdline instead. Journal: *"ostree-remount.service
  skipped, unmet condition check ConditionKernelCommandLine=ostree"*.
- `files/bootc-config/prepare-root.conf`'s `[sysroot] readonly` is read by
  `ostree-prepare-root`, which is skipped for the same reason. It is **inert**.
- `systemd-remount-fs` only ever targets `/`, which is the composefs overlay, so
  it fails with `mount: /: fsconfig() failed: overlay: No changes allowed in
  reconfigure.`

**Fix:** `kargs = ["rw"]` in `/usr/lib/bootc/kargs.d/` — see
`files/bootc-config/10-root-rw.toml`. Freedesktop SDK's own VM boot elements use
`rw quiet splash` for the same reason. As a bonus it stops gpt-auto emitting the
`50-remount-rw.conf` drop-in, which removes the `systemd-remount-fs` failure too.

**Recognising the symptom.** A read-only `/etc`+`/var` produces ~19 failed units
that look like unrelated bugs. Any of these means "check the mount flags first":

| Unit | Message |
|---|---|
| `sshd.service` | `ssh-keygen: Could not save your private key in /etc/ssh/ssh_host_*: Read-only file system` → `sshd: no hostkeys available -- exiting` → 5 restarts → `start-limit-hit` |
| `systemd-logind`, `systemd-homed`, `upower`, `accounts-daemon`, `power-profiles-daemon` | `Failed to set up special execution directory in /var/lib: Read-only file system` |
| `greetd` | `pam_systemd(greetd:session): Failed to create session: Failed to activate service 'org.freedesktop.login1': timed out` — a *downstream* effect of logind failing |
| `greeter-config-seed` | `install: Read-only file system` on `/var/lib/noctalia-greeter/greeter.toml` |
| `systemd-networkd` | `The persistent storage is on read-only filesystem` |

Confirm in one shot from inside the guest:

```bash
findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS   # want rw on /etc and /var
```

Expected topology once fixed — note `/` and `/sysroot` stay `ro` on purpose:

```
/         composefs:<digest>                     overlay  ro
/sysroot  /dev/vda3                              btrfs    ro
/etc      /dev/vda3[/state/deploy/<hash>/etc]    btrfs    rw
/var      /dev/vda3[/state/os/default/var]       btrfs    rw
```

## `systemd-firstboot` / `systemd-homed-firstboot` block the boot once `/etc` is writable — fixed by moving them off the critical path, not by disabling them

`systemd-firstboot.service` is `ConditionPathIsReadWrite=/etc` +
`ConditionFirstBoot=yes`, ordered `Before=sysinit.target` by default, with
`StandardInput=tty` and `--prompt-root-password`. The image ships
`root:!unprovisioned` in `/etc/shadow`, which firstboot reads as "no password
set", so it prompts *"Please enter the new root password (empty to skip)"* on the
console and waits forever. `sysinit.target` never completes, so nothing after it
starts — no greetd, no sshd, no logind. `systemd-homed-firstboot.service` (the
homed equivalent, `homectl firstboot`) has the same shape one target later —
`Before=systemd-user-sessions.service`, no timeout — and ships `disable`d by
freedesktop-sdk's own preset, presumably for this exact reason.

This was latent for as long as `/etc` was read-only (the condition check failed
and the unit was silently skipped). Fixing the `rw` karg is what exposed it.

**Old fix (superseded — see `docs/design/first-boot-setup.md`):**
`kargs = ["systemd.firstboot=no"]`. This globally suppressed
`systemd-firstboot.service`'s interactive prompting (`systemd-firstboot(1)`:
"If off, systemd-firstboot.service will not interactively query the user...")
— it does **not** touch `ConditionFirstBoot=` evaluation itself, and has no
effect on `systemd-homed-firstboot.service` at all (that unit was, and would
still be, suppressed only by its own preset). It also meant krytis could never
use this tooling for real first-boot setup, since the karg silences *every*
`--prompt-*` flag on the unit, not just the root-password one.

**Current fix:** `config/systemd-firstboot.bst` ships drop-ins
(`systemd-firstboot.service.d/10-krytis.conf`,
`systemd-homed-firstboot.service.d/10-krytis.conf`) that drop
`--prompt-root-password` from `ExecStart` (root stays locked), re-point both
units at a reserved VT (`TTYPath=/dev/tty2`) instead of `/dev/console`, and
clear `Before=sysinit.target` / `Before=systemd-user-sessions.service` so
neither one can block boot or login — an unattended boot always reaches
graphical.target whether or not anyone answers. `systemd-homed-firstboot.service`
is re-enabled via a numerically-prefixed preset
(`80-systemd-homed-firstboot.preset` sorts before fdsdk's unprefixed
`systemd-homed-firstboot.preset`, so it wins). See
`docs/design/first-boot-setup.md` for the full rationale.

Diagnosing a stall like this: a unit stuck in `activating` before
`sysinit.target` starves the whole transaction. `systemctl list-jobs` shows
everything `waiting` and `systemctl list-units --state=activating` names the
culprit. If the culprit has `StandardInput=tty`, screendump the VGA console (see
§ Reading a stalled guest without root) to see what it is asking.

## `Failed to send audit message: Invalid argument` is a libaudit rejection, not audit being broken

`systemd-update-utmp.service` failing with

```
systemd-update-utmp[572]: Failed to send audit message: Invalid argument
```

was the only failed unit on an otherwise healthy boot (#417), which is why
`mise run boot-test` used to accept `degraded` as well as `running` — and why
that assertion was worthless: `degraded` *was* the healthy state, so no future
unit failure could have changed the verdict. The message
never reaches the kernel: libaudit's `_get_commname()` rejects any `comm`
argument of 16 bytes or more (`AUDIT_COMM_LEN`, the kernel's `TASK_COMM_LEN`)
with `EINVAL` before it touches the netlink socket, and systemd ≤ v260 passes
the 19-byte `"systemd-update-utmp"`. It only tolerates `EPERM`, so the unit
exits 1. Upstream fix `b8968c49` shortens the literal to `"update-utmp"`;
krytis backports it via `elements/overrides/systemd-base.bst` until the
gnome-build-meta junction reaches v261.

With the unit fixed, `boot-test` asserts `running` and nothing else, prints the
state it observed, and lists the failed units when there are any — verified on
a secure-boot install of the patched image, which reports `system state:
running`. Keep it that way: an assertion that accepts the current breakage is
not an assertion.

**The general technique — locate the failure on the right side of the
syscall.** An audit send that reaches the kernel and is refused comes back
`EPERM` (`CAP_AUDIT_WRITE`), so calling the same libaudit function as an
*unprivileged* user separates the two cases with no VM and no root:

```python
import ctypes, ctypes.util
la = ctypes.CDLL(ctypes.util.find_library("audit"), use_errno=True)
fd = la.audit_open()
for comm in (b"systemd-update-utmp", b"systemd-update-"):   # 19 vs 15 bytes
    ctypes.set_errno(0)
    la.audit_log_user_comm_message(fd, 1127, b"", comm, None, None, None, 1)
    print(comm, ctypes.get_errno())    # 22 EINVAL (libaudit) vs 1 EPERM (kernel)
```

`EPERM` means the message got out of userspace, so the kernel audit path is
healthy and the argument is the problem. Cross-check with a raw
`NETLINK_AUDIT` `AUDIT_SYSTEM_BOOT` send (also `EPERM` unprivileged), and with
the journal: PID 1 emits `SERVICE_START` audit records in the same millisecond
the unit fails — including one for the failing unit itself.

Corollaries worth remembering: `auditd` being up is not evidence that a
userspace audit call will succeed, and it is not implicated by this failure at
all (`systemd-update-utmp.service` is already `After=auditd.service`); and this
failure is not the read-only-`/var` one fixed in #403, which logged `Failed to
write wtmp record, ignoring: Read-only file system` — note the `ignoring`.

## Known fix: dracut bootc module unit placement

The bootc dracut module places `bootc-root-setup.service`'s wants symlink at
`/initrd-root-fs.target.wants/` (initramfs root) instead of
`/usr/lib/systemd/system/initrd-root-fs.target.wants/`. systemd doesn't look at
the root level, so the service is never pulled in.

**Fix** (already applied in `elements/core/initramfs.bst`): write a dracut.conf.d
snippet before running dracut:

```bash
printf 'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
  | tee "%{install-root}/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf" \
       "/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf"
```

This tells the bootc module where to install its systemd units.

## Inspecting the initramfs

```bash
# List all contents
lsinitrd /run/media/lily/EFI-SYSTEM/EFI/Linux/bootc_composefs-<hash>/initrd

# Read a specific file out of the initramfs
lsinitrd <initrd-path> -f usr/lib/systemd/system/bootc-root-setup.service

# Check which dracut modules are loaded
lsinitrd <initrd-path> -f usr/lib/dracut/modules.txt

# Check kernel modules are present
lsinitrd <initrd-path> | grep -E 'erofs|overlay'
```

## Btrfs disk layout (bootc composefs)

```
/                      btrfs root
├── boot/              EFI stubs, boot files
├── composefs/         EROFS images (mode 700 — root only)
│   └── <hash>         the composefs image for the active deployment
└── state/
    ├── deploy/
    │   └── <hash>/
    │       ├── etc/   writable /etc overlay for this deployment
    │       └── var/   writable /var
    └── os/
```

The full OS (`/usr/`, `/bin/`, etc.) exists only inside the composefs EROFS image.
If composefs doesn't mount, `/sysroot` has no init and switch-root fails.

**Modifying /etc from the host:** the overlay at
`/run/media/lily/root/state/deploy/<hash>/etc/` is writable btrfs (root-owned).
This is the live `/etc` for that deployment — changes here survive reboot.
Useful for setting a root password or unlocking accounts without rebuilding.

## Boot debug techniques

### An EMPTY serial log is never an image bug — read it as "firmware never printed"

`boot-test` failing with

```
==> FAIL: SSH never came up within 240s.
    Serial log is empty — qemu produced no output at all.
```

looks identical to a broken image and is not one. Zero serial bytes means the *firmware* never printed, so nothing from the image ever executed. Do not go looking at the OS, the UKI, or composefs.

The cause that actually bit (#414) was the **machine type**: distro edk2 ships `OvmfPkgX64`, which is q35-targeted, and it is completely mute on qemu's default `pc` (i440fx). `boot-test`/`boot-vm` set `MACHINE_ARGS="q35,smm=on"` only on the `--secure` path and used to leave it empty otherwise, so plain `mise boot-test` silently never booted while `--secure` worked — which is why it went unnoticed through a whole run of secure-boot work.

**Isolate it by varying one thing.** Launch qemu with the same firmware wiring and *no disk*, changing only `-machine`:

| `-machine` | serial bytes after 25s |
|---|---|
| omitted (default `pc`) | **0** |
| `q35` | 137 — `>>Start PXE over IPv4.` |

Check the firmware pair too: `OVMF_CODE` + `OVMF_VARS` sizes must sum to the flash size, or OVMF can hang mutely. The 4M pair is `3653632 + 540672 = 4194304`. A 4M `CODE` against a 2M `VARS` is a classic silent hang.

### Test the harness itself, unprivileged, with a blank disk

`--reuse-disk` skips `generate-disk` — the only step needing root — and it accepts **any** file, not just a real installed disk. So a 2 GB file of zeros is enough to exercise everything after the install:

```bash
truncate -s 2G /tmp/empty-boot.raw
mise boot-test --reuse-disk /tmp/empty-boot.raw --debug-keep
```

A healthy harness reaches EDK2's boot manager and says so:

```
BdsDxe: failed to load Boot0002 "UEFI Misc Device" ...: Not Found
>>Start PXE over IPv4.
BdsDxe: No bootable option or device was found.
```

That output *is* the pass signal for the harness — the run still fails (a blank disk is not bootable), but firmware, serial capture, credential injection and the diagnostics chain are all proven. It is the cheapest available A/B for "is this the image or the harness?", it needs no sudo, and it separates the two in one 240s run instead of a rebuild-and-reinstall cycle.

**Use `--debug-keep`.** Without it the `EXIT` trap deletes `WORKDIR`, taking `serial.log` with it, so a failing run leaves nothing to read.

**Gotcha when running a task from a worktree:** `mise` resolves tasks from the directory it starts in. Launch it with the worktree as the working directory — if the `cd` silently fails, you get the *main* checkout's task and will conclude your fix did nothing. Check the `[boot-test] $ <path>` line mise echoes: it names the script that actually ran.

### Reading a stalled guest without root

**Use this first.** It works under secure boot, needs no `sudo`, no
`losetup`/`mount`, no disk mutation, and no `console=` karg — so it survives the
two things that make secure-boot UKI debugging painful: an unwritable disk and a
signed, uneditable cmdline.

`systemd-debug-generator` consumes the credentials `systemd.extra-unit.<name>`
and `systemd.unit-dropin.<unit>`, and QEMU can hand credentials to the guest over
SMBIOS type 11. Credentials are **not** part of the signed cmdline, so secure
boot does not block them. So: inject a unit that dumps whatever you want to
`/dev/ttyS0`, which QEMU writes to a host file.

```bash
printf '[Unit]\nWants=krytis-probe.service\n' > dropin.conf

cat > probe.service <<'EOF'
[Unit]
Description=krytis guest probe
DefaultDependencies=no
[Service]
Type=simple
ExecStart=/bin/bash /run/credentials/krytis-probe.service/probe.sh
ImportCredential=probe.sh
StandardOutput=file:/dev/ttyS0
StandardError=file:/dev/ttyS0
EOF

b64() { base64 -w0 < "$1"; }
qemu-system-x86_64 ... \
    -serial file:serial.log \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(b64 dropin.conf)" \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.krytis-probe.service=$(b64 probe.service)" \
    -smbios "type=11,value=io.systemd.credential.binary:probe.sh=$(b64 probe.sh)"
```

Use `io.systemd.credential.binary:` (base64) rather than `io.systemd.credential:`
so multi-line unit files survive intact.

Gotchas learned the hard way:

- **A `Wants=` drop-in on `multi-user.target` is what pulls the unit in.** An
  injected `systemd.extra-unit.*` with only `[Install] WantedBy=` is never
  enabled, so it never runs.
- **If the boot stalls before `sysinit.target`, give the probe unit
  `DefaultDependencies=no` and *no* `After=`.** Anything ordered after
  `sysinit.target`/`basic.target` (or a `Type=oneshot` that blocks them) will
  never run — which looks identical to "the injection didn't work". Use
  `Type=simple` plus a `sleep` inside the script when you want a late snapshot
  without blocking the transaction.
- `systemd.unit-dropin.multi-user.target` adding `Wants=sshd.service` is also the
  cleanest way to enable a service in a deployed image for a single boot — no
  need to mount the disk and hand-place a `multi-user.target.wants` symlink.

Worth dumping: `systemctl list-jobs`, `systemctl list-units --state=activating`,
`systemctl --failed`, `findmnt -A`, `journalctl -b -p err`, `ss -tlnp`.

### Screendump the console instead of guessing

A UKI's cmdline has no `console=ttyS0` (it is a desktop cmdline: `rw quiet splash
rd.luks.options=... composefs=...`), and under secure boot
you cannot edit it at the systemd-boot menu — the cmdline is baked into the signed
PE. So the serial log goes silent right after `BdsDxe: starting Boot0004 "Linux
Boot Manager"`. **That silence is expected, not a hang.**

To see the real console, add `-vga std -display none` plus a monitor socket and
ask QEMU for the framebuffer:

```
screendump /path/to/screen.ppm
```

then `magick screen.ppm screen.png`. This is how the `systemd-firstboot` root
password prompt was found. Note `socat` is not installed on the dev box — drive
the HMP monitor socket from a few lines of Python `AF_UNIX` instead.

### `journalctl -D <dir> -b` is broken for offline journals

`-b` filters by *this host's* current boot ID, which never matches anything in an
external journal directory, so you get "No journal boot entry found for the
specified boot (+0)" even when the journal is full of data. Drop `-b`, or run
`--list-boots` first and pass an explicit ID:

```bash
JDIR=/mnt/guestroot/state/os/default/var/log/journal   # NOT state/deploy/<hash>/var
journalctl -D "$JDIR" --list-boots --no-pager
journalctl -D "$JDIR" --no-pager
```

The live `/var` for a running deployment is `state/os/default/var/` (shared across
deployments in the same stateroot). `state/deploy/<hash>/var/` is just an empty
bind-mount target — nothing is ever written there.

### `kex_exchange_identification: Connection reset` means nothing is listening

QEMU SLIRP `hostfwd` completes the host-side TCP handshake *before* connecting to
the guest, so when the guest port is closed the client gets an RST only after
sending its banner:

```
kex_exchange_identification: read: Connection reset by peer
```

This is **not** an sshd bug and **not** an sshd config problem — it is the
signature of "no listener in the guest". Do not go debugging sshd internals from
it. Two cheap disambiguations, both root-free:

- `info usernet` on the QEMU monitor lists the SLIRP connection table. If you see
  the guest doing NTP/mDNS from `10.0.2.15`, the guest is booted and networked and
  only that one port is closed.
- Sanity-check sshd itself in the container image, which takes seconds:
  `podman run -d -p 127.0.0.1:2401:22 --entrypoint /bin/sh <image> -c 'mkdir -p
  /var/empty /run/sshd; ssh-keygen -A; exec /usr/bin/sshd -D -e'` then ssh to it.

### Get a shell before switch-root

Add to the kernel command line (edit the loader entry on the EFI partition):

```
rd.break=switch-root
```

This triggers `breakpoint-pre-switch-root.service`, which drops a `/bin/sh` shell
on the console **without requiring any password**. At this point composefs is
already mounted at `/sysroot`.

To set a root password from this shell:

```sh
mount --bind /proc /sysroot/proc
mount --bind /dev  /sysroot/dev
mount --bind /sys  /sysroot/sys
chroot /sysroot passwd root
exit
```

### Unlock the emergency shell

When the system drops to emergency mode and sulogin refuses login ("root account
is locked"), add:

```
systemd.setenv=SYSTEMD_SULOGIN_FORCE=1
```

This bypasses the root password check in `sulogin`. Only affects the initramfs
emergency shell (sulogin), not the real system's login manager.

### Boot failure report

On initramfs failure, dracut writes a report to `/run/initramfs/rdsosreport.txt`
in the running initramfs. It contains the full journal from the failed boot.
Accessible only from a shell in the initramfs (e.g. via `rd.break` or emergency
shell).

### Graphical display vs serial console

`mise run boot-vm` gives `-serial stdio` (ttyS0), which shows systemd journal
output. The virtual consoles (tty1–tty9) live on the `virtio-vga` device, *not*
on serial — so a debug shell or prompt on any tty other than ttyS0 is invisible
there. Reaching it needs a graphical backend, which a krytis host does not have
(see the next § ) — fall back to HMP `screendump`.

### `boot-vm` is headless on a krytis host — there is no window to type into

`elements/dev/qemu.bst` deliberately builds qemu with `--disable-gtk
--disable-sdl --disable-vnc --disable-spice --disable-curses`, so on krytis
itself:

```console
$ qemu-system-x86_64 -display help
Available display backend types:
none
dbus
```

`mise run boot-vm` used to pass `-display gtk` unconditionally and died with
`Parameter 'type' does not accept value 'gtk'` — it could never have worked on
this image. It now negotiates (`gtk` → `sdl` → `none`) and accepts
`--display <type>`, failing with the supported list instead of qemu's message.

**Consequence for test planning:** any verification needing *interactive* input
inside the guest — answering a VT prompt, using the greeter, typing a password —
is **not** achievable with `boot-vm` on a krytis host, and `boot-test` cannot do
it either (serial-only harness, and it boots a throwaway copy). Options:

| Need | Use |
|---|---|
| Automated boot verdict | `mise run boot-test` — copies the disk; unprivileged except `generate-disk` |
| State persisting across two boots (set up, reboot, re-check) | `mise run boot-vm` — boots the disk **in place**, no `-snapshot`, so writes survive |
| See what a VT is showing | HMP `screendump /tmp/x.ppm` (§ Screendump the console instead of guessing) |
| Send keys to a VT | HMP `sendkey ctrl-alt-f5`, then one key name per character — drops characters, so screendump after each batch |
| Genuinely interactive session | Real hardware, or rebuild `dev/qemu.bst` with `--enable-gtk` (reverses a deliberate decision — raise it first) |

Note `boot-vm`'s **fallback** path (no native qemu, `ghcr.io/qemus/qemu`) passes
`ARGUMENTS=-snapshot`, which *discards* writes. Any test relying on state
persisting across two boots silently passes for the wrong reason there.

### Interactive VM testing via GNOME Boxes

This is the way around the previous § on a krytis host: Boxes (and virt-manager)
are flatpaks shipping their *own* qemu/SPICE stack, so they are unaffected by
`dev/qemu.bst` disabling every display backend. Use them whenever a check needs
typing inside the guest — a VT prompt, the greeter, a password.

```shell
BOXES_IMG=~/.var/app/org.gnome.Boxes/data/gnome-boxes/images/krytis-vt.qcow2
mise run generate-disk --disk /var/tmp/krytis-vt.raw --size 15G   # needs sudo
mise run convert-to-qcow2 --disk /var/tmp/krytis-vt.raw --output "$BOXES_IMG"
# Boxes -> + -> Install from file -> $BOXES_IMG
```

Verified end to end on 2026-08-05: this reaches the noctalia greeter on vt1, and
`Ctrl+Alt+F5` reaches `krytis-firstboot.service`'s wizard on tty5, which creates
the initial homed user (#487).

**Put the qcow2 under `$HOME`, not `/var/tmp`.** Boxes is granted
`filesystems=host`, which sounds like `/var/tmp` works — it does not. Flatpak's
`host` does **not** bind the host's `/var`, so the sandbox has its own empty
`/var/tmp` and cannot see the file at that path at all:

```console
$ flatpak run --command=sh org.gnome.Boxes -c 'ls /var/tmp'   # empty
```

Boxes' file chooser then exports the file through the **XDG document portal** as
the only way to reach it, and the VM dies before firmware with:

```
Failed to get "consistent read" lock: Input/output error
Is another process using the image [/run/user/1000/doc/…/krytis-vt.qcow2]?
```

That message is misleading — nothing else has the image. `/run/user/$UID/doc` is
`fuse.portal`, qemu locks images with `F_OFD_SETLK`, and FUSE does not implement
it, so the lock attempt returns `EIO`. Reproducible with no VM involved:

```console
$ qemu-io -c quit -f qcow2 /run/user/1000/doc/…/krytis-vt.qcow2
qemu-io: can't open device …: Failed to get "consistent read" lock: Input/output error
$ qemu-io -c quit -f qcow2 /var/tmp/krytis-vt.qcow2     # clean
```

`$HOME` *is* bound into the sandbox (that is where Boxes keeps its own nvram), so
write there in the first place — `mise run convert-to-qcow2` warns when the
output is outside `$HOME`:

```shell
mise run convert-to-qcow2 --disk /var/tmp/krytis-vt.raw \
    --output ~/.var/app/org.gnome.Boxes/data/gnome-boxes/images/krytis-vt.qcow2
```

`$HOME` and `/var/tmp` are the same btrfs, so `cp --reflink=auto` moves an
already-converted image across for free. To repoint an existing VM, edit
`<source file=…>` via the flatpak's own virsh — Boxes ships one at `/app/bin`:

```shell
V() { flatpak run --command=virsh org.gnome.Boxes -c qemu:///session "$@"; }
V dumpxml <vm> > ~/vm.xml     # NB: write to $HOME; the flatpak has its own /tmp
V define ~/vm.xml
V start <vm>
```

Two more things:

- **Firmware is fine unattended.** Boxes selected `firmware="efi"` with
  `secure-boot` on and `enrolled-keys` off — setup mode, so an unsealed image
  boots, and krytis's `secure-boot-enroll.service` only appends
  `secure-boot-enroll manual` to `loader.conf`; it enrols nothing by itself.
- **Boxes may hold an older copy** of the image depending on how it was added, so
  "the change I just rebuilt isn't there" usually means the VM still points at a
  previous file. Check `<source file=…>` before re-testing.

`virsh screenshot <vm> ~/shot.ppm` (then `magick ~/shot.ppm ~/shot.png`) reads
the SPICE display without touching the guest — the reliable way to see which VT
is showing what, and `V send-key <vm> --codeset linux KEY_LEFTCTRL KEY_LEFTALT
KEY_F5` switches VT from outside the guest.

`convert-to-qcow2` refuses to overwrite an existing output without `--force`,
precisely because a stale qcow2 boots old content that looks current.

## `podman save` Must Use `--format oci-archive` for bootc

When transferring an image between rootless and rootful podman stores for `bootc install to-disk`, always use:

```bash
podman save --format oci-archive <image> | sudo podman load
```

The default `docker-archive` format converts OCI layer media types from `application/vnd.oci.image.layer.v1.tar+gzip` to the Docker equivalent. When bootc processes the image with `--composefs-backend`, the Docker media type causes composefs stream name resolution to return an empty string:

```
Invalid splitstream content type
```

`--format oci-archive` preserves the OCI media types and resolves this.

## dracut files belong in the bootc element, not initramfs element

*Source: zirconium-hawaii `928fdf8` — `fix(initramfs): put dracut files into bootc element`*

Non-obvious placement rule from zirconium-hawaii: dracut files go in the `bootc.bst` element, not `initramfs.bst`. Krytis's current layout puts dracut config in `core/initramfs.bst` (the bootc dracut module fix documented above), which works for our case — but if adding additional dracut files specific to bootc behavior, place them in the bootc element to match the convention.

## Temporary root password for VM testing

The `Containerfile` has a commented line for setting a debug root password:

```dockerfile
# Uncomment to set a temporary root password for VM login during debugging.
# Remove before shipping — not for production use.
# RUN echo 'root:krytis' | chpasswd
```

After uncommenting: `mise run lint && mise run generate-disk`.

## Two install paths, two tests: `boot-test` vs `iso-install-test`

`mise run boot-test` installs with `bootc install to-disk --via-loopback` straight
from a local image. That is *not* how a user installs Krytis, and it exercises
none of the ISO machinery: no offline VFS store, no live installer, no
`recipe.json`, no `targetImgref`. `mise run iso-install-test` boots the live ISO
in QEMU and drives fisherman over SSH, which is the real path — so it is the only
test that can catch a broken payload embed, a wrong store key, or an imgref that
sends the installed system to the wrong upgrade stream.

| Command | Exercises |
|---|---|
| `mise run boot-test` | image → disk (`bootc install to-disk`), boot, health |
| `mise run boot-test --secure` | the same under enforcement, signed image |
| `mise run iso-install-test` | ISO → live session → fisherman → disk, boot |
| `mise run iso-install-test --secure` | as above, installed disk under enforcement |
| `mise run iso-install-test --secure --expect-fail` | enforcement refuses an unsigned install |
| `mise run luks-install-test` | ISO → fisherman → **encrypted** disk, boot, answer the passphrase |
| `mise run luks-install-test --strict-installer` | as above, but fail if the installer types the root GUID wrongly |
| `mise run luks-boot-test` | synthetic LUKS2 disk + real UKI — the boot half, no installer |

Two things about the ISO variants that are easy to get wrong:

**The two phases need different firmware.** The live ISO is deliberately unsigned
(#371 Design Gate: signing it would not make it bootable under stock Secure Boot
anyway, since the firmware does not trust krytis's keys until an install has
enrolled them). So phase 1 boots the ISO with **plain** OVMF and only phase 2, the
installed disk, boots with `.ovmf-vars-secure.fd` and enforcement. Running phase 1
under enforcement is a guaranteed false negative, not a stricter test. `--secure`
therefore means "enforce on the installed disk", and dropping it gives the
"a sealed payload is still a valid ordinary image" case — which is a real
acceptance criterion, not a lesser variant.

**It needs a `--debug` ISO.** sshd is disabled in the live session unless the ISO
was built with `mise run build-iso --debug`, and the install is driven over SSH.
Without it the run dies ~2 minutes in with
`kex_exchange_identification: Connection reset by peer`, which reads like a
network fault. dakota-iso's own CI works around this by unsquashing and patching
production ISOs; locally, just pass `--debug`.

As with `build-iso`, the QEMU/fisherman orchestration lives in dakota-iso
(`just sealed-test-qemu krytis`) and the mise task is a wrapper that resolves
defaults, checks every prerequisite *before* the tens-of-minutes run starts, and
copies the enrolled varstore to scratch so an enforcing boot never writes back to
`.ovmf-vars-secure.fd`.

## A sealed image's console goes to tty0, so an interactive prompt is invisible on serial

Cost two 16-minute gate runs while building `luks-install-test`. The gate reported
*"no LUKS passphrase prompt ever appeared"* against a system that was prompting
perfectly well.

With a VGA device present — and `-display none` still creates one — the kernel's
default console is `tty0`. A sealed UKI's cmdline is signed and cannot be edited, so
`console=ttyS0` is not in it, and the serial log therefore ends at:

```
systemd-boot@0x101300000 260.2
systemd-stub@0x14df91000 260.2
```

which is a *healthy* boot, not a hang. The prompt was written to a framebuffer nobody
was reading. **Absence of expected output on serial is not evidence of absence** — the
same trap `iso-install-test` documents for its verdict, met again one layer down.

**Fix: inject `console=ttyS0` through systemd-stub's SMBIOS cmdline-extra.** The stub
accepts additions when Secure Boot is *not* enforcing, and refuses them when it is —
which is the whole point of sealing, and means this technique and `--secure` are
mutually exclusive. `boot-test` rejects that flag combination up front rather than
running for six minutes to produce a harness artefact:

```bash
-smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0"
```

plymouth stays enabled deliberately: `rd.plymouth=0` would make the prompt easier to
see and would stop testing plymouth's interaction with `systemd-ask-password`, which
is the thing that failed on hardware. The console agent prompts on `ttyS0` regardless.

### To *answer* a prompt, write to a socket chardev — not the emulated keyboard

`sendkey` over the HMP monitor reaches whatever owns tty0 (plymouth, possibly
mid-repaint), needs a QEMU key name per character, and drops characters. A socket
chardev with `logfile=` gives the same log on disk plus a writable channel to the
console the agent is actually reading:

```bash
-chardev socket,id=luksser,path=${WORKDIR}/serial.sock,server=on,wait=off,logfile=${WORKDIR}/serial.log
-serial chardev:luksser
```

**Throttle the write and hold the socket open afterwards.** A single `sendall()` then
`close()` delivered only the first 8 characters of a 14-character passphrase — the
guest echoed `********`, rejected it, and dropped to emergency mode. QEMU discards
whatever is still buffered for the guest when the client disconnects. One byte every
50 ms, then `\n`, then a 2 s sleep before closing: reliable on the first attempt. Same
class of bug as `monitor_cmd`'s deliberate sleep before `close()`.

## An in-guest probe cannot observe `is-system-running` — it is waiting on itself

Serial-console probes are injected as a unit pulled in by `multi-user.target`
(`Wants=`, via an SMBIOS `systemd.unit-dropin` credential — see `mise/tasks/upgrade-test`).
That makes the probe part of the **initial boot transaction**, and
`systemctl is-system-running` stays `starting` until that transaction drains. From
inside the probe it therefore never reads `running`:

```
===KRYTIS-UPGRADE phase=post===
state: starting                    # healthy system, impatient observer
```

`systemctl is-system-running --wait` is worse, not better: it blocks on a queue
containing its own job, so it deadlocks until something times out.

**Report from a transient unit instead.** `systemd-run --on-active=1s` creates the
job *after* the initial transaction, which is the same vantage point `boot-test`
gets by connecting over SSH once the guest is up:

```bash
cp "$0" /run/krytis-upgrade-report.sh
systemd-run --collect --unit=krytis-upgrade-report --on-active=1s \
    --property=StandardOutput=file:/dev/ttyS0 \
    --setenv=KRYTIS_REPORT=1 /bin/bash /run/krytis-upgrade-report.sh
```

Copy the script out of `/run/credentials/<unit>/` first — that mount goes away with
the unit that owns it. Bound the subsequent `--wait` with `timeout` so a genuinely
stuck boot still reports a state rather than hanging until the harness deadline.

Corollary for writing these assertions: an assertion is only as good as where it is
observed from. `boot-test` can assert `state: running` because it asks over SSH
after boot; anything asking from inside the boot has to either move its vantage
point or assert something else (`systemctl --failed` being empty is observable from
anywhere).
## Debian/Ubuntu ship no `*VARS*secboot*` — setup mode is the plain `OVMF_VARS_4M.fd`

Every QEMU task here resolves OVMF by walking a list of candidate paths, and those
paths are distro-specific. Ubuntu 24.04's `ovmf` package (2024.02-2) contains only:

```
OVMF_CODE_4M.fd   OVMF_CODE_4M.ms.fd   OVMF_CODE_4M.secboot.fd   OVMF_CODE_4M.snakeoil.fd
OVMF_VARS_4M.fd   OVMF_VARS_4M.ms.fd                             OVMF_VARS_4M.snakeoil.fd
```

Note the asymmetry: there is a **secboot CODE but no secboot VARS**. Fedora's
`OVMF_VARS_4M.secboot.fd` has no Debian equivalent — the setup-mode varstore is the
bare `OVMF_VARS_4M.fd`, paired with the secboot CODE. A candidate list written on a
Fedora or Arch box therefore finds nothing on a runner and the task dies with
"OVMF secboot vars template not found" before it does any work.

**Never paper over that by reaching for `OVMF_VARS_4M.ms.fd`.** It ships with
Microsoft's keys already enrolled, so the firmware is not in setup mode. Any test
whose premise is "watch the image enrol its own keys" silently stops testing
anything — the enrollment never happens because there is nothing to enrol into.

Verify a candidate is really pristine before trusting it:

```bash
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.fd --print | grep -iE '^ *(PK|KEK|db)'
# no output = setup mode = correct for enroll-test
```

### …and its `OVMF_CODE` carries Microsoft CAs of its own

An empty varstore does not mean an empty `db` after boot: Ubuntu's
`OVMF_CODE_4M.secboot.fd` carries built-in default entries. Measured, with the same
sealed image booted under each firmware:

| krytis ships | Fedora/Arch firmware | Ubuntu firmware |
|---|---|---|
| two of Microsoft's five db CAs (before #464) | `db` 4353 — 3 certs, all ours | `db` 7348 — 5 certs |
| all five (#464 onward) | `db` 8891 — 6 certs, all ours | `db` **8891** — identical |

The two Ubuntu added were `Microsoft UEFI CA 2023` and `Microsoft Option ROM UEFI
CA 2023`, under owner GUID `77fa9abd-0359-4d32-bd60-28f4e78f784b` rather than the GUID
krytis generates — which is how you tell a firmware default from a shipped cert even
when it is the same certificate.

**Shipping all five closed that gap by accident and it is worth understanding why.**
Both of the firmware's extras are now in krytis's own `db`, and the result dedupes to
exactly ours: 8891 either way. Before #464 a CI run trusted two CAs a real machine did
not, so a negative test asserting some binary is *refused* could pass in CI for the
wrong reason. That specific hazard is gone — but do not rely on it, because the
firmware's contribution is still not ours to predict, and a different OEM ships
different defaults.

A `db` size or non-emptiness check is therefore still not evidence the image
contributed anything — a firmware can satisfy it alone. `enroll-test` asserts
`CN=Database Key` is present by name, and prints every db subject in its verdict:

```bash
virt-fw-vars --input vars.fd --extract-certs      # writes db-*.pem into CWD
openssl x509 -in db-….pem -noout -subject
```

Match that output loosely. OpenSSL renders the same subject differently across
versions *within* 3.x — `CN = Database Key` under 3.0.13 on the runners,
`CN=Database Key` under 3.5.7 on this workstation — so `grep 'CN=Database Key'`
would pass locally and fail the gate in CI. Use `CN *= *`. Display-only callers
(`scripts/parse-efi-auth.py`, `mise/tasks/fetch-microsoft-certs`) are unaffected;
only code that *matches* on a subject needs this.

### Resolve OVMF through `scripts/ovmf-paths.sh`, never inline

All six QEMU tasks used to carry their own candidate lists. They drifted, and the
drift stayed invisible until CI ran on a distro none of them covered. One resolver
now owns it (#458) — source it and call one of four functions:

```bash
. scripts/ovmf-paths.sh
OVMF_CODE=$(ovmf_code_secboot)    || exit 1   # firmware that enforces signatures
OVMF_CODE=$(ovmf_code_plain)      || exit 1   # firmware that does not
VARS=$(ovmf_vars_pristine)        || exit 1   # SETUP MODE — no PK, guest enrols its own
VARS=$(ovmf_vars_plain)           || exit 1   # non-Secure-Boot varstore
```

They are four functions rather than two with a flag because mixing up *pristine* and
*enrolled* is a silent hollow test, not a crash. `ovmf_vars_pristine` refuses a
varstore that already has a Platform Key, so the `.ms.fd` substitution cannot happen
by accident.

Two constraints to preserve when editing the lists:

- **Keep the CODE and VARS lists in the same distro order.** They are a matched pair
  whose sizes must sum to 2MB or 4MB; drawing CODE from one distro's directory and
  VARS from another's can straddle the 2M/4M split, and the symptom is a firmware
  that emits no serial output at all rather than an error (#414).
- **`.fd` before `.qcow2`.** Every caller passes `format=raw`, which silently
  misreads a qcow2; the resolver warns if only a qcow2 is available.
