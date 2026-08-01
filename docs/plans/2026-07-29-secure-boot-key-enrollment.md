# Secure Boot Key Enrollment Implementation Plan (#309)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get PK/KEK/db firmware keys enrolled at install time (real hardware) and bakeable into OVMF vars (QEMU testing), so the already-signed UKI + `systemd-boot` (#32/#33, merged in #370) chain-verify against a trusted key set instead of just being "signed with no one to trust them."

**Architecture:** `.auth` EFI signature lists (PK.auth, KEK.auth, db.auth — db bundles krytis's cert + Microsoft's two well-known CAs) are generated **inside the same Containerfile `SEAL_SECURE_BOOT` stage** that already builds the UKI and signs `systemd-boot` (`efitools`, already a runtime dep since #370), and land at `/usr/lib/bootc/install/secureboot-keys/auto/` in `localhost/krytis:sealed`. `bootc install --bootloader systemd` copies them to `ESP/loader/keys/auto/*.auth` — confirmed by reading `bootc`'s source (`crates/lib/src/bootc_composefs/boot.rs`, `crates/lib/src/bootloader.rs`): `BOOTC_AUTOENROLL_PATH = "usr/lib/bootc/install/secureboot-keys"`, and `install_systemd_boot()` copies every `<keyset>/*.auth` under it into `ESP/loader/keys/<keyset>/`. A first-boot oneshot systemd unit sets `secure-boot-enroll manual` in the ESP's `loader.conf` (bootc doesn't touch that setting — confirmed absent from bootc's source). QEMU testing uses `virt-fw-vars` to pre-bake the same keys into an OVMF vars file, since real hardware enrollment (firmware setup mode + boot-menu selection) can't be scripted.

**Tech Stack:** efitools (`cert-to-efi-sig-list`, `sign-efi-sig-list` — already in the image via `elements/stacks/bootc.bst`), bootc v1.16.6, systemd-boot `loader/keys/`, python3-virt-firmware (`virt-fw-vars`, host tool), QEMU/OVMF (host tools).

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only (AGENTS.md)
- All maintenance tasks must be `mise` tasks — no loose shell commands (AGENTS.md)
- `mise lint` must pass before opening a PR (AGENTS.md)
- Agents MUST NOT push directly to `main` — all changes via PR from a feature branch (AGENTS.md)
- Worktree + branch required before touching files (AGENTS.md convention) — `#309` is a child of parent issue `#16`, so per AGENTS.md's "Issue with parent issue" row the path is `<base>/gh16/309-add-secure-boot-key-enrollment` (no cc-type prefix), branch `309-add-secure-boot-key-enrollment`
- Skill file updates land in the **same commit** as the change that produced the learning, not a follow-up (AGENTS.md Self-Improvement Loop) — `docs/skills/secure-boot.md` already exists; append to it per task, don't create a new file
- `files/boot-keys/` is gitignored — private keys never committed. `files/microsoft-uefi-certs/` **is** committed — public CA certs, not secrets
- Sealed images are tagged `localhost/krytis:sealed`, never `:latest` (established in #32/#33 — see `docs/skills/secure-boot.md` § Sealed images push under `:sealed` tags)
- `mise/tasks/seal-uki` already passes six secrets: `db_key`, `db_crt`, `kek_key`, `kek_crt`, `pk_key`, `pk_crt`, sourced from `files/boot-keys/{db.key,db.crt,KEK.key,KEK.crt,PK.key,PK.crt}` — note the casing: `PK`/`KEK` upper, `db` lower (see `docs/skills/secure-boot.md`)
- `bootctl install` (invoked by `bootc install --bootloader systemd`) writes a fresh `loader.conf` to the ESP if none exists — do not ship a static `/boot/loader/loader.conf` in the image, it gets wiped along with the rest of `/boot` (see `docs/skills/secure-boot.md` § `bootc container ukify` needs a separate rootfs)
- Config-only BST elements use inline heredocs in `install-commands` (see `elements/config/oomd.bst`) — do not invent a `files/<name>/` directory for a two-file systemd unit + preset when a heredoc does the job
- This is a **Design Gate item** (AGENTS.md): Task 2 below places `.auth` generation inside the Containerfile rather than the standalone BST element the original issue #309 draft sketched. This mirrors the precedent already set and merged for #32/#33 (Containerfile-based signing, keys only ever touch a `--secret` mount, never a build artifact). Flag this explicitly in the PR description per AGENTS.md's Breakage/Design Gate practice — the same way PR #370 flagged its two-stage Containerfile deviation from issue #32's draft.

## Prerequisites (before starting any task)

- [ ] Read `AGENTS.md`, `docs/SKILL.md`, `docs/skills/bst.md`, `docs/skills/mise.md`, `docs/skills/secure-boot.md`, `docs/design/secure-boot-uki.md`
- [ ] Create a worktree: `git worktree add -b 309-add-secure-boot-key-enrollment .worktrees/gh16/309-add-secure-boot-key-enrollment`
- [ ] `mise trust` in the worktree
- [ ] `mise run pull-keys` (or `mise run generate-keys`) — `files/boot-keys/{PK,KEK,db}.{key,crt}` must exist and validate
- [ ] Host has `qemu-system-x86_64` + `edk2-ovmf` (secboot variant — `OVMF_CODE_4M.secboot.fd`/`OVMF_VARS_4M.secboot.fd` or equivalent) installed
- [ ] Host has `virt-fw-vars` (from `python3-virt-firmware`) installed — `pip install virt-firmware` or the distro package. This is a host tool like `qemu`/`podman`, not `mise`-managed (see `docs/skills/mise.md` § Tool declarations)
- [ ] `localhost/krytis:latest` buildable (`mise build`) and `localhost/krytis:sealed` buildable (`mise run seal-uki`) — confirms #32/#33's signing pipeline still works before adding enrollment on top

---

## Task 1: Commit Microsoft UEFI CA certs (`fetch-microsoft-certs`)

**Files:**
- Create: `mise/tasks/fetch-microsoft-certs`
- Create: `files/microsoft-uefi-certs/microsoft-uefi-ca-2011.der`, `files/microsoft-uefi-certs/microsoft-uefi-ca-2023.der` (committed — public certs)

**Interfaces:**
- Produces: `files/microsoft-uefi-certs/*.der` — consumed by Task 2's Containerfile `.auth` generation step (bundled into `db.esl` before signing)

**Issue:** Part of #309

- [ ] **Step 1: Create the `fetch-microsoft-certs` mise task**

Create `mise/tasks/fetch-microsoft-certs`:

```bash
#!/usr/bin/env bash
#MISE description="Fetch Microsoft UEFI CA certificates into files/microsoft-uefi-certs/ (public, committed)"

set -euo pipefail

CERTS_DIR="files/microsoft-uefi-certs"
mkdir -p "$CERTS_DIR"

# Microsoft Corporation UEFI CA 2011 (third-party binaries: Option ROMs, shim, etc.)
curl -sSfL "https://go.microsoft.com/fwlink/p/?linkid=321506" -o "$CERTS_DIR/microsoft-uefi-ca-2011.der"
# Microsoft Corporation UEFI CA 2023 (successor, some newer firmware requires it)
curl -sSfL "https://go.microsoft.com/fwlink/p/?linkid=2093978" -o "$CERTS_DIR/microsoft-uefi-ca-2023.der"

for cert in "$CERTS_DIR"/*.der; do
    openssl x509 -inform DER -in "$cert" -noout || { echo "ERROR: $cert is not a valid DER cert" >&2; exit 1; }
done

echo "==> Microsoft UEFI CA certs in $CERTS_DIR/:"
for cert in "$CERTS_DIR"/*.der; do
    echo "    $(basename "$cert"): $(openssl x509 -inform DER -in "$cert" -noout -subject -sha256 -fingerprint | tr '\n' ' ')"
done
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x mise/tasks/fetch-microsoft-certs
mise run fetch-microsoft-certs
```
Expected: `files/microsoft-uefi-certs/microsoft-uefi-ca-2011.der` and `.../microsoft-uefi-ca-2023.der` created, both print a valid `subject=` and SHA256 fingerprint line.

If the `go.microsoft.com` fwlinks are unreachable: extract the certs from an `sbctl`-managed system (`/usr/share/secureboot/keys/db/` on a machine with `sbctl` and `--microsoft` enrollment) or from Microsoft's published UEFI CA cert pages, and note the substitute source in the commit message.

- [ ] **Step 3: Verify the task is listed**

Run: `mise tasks`
Expected: `fetch-microsoft-certs` appears with its description.

- [ ] **Step 4: Commit**

```bash
git add mise/tasks/fetch-microsoft-certs files/microsoft-uefi-certs/
git commit -m "feat(secure-boot): add fetch-microsoft-certs task

Fetches Microsoft's two well-known UEFI CA certs (2011 + 2023) into
files/microsoft-uefi-certs/ — committed, public, not secrets. Bundled
into db.auth during seal-uki (#309) so third-party EFI binaries
(Option ROMs, GPU firmware, Windows dual-boot) keep working after
krytis's enrollment replaces the firmware's default db.

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 2: Generate `.auth` files in the Containerfile seal step

**Files:**
- Modify: `Containerfile`
- Modify: `docs/skills/secure-boot.md` (append learnings — same commit)

**Interfaces:**
- Consumes: `files/boot-keys/{PK,KEK,db}.{key,crt}` (already mounted as `pk_key`/`pk_crt`/`kek_key`/`kek_crt`/`db_key`/`db_crt` secrets by `mise/tasks/seal-uki`), `files/microsoft-uefi-certs/*.der` (Task 1, via build context)
- Produces: `/usr/lib/bootc/install/secureboot-keys/auto/{PK,KEK,db}.auth` inside `localhost/krytis:sealed`

**Issue:** #309
**Blocked by:** Task 1 (needs `files/microsoft-uefi-certs/`)

- [ ] **Step 1: Re-read the current `Containerfile`**

The current sealed stage (verify this still matches before editing — if it's drifted, adjust the edit accordingly):

```dockerfile
FROM localhost/krytis-input:latest AS base

RUN bootc container lint

# Uncomment to set a temporary root password for VM login during debugging.
# Remove before shipping — not for production use.
# RUN echo 'root:krytis' | chpasswd

# Conditional secure boot sealing — gated by build arg.
# mise build (unsigned) skips this; mise run seal-uki enables it.
#
# A second stage is required: `bootc container ukify` refuses to compute the
# composefs digest against the currently-building (active/mutable) rootfs and
# needs a separate, already-completed image bind-mounted as --rootfs. See
# docs/skills/secure-boot.md § bootc container ukify needs a separate rootfs.
FROM base AS sealed
ARG SEAL_SECURE_BOOT=false

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    --mount=type=bind,from=base,target=/target \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        mkdir -p /var/tmp /boot/EFI/Linux && \
        bootc container ukify --rootfs /target -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
    ; fi
```

- [ ] **Step 2: Add the `.auth` generation to the sealed stage**

Modify `Containerfile` — add a `COPY` of the Microsoft certs before the `RUN`, and extend the `RUN`'s `if` body to also build and sign the three `.auth` files:

```dockerfile
FROM base AS sealed
ARG SEAL_SECURE_BOOT=false

# Public Microsoft UEFI CA certs (files/microsoft-uefi-certs/, committed) —
# bundled into db.auth below so third-party EFI binaries keep working.
COPY files/microsoft-uefi-certs/ /tmp/microsoft-uefi-certs/

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    --mount=type=bind,from=base,target=/target \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        set -ex && \
        mkdir -p /var/tmp /boot/EFI/Linux /usr/lib/bootc/install/secureboot-keys/auto && \
        bootc container ukify --rootfs /target -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        GUID=$(cat /proc/sys/kernel/random/uuid) && \
        openssl x509 -in /run/secrets/pk_crt -outform DER -out /tmp/PK.der && \
        openssl x509 -in /run/secrets/kek_crt -outform DER -out /tmp/KEK.der && \
        openssl x509 -in /run/secrets/db_crt -outform DER -out /tmp/db.der && \
        cert-to-efi-sig-list /tmp/PK.der /tmp/PK.esl && \
        cert-to-efi-sig-list /tmp/KEK.der /tmp/KEK.esl && \
        cert-to-efi-sig-list /tmp/db.der /tmp/db.esl && \
        for ms in /tmp/microsoft-uefi-certs/*.der; do \
            cert-to-efi-sig-list "$ms" /tmp/ms-entry.esl && \
            cat /tmp/ms-entry.esl >> /tmp/db.esl && \
            rm /tmp/ms-entry.esl ; \
        done && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/pk_key -c /run/secrets/pk_crt \
            PK /tmp/PK.esl /usr/lib/bootc/install/secureboot-keys/auto/PK.auth && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/pk_key -c /run/secrets/pk_crt \
            KEK /tmp/KEK.esl /usr/lib/bootc/install/secureboot-keys/auto/KEK.auth && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/kek_key -c /run/secrets/kek_crt \
            db /tmp/db.esl /usr/lib/bootc/install/secureboot-keys/auto/db.auth && \
        rm -f /tmp/PK.der /tmp/KEK.der /tmp/db.der /tmp/PK.esl /tmp/KEK.esl /tmp/db.esl \
    ; fi
```

Notes embedded for the implementer:
- `PK.auth` and `KEK.auth` are both signed with the **PK** key (self-signed initial enrollment — PK asserts the KEK list, and PK asserts itself). `db.auth` is signed with the **KEK** key (KEK asserts the db list). This is the standard UEFI PK→KEK→db signing chain, matching `docs/design/secure-boot-uki.md`.
- `cert-to-efi-sig-list` takes **no type argument** — `<cert.der> <output.esl>` only (see `docs/skills/secure-boot.md`).
- `sign-efi-sig-list` takes the variable name (`PK`/`KEK`/`db`) as its first positional arg, `-k`/`-c` for the signer's key/cert, `-g` for the (optional) signature owner GUID.
- The subdirectory name `auto` is significant — it is the specific key-set name systemd-boot's `secure-boot-enroll=if-safe`/`manual` looks for (see systemd-boot.xml "loader/keys"), and matches the layout `bootc`'s `get_secureboot_keys()` expects: one directory per key set under `usr/lib/bootc/install/secureboot-keys/`, each holding arbitrarily-named `*.auth` files.

- [ ] **Step 3: Verify unsigned build is unaffected**

```bash
mise build
```
Expected: `localhost/krytis:latest` builds — `SEAL_SECURE_BOOT` defaults to `false`, the whole `if` body (including `.auth` generation) is skipped, `COPY` still runs (cheap, just stages files into the `sealed` stage's build context) but has no effect since that stage's `RUN` short-circuits.

- [ ] **Step 4: Run `seal-uki` and verify `.auth` files exist**

```bash
mise run seal-uki
podman run --rm localhost/krytis:sealed ls -la /usr/lib/bootc/install/secureboot-keys/auto/
```
Expected: `PK.auth`, `KEK.auth`, `db.auth`, each non-zero size.

- [ ] **Step 5: Verify `db.auth` includes both krytis's cert and Microsoft's CAs**

```bash
podman run --rm localhost/krytis:sealed cat /usr/lib/bootc/install/secureboot-keys/auto/db.auth > /tmp/db.auth
# .auth = EFI_VARIABLE_AUTHENTICATION_2 header + PKCS7 signature + the ESL payload.
# sig-list-to-certs (efitools) strips the auth header/signature and dumps the ESL's certs.
podman run --rm -v /tmp/db.auth:/db.auth:z localhost/krytis:sealed sh -c \
    'sig-list-to-certs /db.auth /tmp/db-certs && ls /tmp/db-certs*'
for f in /tmp/db-certs*.esl 2>/dev/null || true; do :; done
```
Expected: three certs extracted (krytis db + 2 Microsoft CAs). If `sig-list-to-certs` isn't available or output naming differs, instead diff subject lines: `openssl x509 -in files/boot-keys/db.crt -noout -subject` should appear once, and both Microsoft cert subjects should appear once each, somewhere in the extracted set.

- [ ] **Step 6: Verify keys never entered the image layer**

```bash
podman run --rm localhost/krytis:sealed find / -xdev -iname "*.key" 2>/dev/null
```
Expected: empty output — private keys only ever existed via `--secret` mounts during the `RUN` step (same guarantee already verified for #32/#33's UKI/systemd-boot signing).

- [ ] **Step 7: Append learnings to `docs/skills/secure-boot.md` and commit**

Append a new section to `docs/skills/secure-boot.md`:

```markdown
## `.auth` files land at `secureboot-keys/<keyset>/*.auth`, not a flat directory

Confirmed by reading bootc v1.16.6 source (`crates/lib/src/bootc_composefs/boot.rs`
`get_secureboot_keys()`, `crates/lib/src/bootloader.rs` `install_systemd_boot()`):
`BOOTC_AUTOENROLL_PATH = "usr/lib/bootc/install/secureboot-keys"`. Each entry directly
under that path **must be a directory** (bootc `bail!`s otherwise) — the directory name
is the systemd-boot key-set name (we use `auto`, the name systemd-boot's
`secure-boot-enroll=if-safe`/`manual` specifically recognizes). Inside it, any
arbitrarily-named `*.auth` file is picked up and copied to `ESP/loader/keys/<keyset>/`.
So the layout is `secureboot-keys/auto/{PK,KEK,db}.auth`, not
`secureboot-keys/{PK,KEK,db}.auth` (no `auto/` level) and not
`secureboot-keys/{PK,KEK,db}/{PK,KEK,db}.auth` (one dir per file).

**bootc does not touch `loader.conf`.** Grepped the full source tree for
`secure-boot-enroll`/`loader.conf` — zero matches. `bootctl install` (which bootc's
`install_systemd_boot()` shells out to) writes a fresh `loader.conf` with default
settings if none exists on the ESP, but bootc never sets `secure-boot-enroll` itself.
It defaults to `if-safe` (auto-enrolls only inside a firmware-recognized VM). Real
hardware needs an explicit `secure-boot-enroll manual` (or `force`) line — see the
first-boot oneshot service pattern below (#309).

## `.auth` generation lives in the Containerfile seal step, not a BST element

Deviates from #309's original draft ("place at .../secureboot-keys/auto/ via a BST
element"), for consistency with #32/#33's precedent: `.auth` files are cryptographic
artifacts derived from the private PK/KEK/db keys, so they get the same treatment as
the UKI and signed `systemd-boot` — generated inside the `SEAL_SECURE_BOOT` Containerfile
stage from `--secret` mounts, never committed to git, never present in `localhost/krytis:latest`
(only `:sealed`). A BST element would either need the `.auth` files committed (coupling
key rotation to a git commit, and requiring the *signed artifacts* — not just PEM keys —
to exist on disk before every `mise build`) or conditional BST logic to skip when keys
are absent, both worse than the Containerfile's existing `SEAL_SECURE_BOOT` gate.
```

Then commit:

```bash
git add Containerfile docs/skills/secure-boot.md
git commit -m "feat(secure-boot): generate .auth key enrollment files in seal-uki

Extends the existing SEAL_SECURE_BOOT Containerfile stage to also build
PK.auth/KEK.auth/db.auth (efitools cert-to-efi-sig-list + sign-efi-sig-list)
at /usr/lib/bootc/install/secureboot-keys/auto/. db.auth bundles krytis's
own cert plus Microsoft's 2011/2023 UEFI CAs (#309's Microsoft cert
retention decision). bootc install copies these to ESP/loader/keys/auto/
at install time; systemd-boot enrolls them per loader.conf's
secure-boot-enroll setting.

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 3: First-boot `secure-boot-enroll manual` oneshot service

**Files:**
- Create: `elements/config/secureboot-loader-conf.bst`
- Modify: `elements/stacks/bootc.bst`
- Modify: `docs/skills/secure-boot.md`

**Interfaces:**
- Produces: `/usr/lib/systemd/system/secure-boot-enroll.service` + `/usr/lib/systemd/system-preset/71-krytis-secure-boot-enroll.preset` in the image; on first real boot, appends `secure-boot-enroll manual` to the ESP's `loader.conf`

**Issue:** #309

- [ ] **Step 1: Create `secureboot-loader-conf.bst`**

Matches the established config-only-element pattern (see `elements/config/oomd.bst`) — inline heredocs, no separate `files/` directory needed for two short text files:

```yaml
# On real hardware systemd-boot does NOT auto-enroll loader/keys/auto by default
# (secure-boot-enroll defaults to if-safe: VMs only). This first-boot oneshot sets
# secure-boot-enroll manual so the user gets a boot-menu prompt to select the key
# set instead of a silent no-op. bootc never writes this setting itself — confirmed
# absent from bootc's source, see docs/skills/secure-boot.md. Closes #309.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system/secure-boot-enroll.service" <<'EOF'
    [Unit]
    Description=Set secure-boot-enroll=manual in the ESP's loader.conf
    ConditionFirstBoot=yes
    ConditionPathExists=/boot/loader/loader.conf

    [Service]
    Type=oneshot
    ExecStart=/usr/bin/sh -c 'grep -q "^secure-boot-enroll" /boot/loader/loader.conf || echo "secure-boot-enroll manual" >> /boot/loader/loader.conf'
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-secure-boot-enroll.preset" <<'EOF'
    enable secure-boot-enroll.service
    EOF

  - "%{install-extra}"
```

- [ ] **Step 2: Add to `stacks/bootc.bst`**

Modify `elements/stacks/bootc.bst` — add `config/secureboot-loader-conf.bst` to `depends:`:

```yaml
kind: stack

depends:
  - freedesktop-sdk.bst:vm/config/useradd-ostree.bst
  - freedesktop-sdk.bst:components/podman.bst
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/skopeo.bst
  - freedesktop-sdk.bst:components/systemd-ukify.bst
  - freedesktop-sdk.bst:components/sbsigntools-maybe.bst
  - freedesktop-sdk.bst:components/efitools.bst
  - core/bootc.bst
  - core/efibootmgr.bst
  - config/bootc.bst
  - config/secureboot-loader-conf.bst
```

- [ ] **Step 3: Validate the element graph**

```bash
mise validate
```
Expected: passes.

- [ ] **Step 4: Build and verify the unit + preset are present**

```bash
mise build
podman run --rm localhost/krytis:latest cat /usr/lib/systemd/system/secure-boot-enroll.service
podman run --rm localhost/krytis:latest cat /usr/lib/systemd/system-preset/71-krytis-secure-boot-enroll.preset
```
Expected: both files print with the content from Step 1.

- [ ] **Step 5: Verify the preset actually enables the service**

```bash
podman run --rm localhost/krytis:latest systemctl --root=/ preset-all --dry-run 2>&1 | grep secure-boot-enroll || \
podman run --rm localhost/krytis:latest sh -c 'systemctl is-enabled secure-boot-enroll.service'
```
Expected: `enabled` (or the dry-run preset line shows `enable secure-boot-enroll.service`).

- [ ] **Step 6: Append to `docs/skills/secure-boot.md` and commit**

```markdown
## First-boot loader.conf edits need `ConditionFirstBoot=yes` + `ConditionPathExists`

`bootctl install` (run by `bootc install --bootloader systemd` at install time, before
the system ever boots) writes the ESP's `loader.conf` before `ConditionFirstBoot=yes`
units run on the first *real* boot — so by the time `secure-boot-enroll.service` fires,
`/boot/loader/loader.conf` already exists and it's safe to `grep`+`>>` into it. Without
`ConditionPathExists=/boot/loader/loader.conf` the unit would still succeed (oneshot,
`sh -c` with the file missing just no-ops the `grep`/echo into a non-existent path and
errors) — the condition makes the skip explicit and inspectable via
`systemctl status secure-boot-enroll.service` instead of a cryptic ExecStart failure.
```

```bash
git add elements/config/secureboot-loader-conf.bst elements/stacks/bootc.bst docs/skills/secure-boot.md
git commit -m "feat(secure-boot): set secure-boot-enroll manual on first boot

systemd-boot's default secure-boot-enroll=if-safe only auto-enrolls
loader/keys/auto inside a firmware-recognized VM. Real hardware needs
an explicit setting or enrollment is a silent no-op. Ships a
ConditionFirstBoot=yes oneshot that appends secure-boot-enroll manual
to the ESP's loader.conf (written earlier by bootctl install), giving
the user an explicit boot-menu prompt to select the key set.

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 4: `--image` flag on `generate-disk`

**Files:**
- Modify: `mise/tasks/generate-disk`

**Interfaces:**
- Produces: `generate-disk --image <tag>` installs from an arbitrary local image tag instead of always `localhost/krytis:latest` — needed so Task 5 can install from `localhost/krytis:sealed` without clobbering `:latest`

**Issue:** Part of #309
**Blocked by:** Task 2 (so `localhost/krytis:sealed` exists to test against)

- [ ] **Step 1: Add the `--image` flag and thread it through**

Modify `mise/tasks/generate-disk` (current content shown for reference — replace the marked lines):

```bash
#!/usr/bin/env bash
#MISE description="Install krytis:latest to a bootable raw disk image via bootc"
#USAGE flag "--filesystem <fs>" default="btrfs" help="Root filesystem type (btrfs or ext4)"
#USAGE flag "--disk <path>" default="bootable.raw" help="Output disk image path"
#USAGE flag "--size <size>" default="30G" help="Sparse disk image size passed to fallocate"
#USAGE flag "--image <tag>" default="localhost/krytis:latest" help="Local image tag to install"

set -euo pipefail

FS="${usage_filesystem:-btrfs}"
DISK="${usage_disk:-bootable.raw}"
SIZE="${usage_size:-30G}"
IMAGE="${usage_image:-localhost/krytis:latest}"

if [ ! -e "${DISK}" ]; then
    echo "==> Creating ${SIZE} sparse disk image at ${DISK}..."
    fallocate -l "${SIZE}" "${DISK}"
fi

# rootless and rootful podman have separate image stores; copy so bootc can find itself
ROOTLESS_ID=$(podman image inspect --format '{{.Id}}' "${IMAGE}" 2>/dev/null || true)
ROOT_ID=$(sudo podman image inspect --format '{{.Id}}' "${IMAGE}" 2>/dev/null || true)
if [ -n "${ROOTLESS_ID}" ] && [ "${ROOTLESS_ID}" = "${ROOT_ID}" ]; then
    echo "==> Root podman store already has the current image, skipping copy."
else
    echo "==> Copying ${IMAGE} to root podman store..."
    podman save --format oci-archive "${IMAGE}" | sudo podman load
fi

# systemd.firstboot=no is intentionally absent: firstboot runs on every fresh disk install.
# Re-add once the installer handles first-run setup and the greeter becomes the entry point.
echo "==> Installing ${IMAGE} → ${DISK} (filesystem: ${FS})..."
sudo podman run \
    --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v "$(pwd):/data" \
    --security-opt label=type:unconfined_t \
    "${IMAGE}" \
    bootc install to-disk \
        --composefs-backend \
        --via-loopback "/data/${DISK}" \
        --filesystem "${FS}" \
        --wipe \
        --bootloader systemd \
        --karg console=ttyS0 \
        --karg console=tty1

echo "==> Done: ${DISK}"
```

- [ ] **Step 2: Verify the default (no `--image`) behavior is unchanged**

```bash
rm -f /tmp/test-default.raw
mise run generate-disk --disk /tmp/test-default.raw --size 10G
```
Expected: installs from `localhost/krytis:latest` exactly as before.

- [ ] **Step 3: Verify `--image` installs from the sealed tag**

```bash
rm -f /tmp/test-sealed.raw
mise run generate-disk --image localhost/krytis:sealed --disk /tmp/test-sealed.raw --size 10G
```
Expected: log line reads `Installing localhost/krytis:sealed → /tmp/test-sealed.raw`, install succeeds.

- [ ] **Step 4: Commit**

```bash
git add mise/tasks/generate-disk
git commit -m "feat(mise): add --image flag to generate-disk

Allows installing from an arbitrary local tag (e.g. localhost/krytis:sealed)
without clobbering :latest via a podman tag hack.

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 5: OVMF secure boot testing — `generate-ovmf-vars` + `boot-vm --secure`

**Files:**
- Create: `mise/tasks/generate-ovmf-vars`
- Modify: `mise/tasks/boot-vm`
- Modify: `docs/skills/secure-boot.md`

**Interfaces:**
- Consumes: `files/boot-keys/{PK,KEK,db}.crt` (PEM certs — `virt-fw-vars` accepts PEM directly)
- Produces: `.ovmf-vars-secure.fd` (gitignored — mirrors `.ovmf-vars.fd` which is already gitignored)

**Issue:** #309 (QEMU testing path)
**Blocked by:** Task 4 (needs `--image` for the sealed disk)

- [ ] **Step 1: Add `.ovmf-vars-secure.fd` to `.gitignore`**

Check current `.gitignore` for the existing `.ovmf-vars.fd` entry and add the secure variant next to it:

```bash
grep -n "ovmf-vars" .gitignore
```

Add `.ovmf-vars-secure.fd` immediately after the existing `.ovmf-vars.fd` line (exact line number depends on current file state — re-read `.gitignore` before editing).

- [ ] **Step 2: Create `generate-ovmf-vars`**

```bash
#!/usr/bin/env bash
#MISE description="Bake PK/KEK/db keys into an OVMF vars file for QEMU secure boot testing"

set -euo pipefail

KEYS_DIR="files/boot-keys"
GUID="${GUID:-$(cat /proc/sys/kernel/random/uuid)}"

if ! command -v virt-fw-vars &>/dev/null; then
    echo "ERROR: virt-fw-vars not found. Install python3-virt-firmware (pip install virt-firmware)." >&2
    exit 1
fi

for f in PK KEK db; do
    [ -f "${KEYS_DIR}/${f}.crt" ] || { echo "ERROR: ${KEYS_DIR}/${f}.crt missing — run 'mise run pull-keys' first." >&2; exit 1; }
done

OVMF_VARS_SRC=""
for candidate in \
        /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.fd \
        /usr/share/OVMF/OVMF_VARS_4M.secboot.qcow2 \
        /usr/share/edk2/x64/OVMF_VARS.4m.secboot.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd; do
    [ -f "${candidate}" ] && OVMF_VARS_SRC="${candidate}" && break
done
if [ -z "${OVMF_VARS_SRC}" ]; then
    echo "ERROR: OVMF secure boot vars template not found. Install edk2-ovmf's secboot variant." >&2
    exit 1
fi

echo "==> Baking keys into OVMF vars (source: ${OVMF_VARS_SRC}, GUID: ${GUID})..."
virt-fw-vars \
    --input "${OVMF_VARS_SRC}" \
    --secure-boot \
    --set-pk  "${GUID}" "${KEYS_DIR}/PK.crt" \
    --add-kek "${GUID}" "${KEYS_DIR}/KEK.crt" \
    --add-db  "${GUID}" "${KEYS_DIR}/db.crt" \
    --output ".ovmf-vars-secure.fd"

echo "==> OVMF vars: .ovmf-vars-secure.fd"
```

- [ ] **Step 3: Make it executable, run it**

```bash
chmod +x mise/tasks/generate-ovmf-vars
mise run generate-ovmf-vars
```
Expected: `.ovmf-vars-secure.fd` created. If `virt-fw-vars --input` requires qcow2→raw conversion first (some distro packages only ship the qcow2 template) — check `virt-fw-vars --help` for a `--input-format`/auto-detect flag; if it errors on the qcow2 file directly, convert first: `qemu-img convert -f qcow2 -O raw "$OVMF_VARS_SRC" /tmp/ovmf-vars-src.fd` and pass that as `--input`.

- [ ] **Step 4: Add `--secure` flag to `boot-vm`**

Modify `mise/tasks/boot-vm` — add the flag declaration and branch the native-qemu path:

```bash
#!/usr/bin/env bash
#MISE description="Boot bootable.raw in QEMU (native KVM+UEFI) or qemux/qemu-docker fallback"
#USAGE flag "--disk <path>" default="bootable.raw" help="Disk image to boot"
#USAGE flag "--secure" help="Boot with OVMF secure boot enabled (requires 'mise run generate-ovmf-vars' first)"

set -euo pipefail

DISK="${usage_disk:-bootable.raw}"
SECURE="${usage_secure:-}"

if [ ! -e "${DISK}" ]; then
    echo "ERROR: ${DISK} not found — run 'mise run generate-disk' first." >&2
    exit 1
fi

DISK=$(realpath "${DISK}")

if command -v qemu-system-x86_64 &>/dev/null; then
    echo "==> Using native qemu-system-x86_64..."

    if [ "${SECURE}" = "true" ]; then
        OVMF_CODE=""
        for candidate in \
                /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd \
                /usr/share/OVMF/OVMF_CODE_4M.secboot.qcow2 \
                /usr/share/edk2/x64/OVMF_CODE.4m.secboot.fd \
                /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
            [ -f "${candidate}" ] && OVMF_CODE="${candidate}" && break
        done
        if [ -z "${OVMF_CODE}" ]; then
            echo "ERROR: OVMF secure boot firmware not found. Install edk2-ovmf's secboot variant." >&2
            exit 1
        fi
        OVMF_VARS=".ovmf-vars-secure.fd"
        if [ ! -e "${OVMF_VARS}" ]; then
            echo "ERROR: ${OVMF_VARS} not found — run 'mise run generate-ovmf-vars' first." >&2
            exit 1
        fi
        MACHINE_ARGS="q35,smm=on"
        FLASH_SECURE_ARGS=(-global driver=cfi.pflash01,property=secure,value=on)
    else
        OVMF_CODE=""
        for candidate in \
                /usr/share/edk2/ovmf/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd \
                /usr/share/edk2/x64/OVMF_CODE.4m.fd \
                /usr/share/qemu/OVMF_CODE.fd; do
            [ -f "${candidate}" ] && OVMF_CODE="${candidate}" && break
        done
        if [ -z "${OVMF_CODE}" ]; then
            echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Fedora) or ovmf (Debian/Ubuntu)." >&2
            exit 1
        fi

        OVMF_VARS=".ovmf-vars.fd"
        if [ ! -e "${OVMF_VARS}" ]; then
            OVMF_VARS_SRC=""
            for candidate in \
                    /usr/share/edk2/ovmf/OVMF_VARS.fd \
                    /usr/share/OVMF/OVMF_VARS.fd \
                    /usr/share/OVMF/OVMF_VARS_4M.fd \
                    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
                    /usr/share/qemu/OVMF_VARS.fd; do
                [ -f "${candidate}" ] && OVMF_VARS_SRC="${candidate}" && break
            done
            if [ -z "${OVMF_VARS_SRC}" ]; then
                echo "ERROR: OVMF_VARS not found alongside OVMF_CODE." >&2
                exit 1
            fi
            cp "${OVMF_VARS_SRC}" "${OVMF_VARS}"
        fi
        MACHINE_ARGS=""
        FLASH_SECURE_ARGS=()
    fi

    echo "==> Booting ${DISK}"
    echo "    RAM: ${VM_RAM}M  CPUs: ${VM_CPUS}  Firmware: ${OVMF_CODE}  Secure boot: ${SECURE:-false}"
    echo "    SSH forward: localhost:2222 → guest:22"
    echo "    Serial console on stdio (ttyS0) — Ctrl-A x to quit QEMU"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -m "${VM_RAM}" \
        -cpu host \
        -smp "${VM_CPUS}" \
        ${MACHINE_ARGS:+-machine "${MACHINE_ARGS}"} \
        "${FLASH_SECURE_ARGS[@]}" \
        -drive "file=${DISK},format=raw,if=virtio" \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
        -device virtio-vga \
        -display gtk \
        -device virtio-keyboard \
        -device virtio-mouse \
        -device virtio-net-pci,netdev=net0 \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22" \
        -chardev stdio,id=char0,mux=on,signal=off \
        -serial chardev:char0 \
        -serial chardev:char0 \
        -mon chardev=char0

else
    if [ "${SECURE}" = "true" ]; then
        echo "ERROR: --secure requires native qemu-system-x86_64 (q35+SMM) — the qemux/qemu-docker fallback doesn't support it." >&2
        exit 1
    fi
    echo "==> qemu-system-x86_64 not found, falling back to ghcr.io/qemus/qemu..."

    PORT=8006
    while ss -tunalp 2>/dev/null | grep -q ":${PORT}"; do
        PORT=$(( PORT + 1 ))
    done
    echo "==> Web/VNC at http://localhost:${PORT}"
    xdg-open "http://localhost:${PORT}" &>/dev/null || true

    podman run \
        --rm --privileged \
        --device /dev/kvm \
        --pull=always \
        --publish "127.0.0.1:${PORT}:8006" \
        --publish "127.0.0.1:2222:22" \
        -e "USER_PORTS=22" \
        -e "NETWORK=user" \
        -e "CPU_CORES=${VM_CPUS}" \
        -e "RAM_SIZE=${VM_RAM}M" \
        -e "TPM=y" \
        -e "BOOT_MODE=uefi" \
        -e "ARGUMENTS=-snapshot" \
        -v "${DISK}:/boot.img" \
        ghcr.io/qemus/qemu:latest
fi
```

- [ ] **Step 5: Boot without `--secure` — confirm nothing regressed**

```bash
mise run boot-vm --disk /tmp/test-default.raw
```
Expected: boots exactly as before (Task 4's Step 2 disk). Ctrl-A x to quit once it reaches a prompt.

- [ ] **Step 6: Boot the sealed disk with `--secure`**

```bash
mise run boot-vm --disk /tmp/test-sealed.raw --secure
```
Expected: VM boots to a login prompt (or SSH-reachable state).

- [ ] **Step 7: Verify secure boot is active in the guest**

```bash
ssh -p 2222 root@localhost bootctl status
```
Expected: output contains `Secure Boot: enabled (user)`.

- [ ] **Step 8: Negative test — unsigned image rejected under secure boot enforcement**

```bash
rm -f /tmp/test-unsigned-secure.raw
mise run generate-disk --image localhost/krytis:latest --disk /tmp/test-unsigned-secure.raw --size 10G
mise run boot-vm --disk /tmp/test-unsigned-secure.raw --secure
```
Expected: **boot fails** — firmware rejects the unsigned UKI/`systemd-boot`, VM drops to the UEFI shell/firmware setup screen or shows a verification failure, does **not** reach the OS. This is the proof that `--secure` is actually enforcing (not just present-but-permissive).

If the unsigned image boots anyway: `-machine q35,smm=on` and/or `-global driver=cfi.pflash01,property=secure,value=on` aren't taking effect, or the OVMF binaries picked up aren't the secboot variant — verify `qemu-system-x86_64 -machine help | grep q35` and confirm the resolved `OVMF_CODE`/`OVMF_VARS` paths actually contain `secboot` in their names.

- [ ] **Step 9: Append to `docs/skills/secure-boot.md` and commit**

```markdown
## QEMU secure boot enforcement needs q35+SMM+secboot OVMF, not just a vars file

Baking keys into an OVMF vars file (`virt-fw-vars --secure-boot`) is necessary but not
sufficient. Without `-machine q35,smm=on` and `-global driver=cfi.pflash01,property=secure,value=on`
on the pflash device, plus the `secboot`-suffixed `OVMF_CODE` variant (not the plain one),
QEMU boots an unsigned image anyway even with `--secure-boot` vars — the negative test
(unsigned image + `--secure`) is what actually proves enforcement, not just "the VM has
keys enrolled and happened to boot a signed image."
```

```bash
git add mise/tasks/generate-ovmf-vars mise/tasks/boot-vm .gitignore docs/skills/secure-boot.md
git commit -m "feat(secure-boot): add OVMF secure boot testing for QEMU

generate-ovmf-vars bakes PK/KEK/db into an OVMF vars file via
virt-fw-vars. boot-vm --secure uses q35+smm+secboot OVMF with secure
pflash for real secure boot enforcement, verified by a negative test
(unsigned image is rejected).

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 6: `mise boot-test` — automated boot pass/fail

**Files:**
- Create: `mise/tasks/boot-test`
- Modify: `docs/skills/desktop.md` (remove the "does not exist" gap note — this task closes it)
- Modify: `docs/plans/2026-07-05-chunkah-pipeline.md` (the `project_boot_test_gap` reference is now stale — leave a note only if that file still has open checkboxes referencing it; otherwise skip)

**Interfaces:**
- Produces: `mise boot-test [--image <tag>] [--secure] [--filesystem <fs>]` — headless boot + SSH health check + clean shutdown, non-zero exit on any failure

**Issue:** #309 explicitly lists `mise boot-test passes with secure boot enforcement` as an acceptance criterion. This task also closes the documented cross-repo gap (AGENTS.md references it; `docs/skills/desktop.md` and `docs/plans/2026-07-05-chunkah-pipeline.md` both flag it as "aspirational, not real").
**Blocked by:** Task 5 (needs `boot-vm --secure` and `generate-disk --image`)

- [ ] **Step 1: Create `mise/tasks/boot-test`**

Headless (no GTK window), ephemeral disk in `/tmp`, bounded wait for SSH, a fixed assertion set, explicit shutdown via QEMU monitor, clean non-zero exit on any failure:

```bash
#!/usr/bin/env bash
#MISE description="Automated boot pass/fail: install, boot headless, assert health, shut down"
#USAGE flag "--image <tag>" default="localhost/krytis:latest" help="Local image tag to install and boot"
#USAGE flag "--secure" help="Boot with OVMF secure boot enabled (requires 'mise run generate-ovmf-vars' first)"
#USAGE flag "--filesystem <fs>" default="btrfs" help="Root filesystem type (btrfs or ext4)"
#USAGE flag "--expect-fail" help="Invert the result: a successful boot is the failure (secure boot negative test)"

set -euo pipefail

IMAGE="${usage_image:-localhost/krytis:latest}"
SECURE="${usage_secure:-}"
FS="${usage_filesystem:-btrfs}"
EXPECT_FAIL="${usage_expect_fail:-}"

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: boot-test requires native qemu-system-x86_64 (headless, monitor-controlled) — the qemux/qemu-docker fallback isn't supported." >&2
    exit 1
fi

WORKDIR=$(mktemp -d /tmp/krytis-boot-test.XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

DISK="${WORKDIR}/test.raw"
MONITOR_SOCK="${WORKDIR}/monitor.sock"
SSH_PORT=2299
while ss -tunalp 2>/dev/null | grep -q ":${SSH_PORT}"; do SSH_PORT=$((SSH_PORT + 1)); done

echo "==> [1/5] Installing ${IMAGE} → ${DISK} (filesystem: ${FS})..."
./mise/tasks/generate-disk --image "${IMAGE}" --disk "${DISK}" --size 15G

OVMF_CODE="" ; OVMF_VARS_SRC=""
if [ "${SECURE}" = "true" ]; then
    for c in /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE_4M.secboot.qcow2 \
             /usr/share/edk2/x64/OVMF_CODE.4m.secboot.fd /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
        [ -f "$c" ] && OVMF_CODE="$c" && break
    done
    [ -f ".ovmf-vars-secure.fd" ] || { echo "ERROR: .ovmf-vars-secure.fd missing — run 'mise run generate-ovmf-vars' first." >&2; exit 1; }
    cp ".ovmf-vars-secure.fd" "${WORKDIR}/vars.fd"
    MACHINE_ARGS="q35,smm=on"
    FLASH_SECURE_ARGS=(-global driver=cfi.pflash01,property=secure,value=on)
else
    for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
             /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/qemu/OVMF_CODE.fd; do
        [ -f "$c" ] && OVMF_CODE="$c" && break
    done
    for c in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
             /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/qemu/OVMF_VARS.fd; do
        [ -f "$c" ] && OVMF_VARS_SRC="$c" && break
    done
    cp "${OVMF_VARS_SRC}" "${WORKDIR}/vars.fd"
    MACHINE_ARGS=""
    FLASH_SECURE_ARGS=()
fi
[ -n "${OVMF_CODE}" ] || { echo "ERROR: OVMF firmware not found." >&2; exit 1; }

echo "==> [2/5] Booting headless (secure=${SECURE:-false})..."
qemu-system-x86_64 \
    -enable-kvm -m "${VM_RAM}" -cpu host -smp "${VM_CPUS}" \
    ${MACHINE_ARGS:+-machine "${MACHINE_ARGS}"} \
    "${FLASH_SECURE_ARGS[@]}" \
    -drive "file=${DISK},format=raw,if=virtio" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${WORKDIR}/vars.fd" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -nographic -serial "file:${WORKDIR}/serial.log" \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -daemonize -pidfile "${WORKDIR}/qemu.pid"

cleanup() {
    if [ -S "${MONITOR_SOCK}" ]; then
        echo "system_powerdown" | timeout 5 socat - "UNIX-CONNECT:${MONITOR_SOCK}" &>/dev/null || true
        sleep 3
    fi
    [ -f "${WORKDIR}/qemu.pid" ] && kill -9 "$(cat "${WORKDIR}/qemu.pid")" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "==> [3/5] Waiting for SSH (up to 120s)..."
SSH_UP=false
for _ in $(seq 1 60); do
    if ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=2 -o BatchMode=yes root@localhost true 2>/dev/null; then
        SSH_UP=true
        break
    fi
    sleep 2
done

if [ "${SSH_UP}" != "true" ]; then
    if [ "${EXPECT_FAIL}" = "true" ]; then
        echo "==> PASS (expected failure): VM did not reach SSH — treating as secure boot rejection."
        exit 0
    fi
    echo "==> FAIL: SSH never came up within 120s." >&2
    echo "    Serial log tail:" >&2
    tail -n 40 "${WORKDIR}/serial.log" >&2 || true
    exit 1
fi

if [ "${EXPECT_FAIL}" = "true" ]; then
    echo "==> FAIL (expected failure): VM booted despite --expect-fail (secure boot did not reject it)." >&2
    exit 1
fi

echo "==> [4/5] Running health assertions..."
FAILED=0

SSH() { ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes root@localhost "$@"; }

if ! SSH systemctl is-system-running --wait 2>&1 | grep -qE "^(running|degraded)$"; then
    echo "    FAIL: systemctl is-system-running did not report running/degraded" >&2
    FAILED=1
fi

BOOTCTL_OUT=$(SSH bootctl status 2>&1 || true)
if [ "${SECURE}" = "true" ]; then
    if ! echo "${BOOTCTL_OUT}" | grep -q "Secure Boot: enabled"; then
        echo "    FAIL: bootctl status does not report Secure Boot: enabled" >&2
        FAILED=1
    fi
fi

echo "==> [5/5] Shutting down..."
SSH systemctl poweroff &>/dev/null || true
sleep 5

if [ "${FAILED}" -ne 0 ]; then
    echo "==> boot-test FAILED"
    exit 1
fi
echo "==> boot-test PASSED"
```

- [ ] **Step 2: Make it executable, verify listing**

```bash
chmod +x mise/tasks/boot-test
mise tasks | grep boot-test
```
Expected: `boot-test` listed with its description.

- [ ] **Step 3: Run against the unsigned image**

```bash
mise run boot-test
```
Expected: `boot-test PASSED`, exit code 0.

- [ ] **Step 4: Run against the sealed image with `--secure`**

```bash
mise run boot-test --image localhost/krytis:sealed --secure
```
Expected: `boot-test PASSED`, exit code 0, and the `bootctl status` assertion actually ran (not skipped).

- [ ] **Step 5: Run the negative test**

```bash
mise run boot-test --image localhost/krytis:latest --secure --expect-fail
```
Expected: `PASS (expected failure)`, exit code 0 — confirms the unsigned image is rejected under enforcement, expressed as a passing automated check rather than a manual read of Task 5 Step 8's console output.

- [ ] **Step 6: Update `docs/skills/desktop.md` to remove the stale gap note**

Replace the paragraph at `docs/skills/desktop.md` around "No CI or `mise` task boots the image and checks service health..." — re-read the current file first (it may have shifted line numbers since this plan was written) and update it to point at the new task instead of describing the gap:

```markdown
### Verification (on booted image)

`mise boot-test` (added by #309) boots the image headless, waits for SSH, and asserts
`systemctl is-system-running` + (with `--secure`) `bootctl status`. For deeper service
checks beyond that fixed assertion set, a host already running krytis (self-hosted dev
box) or `mise run boot-vm` + manual login remains the fastest path:
```//keep the existing command examples below unchanged//
```

- [ ] **Step 7: Commit**

```bash
git add mise/tasks/boot-test docs/skills/desktop.md
git commit -m "feat(mise): add boot-test task for automated boot pass/fail

Headless QEMU boot (own ephemeral disk in /tmp, not bootable.raw),
bounded SSH wait, systemctl is-system-running + (with --secure)
bootctl status assertions, clean shutdown via QEMU monitor.
--expect-fail inverts the result for secure boot negative tests.

Closes the 'mise boot-test does not exist' gap AGENTS.md's
Verification section has referenced since before #309 (see
docs/skills/desktop.md, docs/plans/2026-07-05-chunkah-pipeline.md).

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---
## Task 7: Real-hardware enrollment documentation

**Files:**
- Create: `docs/secure-boot-enrollment.md`
- Modify: `docs/SKILL.md` (router entry — this is user-facing operational doc, not an agent skill file, so it's linked from a "Reference Docs" style entry, not the Task → Skill table)

**Interfaces:** No code — a standalone operational doc for a human enrolling a real machine.

**Issue:** #309 acceptance criterion: "Enrollment documentation for real hardware (firmware setup mode + systemd-boot menu flow) written" — this is the one AC that isn't provable by any `mise` command, since it's about a human following steps on physical hardware.
**Blocked by:** Tasks 2-3 (describes the mechanism those tasks implement)

- [ ] **Step 1: Write `docs/secure-boot-enrollment.md`**

```markdown
# Enrolling krytis's Secure Boot Keys on Real Hardware

krytis ships its own PK/KEK/db keys (see `docs/design/secure-boot-uki.md`) and signs
the UKI + `systemd-boot` against them. On real hardware — unlike the QEMU test path,
which bakes keys directly into OVMF vars via `mise run generate-ovmf-vars` — you must
enroll them through the firmware's own Secure Boot setup flow.

## Prerequisites

- A `bootc install`ed krytis system (from `localhost/krytis:sealed`, not `:latest` —
  an unsigned install has nothing to enroll against and secure boot must be **off**
  until enrollment completes, or the machine won't boot at all)
- Physical or remote (IPMI/vPro) access to the firmware setup screen

## 1. Put the firmware in Setup Mode

Reboot into UEFI firmware setup (varies by vendor — commonly `Del`, `F2`, or `F10` at
POST). Find the Secure Boot section (often under "Security" or "Boot"):

1. **Clear existing keys / enter Setup Mode.** Look for "Clear Secure Boot keys",
   "Reset to Setup Mode", or similar. This removes the firmware's factory PK, which
   is what allows new keys to be enrolled at all — Secure Boot cannot be enrolled
   into while the factory PK is still present and locked.
2. Some firmware requires Secure Boot to be **disabled** before you can clear keys,
   then leave Secure Boot in "Setup Mode" (not "enabled", not "disabled" — a distinct
   third state) before rebooting.
3. Save and exit. The machine reboots in Setup Mode — Secure Boot is architecturally
   present but not enforcing (any code can execute) until keys are enrolled.

## 2. Boot krytis and select the key set in the systemd-boot menu

With `secure-boot-enroll manual` set (krytis does this automatically on first boot —
see `docs/skills/secure-boot.md` § First-boot loader.conf edits), systemd-boot shows
an **"Enroll Secure Boot keys"** entry in its boot menu on every boot while the
firmware remains in Setup Mode:

1. At the systemd-boot menu, select **"Enroll Secure Boot keys"** (not the default
   krytis entry).
2. Confirm the enrollment when prompted — systemd-boot writes krytis's PK, KEK, and
   db (from `ESP/loader/keys/auto/*.auth`, placed there by `bootc install` from the
   image's `/usr/lib/bootc/install/secureboot-keys/auto/` — see
   `docs/skills/secure-boot.md` § `.auth` files land at `secureboot-keys/<keyset>/*.auth`)
   into the firmware's PK/KEK/db variables.
3. Enrolling the PK exits Setup Mode and enters **User Mode** — Secure Boot begins
   enforcing immediately, including for the current boot.
4. Reboot. Confirm in the firmware setup screen (or `bootctl status` from within
   krytis) that Secure Boot now shows **enabled (user)**.

## 3. Verify

```bash
bootctl status | grep "Secure Boot"
# Expected: Secure Boot: enabled (user)
```

## What this enrollment does and doesn't preserve

**Preserved:** Microsoft's 2011 and 2023 UEFI CA certs are bundled into `db.auth`
(see `docs/skills/secure-boot.md` § `.auth` generation), so third-party EFI binaries
signed by Microsoft — Option ROMs, GPU/NIC firmware, a Windows bootloader for
dual-boot — continue to verify after enrollment.

**NOT preserved:** enrollment via `loader/keys/auto/*.auth` **replaces** the
firmware's PK/KEK/db outright — it does not merge with whatever `dbDefault`/
`KEKDefault` your specific OEM shipped (vendor-specific option ROM signing keys,
etc.). If you rely on OEM-signed firmware components beyond what's covered by
Microsoft's CAs, they will stop verifying after this enrollment. There is no generic
per-machine fix for this — OEM defaults vary per vendor and aren't knowable at image
build time. If you hit this, you'll see a specific option ROM or add-in card refuse
to initialize under Secure Boot; the fix is case-by-case (contact the vendor for a
Secure Boot-signed firmware update, or accept running without Secure Boot for that
component).

## Recovering from a bad enrollment

If the machine fails to boot after enrollment (extremely rare — this would mean the
.auth files were malformed, which `mise run boot-test --secure` should have already
caught in CI before this image was published): re-enter firmware setup and use the
vendor's "Restore Secure Boot to factory defaults" or "Clear Secure Boot keys" option
again. This returns the firmware to Setup Mode, from which you can either re-enroll
or leave Secure Boot disabled.
```

- [ ] **Step 2: Link it from `docs/SKILL.md`'s Reference Docs table**

Re-read `docs/SKILL.md`'s current "Reference Docs" table before editing (line numbers may have shifted). Add a row:

```markdown
| Enroll secure boot keys on real hardware | [`docs/secure-boot-enrollment.md`](../secure-boot-enrollment.md) |
```

- [ ] **Step 3: Cross-link from `docs/design/secure-boot-uki.md`**

Add a one-line pointer near the "Key enrollment: systemd-boot native (#309)" section: `See docs/secure-boot-enrollment.md for the real-hardware step-by-step.`

- [ ] **Step 4: Commit**

```bash
git add docs/secure-boot-enrollment.md docs/SKILL.md docs/design/secure-boot-uki.md
git commit -m "docs(secure-boot): real hardware enrollment walkthrough

Setup Mode entry, systemd-boot's Enroll Secure Boot keys menu item,
verification, and the OEM-key-preservation limitation (Microsoft CAs
retained, vendor-specific dbDefault/KEKDefault are not).

Part of #309

Assisted-by: Claude Sonnet 4.6"
```

---

## Task 8: Full integration verification + close #309

**Files:** No new files — verification milestone.

**Blocked by:** Tasks 1-7 all complete.

- [ ] **Step 1: Full pipeline from a clean state**

```bash
mise run pull-keys
mise run fetch-microsoft-certs
mise build
mise run seal-uki
mise run generate-ovmf-vars
```
Expected: all succeed.

- [ ] **Step 2: Automated secure boot test — sealed image passes**

```bash
mise run boot-test --image localhost/krytis:sealed --secure
```
Expected: `boot-test PASSED`.

- [ ] **Step 3: Automated negative test — unsigned image rejected**

```bash
mise run boot-test --image localhost/krytis:latest --secure --expect-fail
```
Expected: `PASS (expected failure)`.

- [ ] **Step 3b: Verify bootc actually copied `.auth` files to the ESP (AC: "bootc install copies them to ESP/loader/keys/auto/")**

```bash
mkdir -p /tmp/esp-check
sudo losetup -Pf --show /tmp/test-final.raw > /tmp/esp-loop-dev 2>/dev/null || true
LOOP=$(cat /tmp/esp-loop-dev 2>/dev/null || true)
if [ -n "${LOOP}" ]; then
    sudo mount "${LOOP}p1" /tmp/esp-check
    ls -la /tmp/esp-check/loader/keys/auto/
    sudo umount /tmp/esp-check
    sudo losetup -d "${LOOP}"
fi
```
Expected: `PK.auth`, `KEK.auth`, `db.auth` present under `/tmp/esp-check/loader/keys/auto/` — direct filesystem proof of the `usr/lib/bootc/install/secureboot-keys/auto/` → `ESP/loader/keys/auto/` copy, independent of whatever the firmware does with them at boot. (The partition number/offset for the ESP may not be `p1` on every layout — run `sudo fdisk -l /tmp/test-final.raw` first if this fails, and adjust to the actual ESP partition.)


- [ ] **Step 4: Verify signature chains to the enrolled db cert (closes #33's remaining AC too)**

```bash
mise run generate-disk --image localhost/krytis:sealed --disk /tmp/test-final.raw --size 15G
mise run boot-vm --disk /tmp/test-final.raw --secure
```
In the guest, once booted:
```bash
ssh -p 2222 root@localhost bootctl status
```
Expected: `Secure Boot: enabled (user)` — "user" mode specifically means the firmware verified the boot chain against **enrolled, non-default** keys (as opposed to "setup" mode or Microsoft's factory defaults), which is the concrete proof that `systemd-boot`'s signature chains to krytis's own enrolled db cert, not just "is signed by something."

- [ ] **Step 5: Verify fido2-luks unlock is unaffected**

Per `docs/skills/secure-boot.md` § Signed UKI PCR changes do not affect FIDO2 or passphrase LUKS unlock (already verified structurally for #312 — zero TPM-bound volumes in krytis). Confirm no regression:

```bash
ssh -p 2222 root@localhost lsblk -f | grep crypto_LUKS
ssh -p 2222 root@localhost systemctl status 'systemd-cryptsetup@*' | grep Active
```
Expected: LUKS volume(s) present and unlocked (FIDO2 or passphrase path, per whatever this test VM was enrolled with).

- [ ] **Step 6: `mise lint` passes**

```bash
mise run load-image
mise lint
```
Expected: lint passes on the unsigned `:latest` image (lint doesn't run against `:sealed` — matches existing convention).

- [ ] **Step 7: Open the PR**

```bash
gh pr create --title "feat(secure-boot): add secure boot key enrollment" --body 'Closes #309

## Summary

- .auth EFI signature lists (PK/KEK/db, db bundling Microsoft'"'"'s 2011+2023 CAs)
  generated in the existing SEAL_SECURE_BOOT Containerfile stage, landing at
  /usr/lib/bootc/install/secureboot-keys/auto/ in localhost/krytis:sealed
- First-boot oneshot sets secure-boot-enroll manual in the ESP loader.conf
- mise run generate-ovmf-vars + mise run boot-vm --secure for QEMU testing
- mise run boot-test: new automated headless boot pass/fail task, closes a
  gap AGENTS.mds Verification section has referenced since before this PR

## Design Gate note

.auth generation lives in the Containerfile (keys via --secret mount, same as
UKI/systemd-boot signing in #32/#33), not the standalone BST element issue #309s
original draft sketched — see docs/skills/secure-boot.md for the rationale.

## Verification

- [x] mise run boot-test --image localhost/krytis:sealed --secure passes
- [x] mise run boot-test --image localhost/krytis:latest --secure --expect-fail passes (negative test)
- [x] bootctl status shows "Secure Boot: enabled (user)" in the guest — chains to the enrolled db cert, not just "is signed"
- [x] fido2-luks unlock unaffected (#312 — zero TPM-bound volumes)
- [x] mise lint passes

This also satisfies #33s two remaining acceptance criteria ("boots under secure
boot" and "signature chains to the enrolled db cert") — #33 close-out plan
references this PR.

Assisted-by: Claude Sonnet 4.6'
```

---

## Notes for the implementer

1. **The signing half of this epic (#32/#33) already shipped** in PR #370 — `bootc container ukify` + `sbsign` in a two-stage Containerfile. This plan only adds enrollment on top. Don't re-derive the UKI/signing steps; the Task 2 diff shows exactly what to add to the *existing* file.
2. **`.auth` generation is gated by the same `SEAL_SECURE_BOOT` arg** as UKI/systemd-boot signing — `mise build` (`:latest`) never produces `.auth` files, only `mise run seal-uki` (`:sealed`) does. This is deliberate: unsigned images have nothing for `.auth` files to be trusted against.
3. **The `auto` directory name in `secureboot-keys/auto/` is load-bearing**, confirmed by reading bootc's source directly (not inferred from docs) — it's the specific key-set name systemd-boot recognizes for its `if-safe`/`manual` auto-enrollment behavior.
4. **`bootc` does not write `loader.conf`'s `secure-boot-enroll` setting** — confirmed by grepping bootc's full source tree, zero matches. The first-boot oneshot service in Task 3 is not a workaround for a missing feature; it's filling a gap that's out of scope for bootc itself.
5. **`virt-fw-vars` and secboot-variant OVMF are host tools**, not `mise`-managed and not part of the krytis image — same category as the existing `qemu-system-x86_64`/`edk2-ovmf` prerequisite already documented in `docs/skills/mise.md`.
6. **`mise boot-test` is new**, not a rename of `boot-vm`. `boot-vm` stays interactive (GTK window, for manual debugging); `boot-test` is headless and asserts pass/fail for CI/scripted use. Both share the OVMF-selection logic; if it drifts between the two, that's worth factoring into a shared helper script in a follow-up — out of scope here (YAGNI: only extract the duplication once a third caller needs it).
