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

## `systemd-firstboot` blocks the boot once `/etc` is writable

`systemd-firstboot.service` is `ConditionPathIsReadWrite=/etc` +
`ConditionFirstBoot=yes`, ordered `Before=sysinit.target`, with
`StandardInput=tty` and `--prompt-root-password`. The image ships
`root:!unprovisioned` in `/etc/shadow`, which firstboot reads as "no password
set", so it prompts *"Please enter the new root password (empty to skip)"* on the
console and waits forever. `sysinit.target` never completes, so nothing after it
starts — no greetd, no sshd, no logind.

This was latent for as long as `/etc` was read-only (the condition check failed
and the unit was silently skipped). Fixing the `rw` karg is what exposed it.

**Fix:** `kargs = ["systemd.firstboot=no"]` — see
`files/bootc-config/40-no-firstboot.toml`. This makes PID 1 treat the boot as a
non-first boot so `ConditionFirstBoot=yes` fails and the unit is skipped cleanly.

It **cannot** be an install-time `bootc install --karg`: UKI images reject
externally specified kernel arguments. It has to be baked via `kargs.d`.

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
`mise run boot-test` had to accept `degraded` as well as `running`. The message
never reaches the kernel: libaudit's `_get_commname()` rejects any `comm`
argument of 16 bytes or more (`AUDIT_COMM_LEN`, the kernel's `TASK_COMM_LEN`)
with `EINVAL` before it touches the netlink socket, and systemd ≤ v260 passes
the 19-byte `"systemd-update-utmp"`. It only tolerates `EPERM`, so the unit
exits 1. Upstream fix `b8968c49` shortens the literal to `"update-utmp"`;
krytis backports it via `elements/overrides/systemd-base.bst` until the
gnome-build-meta junction reaches v261.

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
systemd.firstboot=no rd.luks.options=... composefs=...`), and under secure boot
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

### GTK display vs serial console

`mise run boot-vm` uses `-display gtk` (graphical window) plus `-serial stdio`
(ttyS0). The serial console shows systemd journal output. The GTK window shows
virtual consoles (tty1–tty9). If a debug shell appears on a tty other than ttyS0,
it will only be visible in the GTK window.

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
