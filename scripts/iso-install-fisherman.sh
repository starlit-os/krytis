#!/usr/bin/bash
# scripts/iso-install-fisherman.sh
# Run a fisherman composefs install via SSH into the live QEMU session.
#
# PAYLOAD_REF (env, optional) overrides <target>/payload_ref, matching
# scripts/iso-sd-boot.sh. It must equal the `image` of the ISO's
# /etc/bootc-installer/media-input.json: on live media fisherman refuses any
# other source (#1479), so the script checks it up front.
#
# LUKS_PASSPHRASE (env, optional) installs to an ENCRYPTED root instead,
# by emitting an "encryption": {"type": "luks-passphrase"} recipe block.
# Callers that then want to BOOT the result need to answer a passphrase
# prompt — see mise/tasks/luks-install-test.
#
# LUKS_ENCRYPTION_TYPE (env, optional, needs LUKS_PASSPHRASE) picks the
# encryption type: luks-passphrase (default) or tpm2-luks-passphrase, which is
# what the GUI installer writes on any machine with a TPM 2.0 (#1276) — see
# mise/tasks/tpm-install-test.
#
# sshpass and socat are used when present and transparently substituted
# when not — see scripts/e2e-lib.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/e2e-lib.sh
source "${SCRIPT_DIR}/e2e-lib.sh"

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <target> <ssh_port> <monitor_live_socket>" >&2
    exit 1
fi

TARGET="$1"
SSH_PORT="$2"
MONITOR_LIVE="$3"

DISK="/dev/vda"
PAYLOAD_IMAGE="${PAYLOAD_REF:-$(cat "${TARGET}/payload_ref" | tr -d '[:space:]')}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=password -o ServerAliveInterval=30 -o ServerAliveCountMax=20"
e2e_ssh_auth_init live
SSH="${E2E_SSH_WRAP} ssh $SSH_OPTS ${E2E_SSH_AUTH_OPTS} liveuser@127.0.0.1 -p ${SSH_PORT}"
SCP="${E2E_SSH_WRAP} scp $SSH_OPTS ${E2E_SSH_AUTH_OPTS} -P ${SSH_PORT}"

# The live ISO carries /etc/bootc-installer/live-iso-mode, so fisherman requires
# media-input.json and installs from its OCI layout or not at all; there is no
# network fallback to take. Fail here, with the two refs side by side, rather
# than on fisherman's "requested image … does not match embedded source".
MEDIA_IMAGE=$($SSH "python3 -c 'import json; print(json.load(open(\"/etc/bootc-installer/media-input.json\"))[\"image\"])'" 2>/dev/null) || {
    echo "ERROR: the live session has no readable /etc/bootc-installer/media-input.json." >&2
    echo "       The ISO predates the OCI-layout payload (#1479); rebuild it with mise run build-iso." >&2
    exit 1
}
if [[ "${MEDIA_IMAGE}" != "${PAYLOAD_IMAGE}" ]]; then
    echo "ERROR: the ISO embeds ${MEDIA_IMAGE}, but this run asks fisherman for ${PAYLOAD_IMAGE}." >&2
    echo "       Pass --payload-ref ${MEDIA_IMAGE}, or rebuild the ISO for ${PAYLOAD_IMAGE}." >&2
    exit 1
fi
INSTALL_IMAGE="${PAYLOAD_IMAGE}"
echo "Installing ${INSTALL_IMAGE} from the ISO's embedded OCI layout (media-input.json)."

# Constants, matching the GUI recipe baked by live/src/configure-live-krytis.sh
# (bootloader "systemd", composeFsBackend true). The live_target/bootloader
# file indirection inherited from dakota-iso was removed in #1247.
BOOTLOADER="systemd"

FILESYSTEM="btrfs"

RECIPE_TMP=$(mktemp /tmp/krytis-recipe-XXXXXX.json)
e2e_cleanup_add "${RECIPE_TMP}"

# json-escape via python so a passphrase is safe regardless of content.
ENCRYPTION_TYPE="${LUKS_ENCRYPTION_TYPE:-luks-passphrase}"
case "${ENCRYPTION_TYPE}" in
    luks-passphrase|tpm2-luks-passphrase) ;;
    *) echo "ERROR: LUKS_ENCRYPTION_TYPE=${ENCRYPTION_TYPE}; want luks-passphrase or tpm2-luks-passphrase" >&2; exit 1 ;;
esac
if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
    ENCRYPTION=$(LUKS_PASSPHRASE="${LUKS_PASSPHRASE}" ENCRYPTION_TYPE="${ENCRYPTION_TYPE}" python3 -c \
        'import json,os; print(json.dumps({"type":os.environ["ENCRYPTION_TYPE"],"passphrase":os.environ["LUKS_PASSPHRASE"]}))')
    HOSTNAME_KEY="krytis-luks-test"
    echo "Encryption: ${ENCRYPTION_TYPE} (root will be a LUKS2 container)"
elif [[ -n "${LUKS_ENCRYPTION_TYPE:-}" ]]; then
    echo "ERROR: LUKS_ENCRYPTION_TYPE=${LUKS_ENCRYPTION_TYPE} needs LUKS_PASSPHRASE" >&2
    exit 1
else
    ENCRYPTION='{"type": "none"}'
    HOSTNAME_KEY="krytis-plain-test"
fi

echo "Mounting scratch disk (/dev/vdb) over /var/tmp..."
$SSH 'sudo bash -c "
    mkfs.ext4 -F /dev/vdb >/dev/null
    umount /var/tmp 2>/dev/null || true
    mount /dev/vdb /var/tmp
    echo \"/var/tmp is now disk-backed on /dev/vdb\"
"'

printf '{\n  "disk": "%s",\n  "filesystem": "%s",\n  "image": "%s",\n  "composeFsBackend": true,\n  "bootloader": "%s",\n  "hostname": "%s",\n  "encryption": %s,\n  "flatpaks": []\n}\n' \
    "${DISK}" "${FILESYSTEM}" "${INSTALL_IMAGE}" "${BOOTLOADER}" "${HOSTNAME_KEY}" "${ENCRYPTION}" > "${RECIPE_TMP}"
$SCP "${RECIPE_TMP}" liveuser@127.0.0.1:/tmp/krytis-recipe.json
echo "Uploaded recipe — running fisherman (this takes several minutes)..."
# Straight into fisherman. This used to go through scripts/fisherman-install.sh,
# a wrapper that re-mounted the installed root to finish a hostname write
# fisherman aborted on composefs sysroots (it resolved the deployment with
# `ostree admin --print-current-dir` against the *running* system, after
# unmounting the target). fisherman's post.WriteHostname now resolves the
# composefs deploy etc from the BLS entry's composefs=<hash>, so the write
# lands on the first try. The wrapper's only other action was a systemd
# override for Universal Blue's rechunker-group-fix.service, which krytis has
# never shipped — it looked for the deployment under ostree/{bootc/,}deploy,
# found nothing in krytis's state/deploy layout, and printed a warning instead
# of patching anything, on every single run.
$SSH 'sudo /usr/local/bin/fisherman /tmp/krytis-recipe.json'

echo "Patching BLS entries to add serial console..."
$SSH "sudo bash -c \"
    set -euo pipefail
    BOOT_PART=\\\"/dev/vda1\\\"
    if ls /dev/vda3 >/dev/null 2>&1; then
        echo \\\"Detected 3 partitions layout (separate boot partition for GRUB)\\\"
        BOOT_PART=\\\"/dev/vda2\\\"
    fi
    TMP=\\\$(mktemp -d)
    trap \\\"umount \\\$TMP 2>/dev/null || true; rmdir \\\$TMP\\\" EXIT
    mount \\\"\\\$BOOT_PART\\\" \\\$TMP
    COUNT=0
    for entry in \\\$TMP/loader/entries/*.conf \\\$TMP/EFI/loader/entries/*.conf; do
        [[  -f \\\"\\\$entry\\\" ]] || continue
        echo \\\"=== BLS entry before patch: \\\$(basename \\\$entry) ===\\\"
        cat \\\"\\\$entry\\\"
        if grep -q \\\"^options \\\" \\\"\\\$entry\\\" && ! grep -q \\\"console=tty0\\\" \\\"\\\$entry\\\"; then
            sed -i \\\"s|^options .*|& console=tty0 console=ttyS0 rd.info systemd.journald.forward_to_console=yes|\\\" \\\"\\\$entry\\\"
            COUNT=\\\$((COUNT+1))
        fi
        echo \\\"=== BLS entry after patch ===\\\"
        cat \\\"\\\$entry\\\"
    done
    echo \\\"BLS patch: \\\$COUNT entries updated\\\"
\""

echo "Install complete. Shutting down live QEMU..."
e2e_monitor "${MONITOR_LIVE}" system_powerdown
sleep 5
e2e_monitor "${MONITOR_LIVE}" quit
