# Chunkah Pipeline Port (#15) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port dakota's chunkah rechunking pipeline into krytis so `mise generate-disk` can enable `--composefs-backend` on a real component-keyed chunked image, closing #15 via its sub-issues #28, #29, #30.

**Architecture:** Add one BST-adjacent host tool (`fakecap-restore.c`, compiled ad hoc — not a BST element), one manifest-generation mise task that walks BST artifacts to attribute every installed file to its owning element, and one `chunkify` mise task that mounts `localhost/krytis:latest` as a writable overlay, injects `user.component` xattrs, and runs the pinned `chunkah` container to re-layer the image. This mirrors dakota's proven pipeline (`docs/plan/composefs-chunkah.md`), confirmed unchanged against true upstream `projectbluefin/dakota` as of 2026-07-05, with one upstream fix (largest-free-tmpdir) folded in that dakota's own doc-era snapshot didn't have.

**Tech Stack:** bash (mise tasks), Python 3.12 (manifest generation, already a project dependency via `pyproject.toml`), C (`fakecap-restore`, compiled with `gcc` at task-run time — matches dakota, not a BST-shipped binary), podman, `quay.io/coreos/chunkah`.

## Global Constraints

- No RPMs, no dnf, no container package overlays — BST elements only for anything that ships in the image (AGENTS.md). `fakecap-restore` and the manifest generator are **host-side build tooling**, not shipped in the image, so they are plain `files/` + `scripts/` + `mise/tasks/` artifacts, not new `.bst` elements — the Update Path Gate does not apply to them.
- All maintenance tasks must be `mise` tasks (AGENTS.md) — no loose shell commands.
- `chunkah` is pinned by tag+digest (`quay.io/coreos/chunkah:v0.6.0@sha256:ff8b8b466a942ec6000445d4001fc661e2fc5a952ad9ee29b4de9ab09d1d1708`, current as of dakota's real upstream HEAD, verified 2026-07-05). Per repo convention (every pinned external ref gets an `<name>-update` mise task + `track-bst-sources.yml` job, e.g. `gum-update`, `mise-update`), add `chunkah-update` and wire it into CI (Task 4) even though it's not one of the three sub-issue titles — this satisfies the Update Path Gate's spirit for a digest that otherwise has no automated freshness check.
- Skill-improvement mandate: each task below ends with a `docs/skills/` update in the **same commit** as the code it documents — not a follow-up.
- This repo has no unit-test framework (no `tests/`, no pytest in `pyproject.toml`) — verification is command-output-driven (`mise validate`, `mise lint`, manual runs with `diff`/`getfattr`/`grep` assertions), matching AGENTS.md's Verification section. Steps below use that style instead of introducing pytest as a new dependency (YAGNI — don't add a test framework for 3 scripts when the whole repo verifies this way).

---

### Task 1 (issue #29): Port fakecap-restore from dakota

**Files:**
- Create: `files/fakecap/fakecap-restore.c`
- Create: `docs/skills/chunkah.md` (new skill file — nothing currently documents the chunkah pipeline in `docs/skills/`)

**Interfaces:**
- Produces: a compiled `files/fakecap/fakecap-restore` binary (gitignored — added to `.gitignore`), invoked as `fakecap-restore <manifest.tsv> <rootfs>`. Task 3 (chunkify) depends on this exact CLI signature.

- [ ] **Step 1: Add the C source verbatim (MIT-licensed port from dakota)**

Create `files/fakecap/fakecap-restore.c`:

```c
/*
 * fakecap-restore — physically write user.component xattrs from a
 * fakecap manifest to a target rootfs.
 *
 * Usage: fakecap-restore <manifest.tsv> <rootfs>
 *
 * Reads a TSV manifest (path\tcomponent\tinterval) and calls lsetxattr
 * on each file under <rootfs>.  Skips missing files silently.
 *
 * Physical xattr injection for BST images.
 * chunkah uses rustix raw syscalls for xattr reads (bypassing libc / LD_PRELOAD),
 * so xattrs must be physically applied before chunkah runs.
 * coreos/chunkah#113 is closed — the resolution is this overlay approach,
 * not a libc fallback. Used by `just chunkify` for local dev; CI uses
 * the bootc-build/chunka action (inject-xattrs.py) instead.
 *
 * Copyright (c) 2025  contributors
 * SPDX-License-Identifier: MIT
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: fakecap-restore <manifest.tsv> <rootfs>\n");
        return 1;
    }
    const char *manifest_path = argv[1];
    const char *rootfs        = argv[2];

    FILE *f = fopen(manifest_path, "r");
    if (!f) {
        perror("fakecap-restore: open manifest");
        return 1;
    }

    size_t n_set = 0, n_skip = 0, n_err = 0;
    char line[8192];

    while (fgets(line, sizeof(line), f)) {
        /* strip newline */
        size_t len = strlen(line);
        if (len && line[len - 1] == '\n') line[--len] = '\0';

        if (!*line || *line == '#') continue;

        char *tab1 = strchr(line, '\t');
        if (!tab1) continue;
        *tab1 = '\0';
        const char *rel_path  = line;
        const char *component = tab1 + 1;

        char *tab2 = strchr(component, '\t');
        const char *interval = "weekly";
        if (tab2) { *tab2 = '\0'; interval = tab2 + 1; }

        char fullpath[8192];
        if (snprintf(fullpath, sizeof(fullpath), "%s%s", rootfs, rel_path)
                >= (int)sizeof(fullpath))
            continue;

        int r = lsetxattr(fullpath, "user.component",
                          component, strlen(component), 0);
        if (r < 0) {
            /* ENOENT: file absent in this image variant — expected, skip.
             * EPERM/ENOTSUP/EOPNOTSUPP: symlinks and some special files do
             * not support user.* xattrs on Linux — expected, skip. */
            if (errno == ENOENT   ||
                errno == EPERM    ||
                errno == ENOTSUP  ||
                errno == EOPNOTSUPP) { n_skip++; continue; }
            n_err++;
            continue;
        }

        lsetxattr(fullpath, "user.update-interval",
                  interval, strlen(interval), 0);
        n_set++;
    }
    fclose(f);

    fprintf(stderr,
            "fakecap-restore: %zu xattrs set, %zu files skipped, %zu errors\n",
            n_set, n_skip, n_err);
    return n_err > 0 ? 1 : 0;
}
```

- [ ] **Step 2: Add the compiled binary to `.gitignore`**

Append to `.gitignore`:

```
files/fakecap/fakecap-restore
```

- [ ] **Step 3: Compile and smoke-test against a scratch directory**

Run:

```bash
gcc -O2 -o files/fakecap/fakecap-restore files/fakecap/fakecap-restore.c
mkdir -p /tmp/fakecap-smoke/usr/bin
touch /tmp/fakecap-smoke/usr/bin/testfile
printf '/usr/bin/testfile\tcomponents/test.bst\tmonthly\n' > /tmp/fakecap-smoke/manifest.tsv
./files/fakecap/fakecap-restore /tmp/fakecap-smoke/manifest.tsv /tmp/fakecap-smoke
getfattr -n user.component --only-values /tmp/fakecap-smoke/usr/bin/testfile
echo; getfattr -n user.update-interval --only-values /tmp/fakecap-smoke/usr/bin/testfile
rm -rf /tmp/fakecap-smoke
```

Expected: stderr prints `fakecap-restore: 1 xattrs set, 0 files skipped, 0 errors`, first `getfattr` prints `components/test.bst`, second prints `monthly`.

- [ ] **Step 4: Verify the ENOENT-skip path (missing file must not error)**

Run:

```bash
mkdir -p /tmp/fakecap-smoke2
printf '/usr/bin/does-not-exist\tcomponents/test.bst\tmonthly\n' > /tmp/fakecap-smoke2/manifest.tsv
./files/fakecap/fakecap-restore /tmp/fakecap-smoke2/manifest.tsv /tmp/fakecap-smoke2; echo "exit=$?"
rm -rf /tmp/fakecap-smoke2
```

Expected: stderr prints `fakecap-restore: 0 xattrs set, 1 files skipped, 0 errors`, `exit=0`.

- [ ] **Step 5: Create `docs/skills/chunkah.md` with the porting note**

Create `docs/skills/chunkah.md`:

```markdown
# chunkah — composefs rechunking pipeline

Ported from dakota (`projectbluefin/dakota`) per #15. Splits the single-layer
krytis OCI image into up to 120 component-keyed layers so `bootc install
to-disk --composefs-backend` gets valid ostree splitstreams and OTA deltas
stay small.

## fakecap-restore (#29)

`files/fakecap/fakecap-restore.c` is a **host-side build tool**, not a BST
element — it is compiled ad hoc with `gcc -O2` by the `chunkify` mise task
(see below), matching dakota's own approach. It is *not* the same thing as
`freedesktop-sdk.bst:components/fakecap.bst` (an `LD_PRELOAD` shim used
during BST sandbox builds for fake capabilities) — same author lineage,
completely different purpose. Do not conflate the two when grepping for
"fakecap" in this repo.

chunkah reads `user.component` xattrs via rustix raw syscalls, bypassing
`LD_PRELOAD` — so the xattrs must be physically present on disk before
chunkah runs (coreos/chunkah#113, closed; overlay+physical-xattr is the
permanent resolution, not a future libc fallback).

fakecap-restore treats `ENOENT` (file absent in this image variant) and
`EPERM`/`ENOTSUP`/`EOPNOTSUPP` (symlinks and special files don't support
`user.*` xattrs) as expected skips, not errors — only genuine I/O errors
count toward its exit code.
```

- [ ] **Step 6: Commit**

```bash
git add files/fakecap/fakecap-restore.c .gitignore docs/skills/chunkah.md
git commit -m "$(cat <<'EOF'
feat(chunkah): port fakecap-restore from dakota

Physically applies user.component xattrs before chunkah runs, since
chunkah reads xattrs via rustix raw syscalls (bypasses LD_PRELOAD).
Host-side build tool, compiled ad hoc — not a BST element.

Closes #29
EOF
)"
```

---

### Task 2 (issue #28): Generate fakecap manifest task

**Files:**
- Create: `scripts/generate-fakecap-manifest.py`
- Create: `mise/tasks/generate-fakecap-manifest`
- Modify: `docs/skills/chunkah.md` (append manifest-generation section)

**Interfaces:**
- Consumes: `/usr/manifest.json` module list format documented in `docs/skills/bst.md:1194-1201` (`{"modules": [{"name": "core-deps/NetworkManager.bst", ...}, ...]}`), and `mise/tasks/bst` (existing wrapper, same one `load-image` uses at `mise/tasks/load-image:9`).
- Produces: `files/fakecap-manifest.tsv` with lines `<abs-path-in-image>\t<element-name>\t<interval>`. Task 3 (chunkify) consumes this file verbatim as `fakecap-restore`'s first argument.

- [ ] **Step 1: Write `scripts/generate-fakecap-manifest.py`**

```python
#!/usr/bin/env python3
"""Attribute every file in the built krytis image to its owning BST element.

Reads the element list from a built image's /usr/manifest.json (produced by
elements/oci/krytis/manifest.bst), then for each element asks BuildStream for
that element's own artifact file list via `bst artifact checkout --tar -`,
and writes files/fakecap-manifest.tsv (path\telement\tinterval) for
fakecap-restore to consume.
"""
import json
import subprocess
import sys
import tarfile
import io
from pathlib import Path

MANIFEST_JSON = Path("usr-manifest.json")
OUTPUT_TSV = Path("files/fakecap-manifest.tsv")
DEFAULT_INTERVAL = "monthly"


def element_names(manifest_path: Path) -> list[str]:
    data = json.loads(manifest_path.read_text())
    return sorted({m["name"] for m in data["modules"]})


def files_for_element(element: str) -> list[str]:
    """Return absolute in-image paths (leading '/') contributed by one element."""
    proc = subprocess.run(
        ["./mise/tasks/bst", "artifact", "checkout", "--tar", "-", element],
        stdout=subprocess.PIPE,
        check=True,
    )
    paths = []
    with tarfile.open(fileobj=io.BytesIO(proc.stdout)) as tar:
        for member in tar.getmembers():
            if member.isfile() or member.issym():
                paths.append("/" + member.name.lstrip("/"))
    return paths


def main() -> int:
    if not MANIFEST_JSON.exists():
        print(
            f"error: {MANIFEST_JSON} not found. Extract /usr/manifest.json from "
            "localhost/krytis:latest first, e.g.:\n"
            "  podman run --rm localhost/krytis:latest cat /usr/manifest.json "
            f"> {MANIFEST_JSON}",
            file=sys.stderr,
        )
        return 1

    elements = element_names(MANIFEST_JSON)
    print(f"==> {len(elements)} elements in manifest", file=sys.stderr)

    rows: list[tuple[str, str, str]] = []
    for i, element in enumerate(elements, 1):
        print(f"==> [{i}/{len(elements)}] {element}", file=sys.stderr)
        try:
            paths = files_for_element(element)
        except subprocess.CalledProcessError as exc:
            print(f"    skip (artifact checkout failed): {exc}", file=sys.stderr)
            continue
        for path in paths:
            rows.append((path, element, DEFAULT_INTERVAL))

    OUTPUT_TSV.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_TSV.open("w") as out:
        for path, element, interval in sorted(rows):
            out.write(f"{path}\t{element}\t{interval}\n")

    print(f"==> Wrote {len(rows)} rows to {OUTPUT_TSV}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Wire it into a mise task**

Create `mise/tasks/generate-fakecap-manifest`:

```bash
#!/usr/bin/env bash
#MISE description="Regenerate files/fakecap-manifest.tsv from localhost/krytis:latest"
#USAGE flag "--tag <tag>" default="localhost/krytis:latest" help="Image tag to attribute files from"

set -euo pipefail

TAG="${usage_tag:-localhost/krytis:latest}"

echo "==> Extracting /usr/manifest.json from ${TAG}..."
podman run --rm "${TAG}" cat /usr/manifest.json > usr-manifest.json

echo "==> Attributing files to elements (this walks every element's artifact — slow)..."
uv run python3 scripts/generate-fakecap-manifest.py

rm -f usr-manifest.json
echo "==> Done. Review and commit files/fakecap-manifest.tsv."
```

```bash
chmod +x mise/tasks/generate-fakecap-manifest
```

- [ ] **Step 3: Verify the script's pure-logic function in isolation (no full image build needed)**

Run:

```bash
mkdir -p /tmp/manifest-smoke
python3 - <<'EOF'
import importlib.util
spec = importlib.util.spec_from_file_location("gfm", "scripts/generate-fakecap-manifest.py")
gfm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gfm)

from pathlib import Path
Path("/tmp/manifest-smoke/usr-manifest.json").write_text(
    '{"modules": [{"name": "components/test-b.bst"}, {"name": "components/test-a.bst"}]}'
)
names = gfm.element_names(Path("/tmp/manifest-smoke/usr-manifest.json"))
assert names == ["components/test-a.bst", "components/test-b.bst"], names
print("OK: element_names sorts and dedupes")
EOF
rm -rf /tmp/manifest-smoke
```

Expected: prints `OK: element_names sorts and dedupes`.

- [ ] **Step 4: Run end-to-end against a real built image (requires `mise load-image && mise lint` already done)**

Run:

```bash
mise generate-fakecap-manifest
wc -l files/fakecap-manifest.tsv
head -5 files/fakecap-manifest.tsv
```

Expected: a non-empty TSV, each line `/abs/path<TAB>element-name.bst<TAB>monthly`.

- [ ] **Step 5: Append manifest-generation notes to `docs/skills/chunkah.md`**

Append to `docs/skills/chunkah.md`:

```markdown

## fakecap-manifest.tsv generation (#28)

`mise generate-fakecap-manifest` extracts `/usr/manifest.json` from
`localhost/krytis:latest` (must already be built via `mise load-image &&
mise lint`), then for each element name in the manifest runs
`bst artifact checkout --tar - <element>` and records every file path that
element's own artifact contributes. This is `bst`'s per-element artifact
output, not a scan of the assembled image filesystem — it walks every
element in the closure, so it is slow (one `bst artifact checkout` per
element) but attributes files exactly the way dakota's dakota-side
"rechunk" process does conceptually, without needing dakota's tooling.

`files/fakecap-manifest.tsv` should be committed (same convention as
dakota) and regenerated whenever elements meaningfully change — there is
no CI job auto-regenerating it yet (dakota's `update-filemap.yml` has no
krytis equivalent); re-run the mise task manually and commit the diff.

All rows currently get `interval=monthly` — krytis doesn't yet distinguish
weekly/daily-changing components the way dakota's finer-grained interval
tagging does. This is fine for the initial port (YAGNI); revisit only if
OTA delta size becomes a problem.
```

- [ ] **Step 6: Commit**

```bash
git add scripts/generate-fakecap-manifest.py mise/tasks/generate-fakecap-manifest docs/skills/chunkah.md
git commit -m "$(cat <<'EOF'
feat(chunkah): add generate-fakecap-manifest mise task

Attributes every file in the built image to its owning BST element by
walking /usr/manifest.json's module list and checking out each
element's own artifact contents. Feeds fakecap-restore (#29).

Closes #28
EOF
)"
```

---

### Task 3 (issue #30): Add chunkify task

**Files:**
- Create: `mise/tasks/chunkify`
- Modify: `docs/skills/chunkah.md` (append chunkify section)
- Modify: `docs/skills/mise.md` (add `mise chunkify` to Quick reference + Standard build workflow)

**Interfaces:**
- Consumes: `files/fakecap-manifest.tsv` (Task 2 output), `files/fakecap/fakecap-restore` binary (compiled inline, same as Task 1's Step 3 — the task compiles it itself if missing, mirroring dakota), `localhost/krytis:latest` (built by existing `mise lint`).
- Produces: `localhost/krytis:latest` re-tagged in place as a chunked, composefs-ready image — no new tag name, so `mise generate-disk` (already `--composefs-backend`, `mise/tasks/generate-disk:39`) needs no changes.

- [ ] **Step 1: Write `mise/tasks/chunkify`**

```bash
#!/usr/bin/env bash
#MISE description="Rechunk localhost/krytis:latest into composefs-ready component layers via chunkah"
#USAGE flag "--tag <tag>" default="localhost/krytis:latest" help="Image tag to chunkify in place"

set -euo pipefail

TAG="${usage_tag:-localhost/krytis:latest}"

# Pinned chunkah image — bump via `mise chunkah-update` (see Task 4).
CHUNKAH_REF="quay.io/coreos/chunkah:v0.6.0@sha256:ff8b8b466a942ec6000445d4001fc661e2fc5a952ad9ee29b4de9ab09d1d1708"

echo "==> Chunkifying ${TAG}..."

SUDO_CMD=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

CONFIG=$($SUDO_CMD podman inspect "${TAG}")

FAKECAP_RESTORE="$(pwd)/files/fakecap/fakecap-restore"
if [ ! -x "${FAKECAP_RESTORE}" ]; then
    echo "==> Compiling fakecap-restore..."
    gcc -O2 -o "${FAKECAP_RESTORE}" "$(pwd)/files/fakecap/fakecap-restore.c"
fi

LOWER=$($SUDO_CMD podman image mount "${TAG}")

cleanup() {
    $SUDO_CMD umount "$MERGED" 2>/dev/null || true
    $SUDO_CMD rm -rf "$UPPER" "$WORK" "$MERGED"
    $SUDO_CMD podman image umount "${TAG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Pick the tmpdir with the most free space for the overlay work dirs.
# fakecap-restore triggers overlayfs copy-up for every file it touches;
# copy-ups can exhaust /var/tmp on machines where root has little free
# space (e.g. CI runners with a BTRFS loopback for /var/lib/containers).
# Ported from dakota's e0b5a52 — see docs/skills/chunkah.md.
_OVERLAY_TMPDIR="/var/tmp"
for _candidate in /var/lib/containers /var/tmp; do
    if [ -d "${_candidate}" ]; then
        _free=$(df --output=avail "${_candidate}" 2>/dev/null | tail -1 || echo 0)
        _best=$(df --output=avail "${_OVERLAY_TMPDIR}" 2>/dev/null | tail -1 || echo 0)
        if (( _free > _best )); then _OVERLAY_TMPDIR="${_candidate}"; fi
    fi
done
echo "==> overlay tmpdir: ${_OVERLAY_TMPDIR} ($(df -h --output=avail "${_OVERLAY_TMPDIR}" | tail -1 | tr -d ' ') free)"
UPPER=$(mktemp -d -p "${_OVERLAY_TMPDIR}")
WORK=$(mktemp -d -p "${_OVERLAY_TMPDIR}")
MERGED=$(mktemp -d -p "${_OVERLAY_TMPDIR}")
$SUDO_CMD chmod 755 "${UPPER}" "${WORK}" "${MERGED}"
$SUDO_CMD mount -t overlay overlay \
    -o "lowerdir=${LOWER},upperdir=${UPPER},workdir=${WORK}" \
    "${MERGED}"

echo "==> Applying user.component xattrs via fakecap-restore..."
$SUDO_CMD "${FAKECAP_RESTORE}" files/fakecap-manifest.tsv "${MERGED}"

echo "==> Pulling chunkah..."
for attempt in 1 2 3; do
    $SUDO_CMD podman pull "${CHUNKAH_REF}" && break
    echo "==> chunkah pull attempt ${attempt} failed, retrying in 10s..."
    [ "${attempt}" -lt 3 ] && sleep 10
done

echo "==> Running chunkah (max 120 layers)..."
LOADED=$($SUDO_CMD podman run --rm \
    --pull never \
    --security-opt label=type:unconfined_t \
    -v "${MERGED}:/chunkah:ro" \
    -e "CHUNKAH_ROOTFS=/chunkah" \
    -e "CHUNKAH_CONFIG_STR=${CONFIG}" \
    "${CHUNKAH_REF}" build --max-layers 120 --prune /sysroot/ \
    --label ostree.commit- --label ostree.final-diffid- \
    | $SUDO_CMD podman load)

echo "${LOADED}"

# Parse the loaded image reference — podman's "Loaded image" wording varies by version.
NEW_REF=$(echo "${LOADED}" | sed -n 's/^Loaded image(s): //p; s/^Loaded image: //p' | head -1)
if [ -z "${NEW_REF}" ]; then
    NEW_REF=$(echo "${LOADED}" | grep -oP '^[0-9a-f]{64}$' | head -1 || true)
fi

if [ -n "${NEW_REF}" ] && [ "${NEW_REF}" != "${TAG}" ]; then
    echo "==> Retagging chunked image to ${TAG}..."
    $SUDO_CMD podman tag "${NEW_REF}" "${TAG}"
fi

echo "==> Done: ${TAG} is now composefs-ready."
```

```bash
chmod +x mise/tasks/chunkify
```

- [ ] **Step 2: Verify overlay-tmpdir selection logic in isolation**

Run:

```bash
bash -c '
_OVERLAY_TMPDIR="/var/tmp"
for _candidate in /var/lib/containers /var/tmp; do
    if [ -d "$_candidate" ]; then
        _free=$(df --output=avail "$_candidate" 2>/dev/null | tail -1 || echo 0)
        _best=$(df --output=avail "$_OVERLAY_TMPDIR" 2>/dev/null | tail -1 || echo 0)
        if (( _free > _best )); then _OVERLAY_TMPDIR="$_candidate"; fi
    fi
done
echo "picked: $_OVERLAY_TMPDIR"
'
```

Expected: prints `picked: /var/tmp` or `picked: /var/lib/containers`, whichever this machine reports more free space for — confirms no syntax error and the comparison runs.

- [ ] **Step 3: Run end-to-end (requires sudo, requires Task 1 + Task 2 already done and `files/fakecap-manifest.tsv` present)**

Run:

```bash
mise load-image
mise lint
mise generate-fakecap-manifest
mise chunkify
podman inspect localhost/krytis:latest --format '{{len .RootFS.Layers}}'
```

Expected: layer count prints something in the 1–120 range and greater than the pre-chunkify single-layer count (i.e. > 1) — confirms the image was actually re-layered.

- [ ] **Step 4: Confirm `generate-disk` now succeeds with `--composefs-backend` on the chunked image**

Run:

```bash
mise generate-disk
```

Expected: completes without the `"Invalid splitstream content type"` error noted in `docs/plan/composefs-chunkah.md` — this is the acceptance criterion for #15 as a whole. (Full VM boot-test is out of scope for this step per the existing `mise boot-test` gap — see the `project_boot_test_gap` memory; a successful `bootc install to-disk` exit code is the bar here, matching the "no automated boot verification anywhere in repo" reality.)

- [ ] **Step 5: Update `docs/skills/mise.md`**

In `docs/skills/mise.md`, add to the "Quick reference" block (after the `mise lint` line):

```
mise chunkify                                      # rechunk into composefs-ready component layers
```

And update the "Standard build workflow" block to insert chunkify between lint and generate-disk:

```
mise validate                 # confirm element graph resolves
mise load-image               # BST build → podman local storage
mise lint                     # bootc container lint (squash-all)
mise generate-fakecap-manifest # regenerate files/fakecap-manifest.tsv (only when elements change)
mise chunkify                 # rechunk into composefs-ready component layers
mise generate-disk            # bootc install to-disk → bootable.raw
mise boot-vm                  # QEMU boot (native KVM or qemux/qemu-docker)
```

- [ ] **Step 6: Append chunkify notes to `docs/skills/chunkah.md`**

Append to `docs/skills/chunkah.md`:

```markdown

## chunkify task (#30)

`mise chunkify` mounts `localhost/krytis:latest` as a writable overlay,
runs `fakecap-restore` to physically set `user.component` xattrs from
`files/fakecap-manifest.tsv`, then runs the pinned `chunkah` container
against the overlay and re-tags the result back onto the same image tag —
no new tag, so `mise generate-disk`'s existing `--composefs-backend` flag
(`mise/tasks/generate-disk:39`) needed no change.

**Overlay tmpdir disk-pressure fix**, ported from dakota's `e0b5a52`
(upstream `projectbluefin/dakota`, 2026-06-13 — confirmed via `git log
HEAD..upstream/main` that this is dakota's *current* logic, not a stale
snapshot): `fakecap-restore` triggers an overlayfs copy-up for every file
it touches, and the manifest can be hundreds of thousands of entries. On
a machine where root has little free space (BTRFS loopback CI runners,
constrained dev VMs), that exhausts `/var/tmp`. The task picks whichever
of `/var/lib/containers` or `/var/tmp` reports more free space via `df
--output=avail` for the overlay's upper/work/merged dirs.

**Podman "Loaded image" parsing** handles three known output formats
(`Loaded image: <ref>`, `Loaded image(s): <ref>`, and bare 64-char sha256
for untagged archives on some podman versions) — this is copied from
dakota verbatim since it is itself a defensive workaround for
podman-version skew, not something worth re-deriving.
```

- [ ] **Step 7: Commit**

```bash
git add mise/tasks/chunkify docs/skills/chunkah.md docs/skills/mise.md
git commit -m "$(cat <<'EOF'
feat(chunkah): add chunkify mise task

Rechunks localhost/krytis:latest into composefs-ready component
layers via the pinned chunkah container, so generate-disk's existing
--composefs-backend flag can succeed. Ports dakota's overlay
tmpdir disk-pressure fix (e0b5a52) that predates our design doc.

Closes #30, closes #15
EOF
)"
```

---

### Task 4 (Update Path Gate compliance, not a named sub-issue): chunkah digest tracking

**Files:**
- Create: `mise/tasks/chunkah-update`
- Modify: `.github/workflows/track-bst-sources.yml` (add `track-chunkah` job + `chunkah` choice option)

**Interfaces:**
- Consumes: `CHUNKAH_REF` string literal in `mise/tasks/chunkify` (Task 3, Step 1).
- Produces: an updated `CHUNKAH_REF` line in `mise/tasks/chunkify`, same file the task itself lives in.

- [ ] **Step 1: Write `mise/tasks/chunkah-update`**

```bash
#!/usr/bin/env bash
#MISE description="Update the pinned chunkah container digest in mise/tasks/chunkify"

set -euo pipefail

TASK_FILE="mise/tasks/chunkify"
IMAGE="quay.io/coreos/chunkah"

CURRENT_REF=$(grep -oP 'CHUNKAH_REF="\K[^"]+' "${TASK_FILE}")
CURRENT_TAG=$(echo "${CURRENT_REF}" | sed -n 's|.*:\([^@]*\)@.*|\1|p')
echo "==> Current: ${CURRENT_REF}"

echo "==> Fetching latest tags for ${IMAGE}..."
LATEST_TAG=$(skopeo list-tags "docker://${IMAGE}" | jq -r '.Tags[]' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
echo "==> Latest tag: ${LATEST_TAG}"

LATEST_DIGEST=$(skopeo inspect "docker://${IMAGE}:${LATEST_TAG}" | jq -r '.Digest')
NEW_REF="${IMAGE}:${LATEST_TAG}@${LATEST_DIGEST}"

if [ "${NEW_REF}" = "${CURRENT_REF}" ]; then
    echo "==> Already up to date (${CURRENT_REF})"
    exit 0
fi

echo "==> Updating ${TASK_FILE}: ${CURRENT_TAG} → ${LATEST_TAG}"
sed -i "s|CHUNKAH_REF=\"${CURRENT_REF}\"|CHUNKAH_REF=\"${NEW_REF}\"|" "${TASK_FILE}"

echo "==> Done. Run 'mise chunkify' against a built image to verify."
```

```bash
chmod +x mise/tasks/chunkah-update
```

- [ ] **Step 2: Verify the digest-parsing regex against the current pinned value**

Run:

```bash
grep -oP 'CHUNKAH_REF="\K[^"]+' mise/tasks/chunkify
```

Expected: prints `quay.io/coreos/chunkah:v0.6.0@sha256:ff8b8b466a942ec6000445d4001fc661e2fc5a952ad9ee29b4de9ab09d1d1708` (the exact string written into `mise/tasks/chunkify` in Task 3, Step 1) — confirms the grep pattern matches the real line before wiring it into CI.

- [ ] **Step 3: Add a `track-chunkah` job to `.github/workflows/track-bst-sources.yml`**

Add `chunkah` to the `workflow_dispatch.inputs.group.options` list (alongside `gum`, `pangolin`, etc.), then add a job modeled on the existing `track-gum` structure but calling the new task instead of an element-specific script:

```yaml
  track-chunkah:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      pull-requests: write
    if: >-
      github.event.inputs.group == 'all' ||
      github.event.inputs.group == 'chunkah' ||
      github.event_name == 'schedule'
    steps:
      - name: Checkout repository
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7
        with:
          fetch-depth: 0

      - name: Setup mise
        uses: jdx/mise-action@e6a8b3978addb5a52f2b4cd9d91eafa7f0ab959d # v4.2.0
        with:
          experimental: true

      - name: Run chunkah-update
        run: mise run chunkah-update

      - name: Create PR if changed
        run: |
          if git diff --quiet; then
            echo "No changes"
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          BRANCH="track/chunkah-$(date +%Y%m%d)"
          git checkout -b "${BRANCH}"
          git add mise/tasks/chunkify
          git commit -m "chore(deps): update chunkah digest"
          git push origin "${BRANCH}"
          gh pr create --title "chore(deps): update chunkah digest" \
            --body "Automated digest bump via track-bst-sources.yml" \
            --base main --head "${BRANCH}"
        env:
          GH_TOKEN: ${{ github.token }}
```

Use the exact SHA-pinned action refs already present elsewhere in this file for `actions/checkout` and `jdx/mise-action` (copy them, don't retype — confirm via `grep -n "actions/checkout@\|mise-action@" .github/workflows/track-bst-sources.yml` before finalizing this step, since pins get bumped independently of this plan).

- [ ] **Step 4: Commit**

```bash
git add mise/tasks/chunkah-update .github/workflows/track-bst-sources.yml
git commit -m "$(cat <<'EOF'
ci(chunkah): add digest tracking task and CI job

Every other pinned external ref in this repo has an <name>-update
mise task + track-bst-sources.yml job; chunkah's digest had neither.
Closes the Update Path Gate compliance gap for #30.
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** every numbered step of `docs/plan/composefs-chunkah.md`'s "What krytis needs" section (1. generate manifest, 2. port fakecap-restore, 3. chunkify task, 4. re-enable `--composefs-backend`) maps to Tasks 1–3; item 4 needed no code change since `generate-disk` already carries the flag (confirmed at `mise/tasks/generate-disk:39`) — Task 3 Step 4 is the verification that this flag now actually works instead of failing.
- **Fork-staleness caveat carried forward:** the `CHUNKAH_REF` digest and the tmpdir fix in this plan were verified against `projectbluefin/dakota` directly (not the stale `starlit-os/dakota` fork mirror) — see the `project_chunkah_pipeline_state` memory. Re-verify before merging if significant time has passed since 2026-07-05.
- **Type/interface consistency:** `fakecap-restore <manifest.tsv> <rootfs>` (Task 1) is called identically in Task 3's chunkify script; `files/fakecap-manifest.tsv` (Task 2's output path) matches the literal path Task 3 passes to fakecap-restore; `localhost/krytis:latest` is the same default tag threaded through Tasks 2 and 3's `--tag` flags.
