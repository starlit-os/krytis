#!/usr/bin/bash
# scripts/iso-sd-boot.sh — Assemble a systemd-boot UEFI live ISO for krytis.
#
# Called by the build-iso mise task after the live installer container
# (localhost/krytis-installer) has already been built. Receives configuration
# via environment:
#
#   TARGET            — variant directory name (always "krytis")
#   OUTPUT_DIR        — directory for the final ISO and intermediate artifacts
#   WORKDIR           — working directory for the squashfs root
#   DEBUG             — 0 (default) or 1 to enable SSH in the live env
#   INSTALLER_CHANNEL — stable (default) or dev
#   COMPRESSION       — fast (default) or release
#   PAYLOAD_REF       — OCI ref of the offline install payload. Overrides
#                       <target>/payload_ref when set; the same ref is forwarded
#                       to the live-installer container build so recipe.json's
#                       imgref/targetImgref/image move with it, and is written
#                       as media-input.json's image/targetImgref.
#   PAYLOAD_SEALED    — 0 (default) or 1. 1 embeds the payload byte-identically:
#                       payload prep is skipped entirely so no file is injected
#                       and no layer is re-committed. Required for a sealed (signed
#                       UKI) payload, whose frozen cmdline pins a composefs digest.
#   ISO_TOOLS_IMAGE   — podman image carrying xorriso/implantisomd5 (set when
#                       the host lacks those tools, e.g. an immutable Krytis host)
#
# All variables have defaults so the script can be run standalone for testing.
# Usage: TARGET=krytis OUTPUT_DIR=output bash scripts/iso-sd-boot.sh
#
# NOTE: localhost/krytis-installer must already exist before calling this
# script. Build it first via `mise run iso-container-build` or the build-iso
# task, which calls iso-container-build before invoking this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

TARGET="${TARGET:?TARGET must be set}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"
WORKDIR="${WORKDIR:-${OUTPUT_DIR}}"
DEBUG="${DEBUG:-0}"
INSTALLER_CHANNEL="${INSTALLER_CHANNEL:-stable}"
COMPRESSION="${COMPRESSION:-fast}"
PAYLOAD_SEALED="${PAYLOAD_SEALED:-0}"

PAYLOAD_IMAGE="${PAYLOAD_REF:-$(cat "${TARGET}/payload_ref" | tr -d '[:space:]')}"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR=$(realpath "${OUTPUT_DIR}")
WORKDIR=$(realpath "${WORKDIR}")

echo "=== Disk space before squashfs assembly ==="
df -h "${OUTPUT_DIR}"

if ! findmnt -n -o FSTYPE -T "${WORKDIR}" 2>/dev/null | grep -qE '^(xfs|btrfs)$'; then
    echo "Hint: ${WORKDIR} is not an XFS/BTRFS mount.  For a faster squashfs root, mount one." >&2
fi

AVAILABLE_KB=$(df --output=avail -B1024 "${OUTPUT_DIR}" | tail -1 | tr -d ' ')
REQUIRED_KB=$((20 * 1024 * 1024))
if [ "${AVAILABLE_KB}" -lt "${REQUIRED_KB}" ]; then
    echo "WARNING: Only $(( AVAILABLE_KB / 1024 / 1024 ))GB free on $(df --output=target "${OUTPUT_DIR}" | tail -1) — ISO output needs ~5GB, full build needs more" >&2
fi
podman images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null || true

# podman unshare enters the user namespace for rootless builds.
# When running as root (CI with sudo) run directly.
if [[ $(id -u) -eq 0 ]]; then
    _ns() { bash -c "$1"; }
else
    _ns() { podman unshare bash -c "$1"; }
fi

SQUASHFS="${OUTPUT_DIR}/${TARGET}-rootfs.sfs"
BOOT_TAR="${OUTPUT_DIR}/${TARGET}-boot-files.tar"
# The embedded payload as an OCI image layout. It goes on the ISO 9660 tree at
# /OCI, grafted by live/src/build-iso.sh rather than copied, and NOT into the
# squashfs: fisherman only accepts a layout on a read-only filesystem (statfs
# ST_RDONLY on the directory and every blob), and the live root is an overlay
# whose upper layer is writable. dmsquash-live mounts the ISO itself read-only at
# /run/initramfs/live, so that is where the live system finds it.
OCI_LAYOUT="${OUTPUT_DIR}/${TARGET}-payload-layout"
OCI_LAYOUT_LIVE_PATH="/run/initramfs/live/OCI"
SQUASHFS_ROOT="${WORKDIR}/${TARGET}-sfs-root"
PAYLOAD_OCI="${OUTPUT_DIR}/${TARGET}-payload.oci.tar"

trap "rm -rf '${SQUASHFS}' '${BOOT_TAR}' '${PAYLOAD_OCI}' '${OCI_LAYOUT}' 2>/dev/null || true" EXIT

# Krytis is single-target and always composefs (#1247). The payload is embedded
# as an OCI layout plus /etc/bootc-installer/media-input.json, the receipt
# fisherman requires on live media since tuna-os/fisherman eecb1106 (#1479).
# verify-iso-payload checks both on the finished ISO.
echo "=== Building offline OCI layout for ${PAYLOAD_IMAGE} ==="

# Payload prep needs buildah + skopeo + python3. On hosts without buildah
# (e.g. immutable Krytis) set ISO_TOOLS_IMAGE to run the step inside the
# iso-tools container (see live/iso-tools/Containerfile); the whole
# from→copy→commit sequence runs in one `podman run` so the buildah working
# container survives across commands. Otherwise it runs on the host.
#
# Export the payload to an oci-archive on the host first, so payload-prep reads
# from a file under OUTPUT_DIR rather than the host containers-storage. This
# avoids bind-mounting /var/lib/containers/storage into the tools container —
# that path is wrong for rootless podman (storage lives under $HOME) and even
# when mounted the nested userns can't take the storage lock. The oci-archive
# transport works identically rootless and rootful.
PAYLOAD_INPUT="${OUTPUT_DIR}/${TARGET}-payload-input.oci.tar"
trap "rm -rf '${SQUASHFS}' '${BOOT_TAR}' '${PAYLOAD_OCI}' '${PAYLOAD_INPUT}' '${OCI_LAYOUT}' 2>/dev/null || true" EXIT
echo "=== Exporting ${PAYLOAD_IMAGE} to oci-archive for payload prep ==="
podman save --format oci-archive -o "${PAYLOAD_INPUT}" "${PAYLOAD_IMAGE}"
podman rmi "${PAYLOAD_IMAGE}" || true

if [[ "${PAYLOAD_SEALED}" == "1" ]]; then
    # Byte-identical embed — see live/iso-tools/payload-prep.sh for why a sealed
    # payload must not be re-committed. Aliasing avoids a ~7GB copy of the archive.
    echo "=== PAYLOAD_SEALED=1 — skipping payload prep, embedding ${PAYLOAD_IMAGE} as exported ==="
    PAYLOAD_OCI="${PAYLOAD_INPUT}"
else
    export PAYLOAD_IMAGE PAYLOAD_INPUT PAYLOAD_OCI OUTPUT_DIR PAYLOAD_SEALED
    if [[ -n "${ISO_TOOLS_IMAGE:-}" ]]; then
        echo "Running payload prep in iso-tools container: ${ISO_TOOLS_IMAGE}"
        # STORAGE_DRIVER=vfs: buildah's internal storage lives on the container's
        # overlayfs rootfs. Its default overlay driver cannot stack on overlayfs
        # without fuse-overlayfs ("'overlay' is not supported over overlayfs"); vfs
        # has no such constraint. Scoped to the container path — the host path uses
        # whatever the host buildah is configured for (overlay on rootful CI).
        podman run --rm --privileged --net=host \
            -v "${OUTPUT_DIR}:${OUTPUT_DIR}" \
            -v "${REPO_ROOT}/live/iso-tools/payload-prep.sh:/payload-prep.sh:ro" \
            -e PAYLOAD_IMAGE -e PAYLOAD_INPUT -e PAYLOAD_OCI -e OUTPUT_DIR \
            -e PAYLOAD_SEALED \
            -e STORAGE_DRIVER=vfs \
            "${ISO_TOOLS_IMAGE}" bash /payload-prep.sh
    else
        _ns "bash '${REPO_ROOT}/live/iso-tools/payload-prep.sh'"
    fi

    # Sealed runs alias PAYLOAD_OCI at PAYLOAD_INPUT, so removing the input here
    # would delete the archive before _ns_build_squashfs converts it. The EXIT trap
    # (set above, fires after the conversion) cleans it up either way.
    rm -f "${PAYLOAD_INPUT}"
fi

# ── Squashfs assembly (runs in user namespace for rootless UID mapping) ───────
#
# All variables needed inside _ns are passed via the outer scope — no string
# interpolation of shell vars into the bash -c argument. Instead we export them
# and the inner bash inherits them directly.
export OUTPUT_DIR WORKDIR TARGET PAYLOAD_IMAGE COMPRESSION
export SQUASHFS_ROOT SQUASHFS BOOT_TAR PAYLOAD_OCI OCI_LAYOUT OCI_LAYOUT_LIVE_PATH

_ns_build_squashfs() {
    set -euo pipefail

    echo "=== Disk space inside _ns block ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"

    OVERLAY_UPPER=$(mktemp -d "${SQUASHFS_ROOT}_upper_XXXXXX")
    OVERLAY_WORK=$(mktemp -d "${SQUASHFS_ROOT}_work_XXXXXX")

    ns_cleanup() {
        umount "${SQUASHFS_ROOT}" 2>/dev/null || true
        podman image unmount "localhost/${TARGET}-installer" 2>/dev/null || true
        rm -rf "${OVERLAY_UPPER}" "${OVERLAY_WORK}" 2>/dev/null || true
        rm -rf "${SQUASHFS_ROOT}" 2>/dev/null || true
    }
    trap ns_cleanup EXIT

    MOUNT=$(podman image mount "localhost/${TARGET}-installer")
    PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH

    echo "=== Disk space before OCI layout conversion ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"

    # oci-archive → OCI layout. podman save writes uncompressed layers, which
    # would put ~7GB of raw tar on the ISO; gzip them, as the registry copy is.
    # Recompression changes the layer digests but not the diff_ids or the config,
    # so the image ID and the sealed UKI's composefs digest (computed over the
    # uncompressed rootfs) are unchanged. gzip rather than zstd: it is what every
    # `bootc upgrade` from ghcr.io already decodes. skopeo comes from the live
    # installer image, as the old VFS import did, so the host needs none.
    rm -rf "${OCI_LAYOUT}"
    mkdir -p "${OCI_LAYOUT}"
    echo 'Converting the payload to a gzip OCI layout...'
    podman run --rm \
        --privileged \
        -v "${PAYLOAD_OCI}:/payload.oci.tar:ro" \
        -v "${OCI_LAYOUT}:/layout" \
        "localhost/${TARGET}-installer" \
        sh -c "mkdir -p /var/tmp && skopeo copy --dest-compress --dest-compress-format gzip oci-archive:/payload.oci.tar:${PAYLOAD_IMAGE} oci:/layout:${PAYLOAD_IMAGE}"
    rm -f "${PAYLOAD_OCI}"

    echo "=== Disk space after OCI layout conversion ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"
    du -sh "${OCI_LAYOUT}" 2>/dev/null || true

    echo 'Building unified squashfs source tree using bind mounts...'
    mkdir -p "${SQUASHFS_ROOT}"

    FS_TYPE=$(findmnt -n -o FSTYPE -T "${SQUASHFS_ROOT}" 2>/dev/null || echo "unknown")
    if [[ "${FS_TYPE}" == "xfs" || "${FS_TYPE}" == "ext4" ]]; then
        echo "Filesystem is ${FS_TYPE}, trying overlay"
        if ! mount -t overlay overlay \
                -o lowerdir="${MOUNT}",upperdir="${OVERLAY_UPPER}",workdir="${OVERLAY_WORK}" \
                "${SQUASHFS_ROOT}"; then
            echo "Overlay mount failed on ${FS_TYPE}; falling back to cp -a"
            cp -a "${MOUNT}/." "${SQUASHFS_ROOT}/"
        fi
    else
        echo "Filesystem is ${FS_TYPE}, doing it the boring way"
        cp -a "${MOUNT}/." "${SQUASHFS_ROOT}/"
    fi

    # The receipt fisherman binds the install to (tuna-os/fisherman
    # internal/install/mediainput.go, MediaInput v1). It names the layout's
    # live path and pins its platform manifest and config digests, which are
    # only known now, after the conversion above, so it is written into the
    # live root here rather than by configure-live-krytis.sh. image and
    # targetImgref are both PAYLOAD_IMAGE: recipe.json's image must equal
    # `image`, and `targetImgref` is what the installed system follows on
    # `bootc upgrade`.
    mkdir -p "${SQUASHFS_ROOT}/etc/bootc-installer"
    python3 - "${OCI_LAYOUT}" "${PAYLOAD_IMAGE}" "${OCI_LAYOUT_LIVE_PATH}" \
        > "${SQUASHFS_ROOT}/etc/bootc-installer/media-input.json" <<'PY'
import json, sys
layout, image, live_path = sys.argv[1:]
with open(f"{layout}/index.json") as f:
    manifests = json.load(f)["manifests"]
if len(manifests) != 1:
    sys.exit(f"expected one manifest in {layout}/index.json, found {len(manifests)}")
digest = manifests[0]["digest"]
with open(f"{layout}/blobs/{digest.replace(':', '/', 1)}") as f:
    config = json.load(f)["config"]["digest"]
json.dump({
    "schemaVersion": 1,
    "kind": "krytis-live",
    "image": image,
    "platformManifestDigest": digest,
    "indexDigest": "",
    "configDigest": config,
    "ociLayoutPath": live_path,
    "targetImgref": image,
    "platform": "linux/amd64",
    "catalogVersion": "",
    "qualificationID": "",
}, sys.stdout, indent=2)
print()
PY
    cat "${SQUASHFS_ROOT}/etc/bootc-installer/media-input.json"

    echo "=== Disk space after creation of squashfs root ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"
    du -sh "${SQUASHFS_ROOT}" 2>/dev/null || true

    mkdir -p "${SQUASHFS_ROOT}/proc" "${SQUASHFS_ROOT}/sys" "${SQUASHFS_ROOT}/dev"
    SFS_LEVEL=3; SFS_BLOCK=131072
    [[ "${COMPRESSION}" == "release" ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
    mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS}" \
        -noappend -comp zstd -Xcompression-level "${SFS_LEVEL}" -b "${SFS_BLOCK}" \
        -processors 4 \
        -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e run -e tmp

    tar -C "${MOUNT}" \
        -cf "${BOOT_TAR}" \
        ./usr/lib/modules \
        ./usr/lib/systemd/boot/efi
}
export -f _ns_build_squashfs

if [[ $(id -u) -eq 0 ]]; then
    bash -c '_ns_build_squashfs'
else
    podman unshare bash -c '_ns_build_squashfs'
fi

echo "=== Disk space after squashfs, before ISO assembly ==="
df -h "${OUTPUT_DIR}"
du -sh "${SQUASHFS}" "${BOOT_TAR}" 2>/dev/null || true

LIVE_TITLE=$(cat "${TARGET}/live_title" 2>/dev/null || echo 'Krytis Live')
LIVE_LABEL=$(cat "${TARGET}/live_label" 2>/dev/null | tr -d '[:space:]' || echo 'KRYTIS_LIVE')

# xorriso/implantisomd5 have no freedesktop-sdk component. When ISO_TOOLS_IMAGE
# is set (immutable host), route just those two binaries through the container;
# mtools/dosfstools/truncate/tar still run on the host. OUTPUT_DIR is mounted at
# the same path so the WORK tmpdir (TMPDIR=OUTPUT_DIR) and OUTPUT_ISO resolve.
XORRISO="xorriso"
IMPLANTISOMD5="implantisomd5"
if [[ -n "${ISO_TOOLS_IMAGE:-}" ]]; then
    XORRISO="podman run --rm -v ${OUTPUT_DIR}:${OUTPUT_DIR} -w ${OUTPUT_DIR} ${ISO_TOOLS_IMAGE} xorriso"
    IMPLANTISOMD5="podman run --rm -v ${OUTPUT_DIR}:${OUTPUT_DIR} -w ${OUTPUT_DIR} ${ISO_TOOLS_IMAGE} implantisomd5"
fi

TMPDIR="${OUTPUT_DIR}" \
XORRISO="${XORRISO}" \
IMPLANTISOMD5="${IMPLANTISOMD5}" \
PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
    bash "live/src/build-iso.sh" \
        --title "${LIVE_TITLE}" \
        --label "${LIVE_LABEL}" \
        --oci-layout "${OCI_LAYOUT}" \
        "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/${TARGET}-live.iso"

echo "ISO ready: ${OUTPUT_DIR}/${TARGET}-live.iso"
