# Host requirements for the Razer Devices noctalia plugin

**Issue:** #1224 · **Status (2026-10-13): planned, not started.** Steps 1–5 wait on the spike
(step 0) and on the Design Gate decisions below.

| Plugin | Catalog id | What it executes |
|---|---|---|
| Razer Devices | `detluck/razer` 1.1.0, `plugin_api` 31 | `busctl --user … org.razer` against `openrazer-daemon` on the **session** bus; `systemctl --user start openrazer-daemon` |

From `noctalia-dev/community-plugins` at `1f12fa9` (2026-10-13). The `dependencies =` field in
a plugin's `plugin.toml` is informational only, so the requirements below come from reading
what the plugin executes.

This is krytis's first out-of-tree kernel module, so it is gated on a build spike. The cheap
sibling, MX Control (Solaar), is #1220. The two share one element,
`deps/python3-pyudev.bst`; whichever plan lands first adds it. Each step below is one PR,
except step 0.

## Non-goals

- **Enabling the plugin in `files/noctalia-skel/settings.toml`.** It is hardware-specific. A
  user turns it on in Settings → Plugins (see `docs/skills/desktop.md`
  § noctalia plugins: enabling in skel).
- **Polychromatic, RazerGenie, or the `openrazer` Python client library.** The plugin talks to
  the daemon with `busctl`.
- **Anything against `openrazer/openrazer` or the plugin author.** No issue, no PR, no comment
  without explicit approval (AGENTS.md § Third-party repositories).

## Design Gate decisions

Record each answer on #1224 before starting the step that depends on it.

| # | Decision | Recommendation | Blocks |
|---|---|---|---|
| D1 | Ship out-of-tree kernel modules at all | Decide after step 0. Without them the daemon runs but finds no devices. | steps 1–5 |
| D2 | Carry openrazer/openrazer#2719 (Kraken Kitty V3 Pro, `1532:0588`) | Yes if D1 is yes. The dev box's only Razer device needs it. The PR was open and unmerged as of 2026-10-13. | step 3 |
| D3 | Add `plugdev` to first-boot's `--member-of=` (Breakage Gate: `firstboot-wizard.sh`) | Yes. The daemon refuses to start without it, and an account the wizard creates would otherwise need a manual `homectl update` first. | step 5 |
| D4 | How `openrazer-daemon` starts | A udev `ENV{SYSTEMD_USER_WANTS}+="openrazer-daemon.service"` on Razer devices: it starts only on machines that have one. Alternatives: a global user preset (a Python daemon on every machine), or nothing (the plugin's "Start Daemon" button). | step 5 |

## Reference: measured facts

All measured on `26.08.202610131212`, kernel `7.2.9-2-cachyos`, unless stated otherwise.

### Razer Devices / OpenRazer v3.12.4 (released 2026-07-04)

| Fact | Evidence |
|---|---|
| The daemon finds a device only through its out-of-tree driver: it monitors udev `hid` and requires the driver's sysfs `device_type` file | `daemon/openrazer_daemon/daemon.py:205-208`, `:465`, `:486` |
| In-tree `hid-razer` (shipped, `CONFIG_HID_RAZER=m`) only enables macro keys on three BlackWidow keyboards (`010d`, `010e`, `011b`). `razer_mount` unbinds those from it. | Linux `drivers/hid/hid-razer.c`; `install_files/udev/razer_mount` |
| Modules: `razerkbd`, `razermouse`, `razerkraken`, `razeraccessory`. Build: `make -C $(KERNELDIR) M=driver modules` | Top-level `Makefile:35-38` |
| Daemon Python deps: `daemonize` (imported at top level by `run_openrazer_daemon.py:15`, even under `-F`), `setproctitle`, `dbus-python`, PyGObject, `pyudev` | `daemon/setup.py`; `run_openrazer_daemon.py`; `daemon.py:17-21` |
| `daemonize` 2.5.0 is the last release; the repo was last pushed 2019-12-09 but is not archived | `gh api repos/thesharp/daemonize` |
| In fdsdk, not shipped: `components/python3-dbus.bst`. In no junction: `setproctitle`, `daemonize` (and `pyudev`, shared with #1220) | fdsdk 26.08.2 |
| Session bus: `dbus.SessionBus()` | `daemon/openrazer_daemon/dbus_services/service.py:50-53` |
| Installs `/usr/bin/openrazer-daemon`, `lib/systemd/user/openrazer-daemon.service` (`Type=dbus`, `BusName=org.razer`, `ExecStart=… -F`) and `share/dbus-1/services/org.razer.service` | `daemon/Makefile:10-22` |
| udev: `99-razer.rules` sets `GROUP:="plugdev"` and runs `razer_mount`, which modprobes, rebinds from `hid-generic` or `razer`, and `chgrp -R plugdev`s the sysfs dir | `install_files/udev/`; `Makefile:108-112` (`UDEV_PREFIX`) |
| `plugdev` is mandatory: the daemon exits without the group (`daemon.py:95-99`, check at `:188-200`), and it skips devices whose `device_type` is not group `plugdev` (`:486-492`). There is no `plugdev` group on the image. | `getent group plugdev` → nothing |
| The plugin's liveness check, `busctl --user status org.razer`, does not D-Bus-activate the service | `razer/razer_dbus.luau:16-21`. [INFERENCE] `status` queries the owner and does not call `StartServiceByName`; verify in step 5. |
| `1532:0588` (Kraken Kitty V3 Pro) is not in v3.12.4 or master. openrazer/openrazer#2719 adds it to `razerkraken` with daemon class `RazerKrakenKittyV3Pro` (head `dd3f090`; open as of 2026-10-13, last updated 2026-09-18). | grep of `driver/*.h`, `hardware/*.py` and `99-razer.rules` |

### Kernel and module build

| Fact | Evidence |
|---|---|
| `core/linux-cachyos.bst` repackages CachyOS's prebuilt `linux-cachyos-7.2.9-2-x86_64_v3.pkg.tar.zst`: no headers, no `build/` symlink | Element; `ls /usr/lib/modules/$(uname -r)` |
| The matching `linux-cachyos-headers-7.2.9-2-x86_64_v3.pkg.tar.zst` is in the same repo (34 MB compressed). Its pacman `DEPENDS` include `clang llvm lld`. | `cachyos-v3.db` |
| CachyOS publishes prebuilt out-of-tree module packages only for `nvidia-open`, `r8125` and `zfs`. There is no razer or v4l2loopback package. | `cachyos-v3.db` listing |
| Kernel built with **clang/LLD 23.1.1**, ThinLTO (`CONFIG_LTO_CLANG_THIN=y`). fdsdk 26.08.2 ships **LLVM 22.1.8** (`include/llvm.yml`). | `/proc/version`; fdsdk tag |
| Compiler-sensitive options are off: no `CONFIG_CFI_CLANG`, `RANDSTRUCT_NONE=y`, no `MODVERSIONS`. `X86_KERNEL_IBT=y`, so `objtool` runs on modules. | `/proc/config.gz` |
| Module signing: `MODULE_SIG=y`, `MODULE_SIG_FORCE` off, lockdown `[none]`, Secure Boot disabled on the dev box. The signing key is ephemeral per CachyOS build, so extra modules are unsigned and taint. `docs/design/secure-boot-uki.md` puts module loading outside Secure Boot's scope. | `/proc/config.gz`; `/sys/kernel/security/lockdown` |
| The module index is built at image assembly: fdsdk's `prepare-image.sh:81-86` runs `depmod -b <sysroot> -a <ver>` for every `/usr/lib/modules/*`. `oci/krytis/image.bst:29-33` does not pass `--nodepmod`. The CachyOS package ships no `modules.dep`. So an element that drops `.ko` files into `/usr/lib/modules/<ver>/extra/` is indexed with no extra step. | fdsdk `files/vm/prepare-image.sh` at `freedesktop-sdk-26.08.2`; `tar -tf` of the kernel package |
| The kernel's update loop is `mise run kernel-update` plus the `track-linux-cachyos` job, which commits only `elements/core/linux-cachyos.bst` | `mise/tasks/kernel-update`; `.github/workflows/track-bst-sources.yml:80-151` |
| homed accounts: supplementary groups live in the user record. `homectl update <user> --member-of=` **replaces** the list. First boot passes `--member-of=wheel`. | `docs/skills/bst.md` § Passwordless sudo for a client that self-elevates (the pangolin group bullet); `files/systemd-firstboot/firstboot-wizard.sh:156-157` |

## Steps

### 0. Spike: can krytis build a loadable module at all? (throwaway branch, no PR)

Answer this before D1 is decided. It costs one element and one boot.

1. Throwaway `core/linux-cachyos-headers.bst`: `kind: manual`, `kind: remote` source for
   `linux-cachyos-headers-7.2.9-2-x86_64_v3.pkg.tar.zst`; extract it and install
   `usr/lib/modules/7.2.9-2-cachyos/build` under a build-only prefix.
2. Throwaway module element: build-depend on that element plus
   `freedesktop-sdk.bst:components/llvm.bst` (clang, lld), `elfutils` and `openssl`. Run
   `make -C <headers>/build M=$PWD/driver LLVM=1 modules` on openrazer `v3.12.4`.
   **Toolchain Gate:** if BuildStream starts compiling LLVM rather than pulling it from the
   cache, stop and ask (AGENTS.md).
3. Things expected to break, in order:
   - the headers' prebuilt host tools (`scripts/basic/fixdep`, `scripts/mod/modpost`,
     `tools/objtool/objtool`) are Arch binaries; they may need a newer glibc or a different
     `libelf` soname than the sandbox has;
   - Kbuild's compiler-version check (built with 23.1.1, building with 22.1.8);
   - an unknown flag from the kernel's `KBUILD_CFLAGS` that clang 22 rejects.
4. Copy the four `.ko` files to the dev box. `sudo insmod razerkraken.ko`; `dmesg` should show
   no `disagrees about version of symbol` and no `Unknown symbol`. Expect only the taint
   message. `modinfo` vermagic must be `7.2.9-2-cachyos SMP preempt mod_unload`. Compare it
   with an in-tree module.

**Exit:** post the result on #1224 and decide D1 with it. The fallbacks, if prebuilt tools
fail: rebuild `scripts/` and `objtool` from the matching kernel source tarball inside the
element. If clang 22 is rejected: wait for an fdsdk LLVM 23 bump. Do not vendor a non-fdsdk
compiler.

### 1. Kernel headers element and update path

- `elements/core/linux-cachyos-headers.bst`, made permanent from step 0. It is **build-only**:
  no stack depends on it, so it never ships.
- `mise run kernel-update` updates both elements from the same `cachyos-v3.db` snapshot. Each
  gets the same version and pkgrel, and each gets its own real-artifact sha256 (keep the
  in-place-rebuild handling at `kernel-update:50-77` for both).
- `track-linux-cachyos` passes both files to `scripts/commit-tracking-update.sh`, and its
  "Check for changes" step diffs both.
- Add a consistency check to the module element's build: the headers'
  `include/config/kernel.release` must equal the module directory name. This catches a
  half-bumped pair at build time instead of at `modprobe`.

### 2. Python dependencies for the daemon

- `elements/deps/python3-setproctitle.bst` (`github:dvarrazzo/py-setproctitle.git`,
  `track: version-*`, C extension).
- `elements/deps/python3-daemonize.bst` (`github:thesharp/daemonize.git`, `track: v*`, pure
  Python). It is unmaintained since 2019, but `run_openrazer_daemon.py:15` imports it
  unconditionally. Packaging it is cheaper than carrying a patch.
- `deps/python3-pyudev.bst`: reuse it if #1220 has landed; otherwise add it as step 1 of
  #1220's plan describes. Also add `freedesktop-sdk.bst:components/python3-dbus.bst`.
- Track matrix rows for both new elements.

### 3. `elements/core/openrazer-driver.bst`

- `git_repo` `github:openrazer/openrazer.git`, `track: v*`, plus a `kind: patch` source for
  openrazer/openrazer#2719 at `dd3f090` (D2), stored under `patches/openrazer/`. Register the
  carry in `docs/design/carried-patches.md`; `mise run patch-inventory-check` fails CI if it is
  missing. Exit condition: openrazer/openrazer#2719 merged and released; drop the patch on the
  next bump after that.
- Build as in step 0. Install the `.ko` files to
  `%{install-root}/usr/lib/modules/<release>/extra/openrazer/`, with `<release>` read from the
  headers. No `depmod` in the element: `prepare-image.sh` indexes every module directory at
  image assembly (see Reference).
- Add it to the stack next to `core/linux-cachyos.bst`.

**Check:** in the loaded image, `modules.dep` lists `extra/openrazer/razerkraken.ko`, and
`modinfo -k 7.2.9-2-cachyos razerkraken` resolves. On a booted VM, `modprobe razerkraken`
succeeds with no device attached.

### 4. `elements/desktop/openrazer-daemon.bst`

- Same source and patch as step 3. Use a `kind: pyproject` build on `daemon/`, not upstream's
  `python3 setup.py install`. Then install the resources, man pages and units with
  `make -C daemon install-resources install-systemd PREFIX=/usr DESTDIR=%{install-root}`,
  and the udev files with `make udev_install UDEV_PREFIX=/usr DESTDIR=%{install-root}`.
- Runtime deps: `components/python3.bst`, `components/pygobject.bst`,
  `components/python3-dbus.bst`, `deps/python3-pyudev.bst`,
  `deps/python3-setproctitle.bst`, `deps/python3-daemonize.bst`, and `core/openrazer-driver.bst`.
- `sysusers.d/openrazer.conf` with `g plugdev - -`, installed to
  `%{indep-libdir}/sysusers.d/`, the way `core/pangolin-cli.bst` creates its group. Without
  it, `GROUP:="plugdev"` silently falls back to root (`docs/skills/desktop.md` § Verify a
  udev rule's `GROUP=` reference).
- `razer_mount` calls `modprobe` and `chgrp`. Confirm both are on the udev `RUN` path in the
  image.

**Check:** `mise run build`. In the image: `getent group plugdev` resolves after
`systemd-sysusers --root`; `/usr/lib/udev/razer_mount` is executable;
`/usr/lib/systemd/user/openrazer-daemon.service` exists.

### 5. Group membership and daemon start

- D3: change `firstboot-wizard.sh`'s `--member-of=wheel` to `--member-of=wheel,plugdev`, and
  update `docs/design/first-boot-setup.md`'s table row in the same commit. **Breakage Gate:**
  verify with `mise boot-test` and with a first boot in `mise run boot-vm`.
- Existing accounts opt in by hand. Document the command in `docs/skills/desktop.md`. For homed
  accounts it is `homectl update <user> --member-of=<existing>,plugdev` (this replaces the
  list; `userdbctl user <user>` shows the current one). For classic `/etc/passwd` accounts it
  is `usermod -aG plugdev <user>`. Either way, log out and back in.
- D4: a krytis rule, `/usr/lib/udev/rules.d/99-krytis-openrazer-user.rules`, ordered after
  `99-razer.rules`. It adds `TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="openrazer-daemon.service"`
  on the devices `99-razer.rules` matches. First verify that the session's user manager
  actually starts a unit from `SYSTEMD_USER_WANTS` on a hidraw/usb device
  (systemd.device(5)); fall back to the preset if not.

**Check (hardware):** after a reboot with the Kraken attached, and with no manual start:

- `systemctl --user is-active openrazer-daemon` → `active`;
- `busctl --user call org.razer /org/razer razer.devices getDevices` lists the device;
- enabling `detluck/razer` shows it in the panel, and Theme Sync changes the headset lighting.

Then remove the device and check that nothing errors in `journalctl --user -u openrazer-daemon`.

### 6. Write back

- `docs/skills/bst.md`: a new "Out-of-tree kernel modules" section covering the headers
  element, compiler pairing, `prepare-image.sh` doing `depmod`, the unsigned/taint status, and
  the kernel-update coupling.
- `docs/skills/desktop.md` § Camera Stack: its v4l2loopback bullet points at #1224 for the
  module-build route. Repoint it at the new `bst.md` section.
- `docs/skills/desktop.md` § noctalia plugins: enabling in skel: the session-bus daemon, the `plugdev`
  requirement, and the start policy.
- Archive this plan to `docs/plans/done/` in the last PR.

## Risks

- **Every kernel bump rebuilds the modules.** If a CachyOS bump breaks openrazer's build (as
  Linux 7.2-rc1 did, fixed in v3.12.4), the `track-linux-cachyos` PR goes red until openrazer
  catches up. That is the intended failure mode: a red tracking PR, not a broken image.
- **Tainted kernel.** Bug reports against the kernel will show `O` and `E` taint flags.
- **Enabling lockdown or `module.sig_enforce` later breaks Razer support.** That would need a
  krytis-owned module signing key enrolled in the machine keyring. krytis boots without shim,
  so there is no MOK. Out of scope here; note it in `docs/design/secure-boot-uki.md` if B
  lands.
