#!/usr/bin/bash
# scripts/iso-install-fisherman.sh
# Run a fisherman composefs install via SSH into the live QEMU session.
#
# PAYLOAD_REF (env, optional) overrides <target>/payload_ref, matching
# scripts/iso-sd-boot.sh — the recipe must name the ref the ISO actually
# embedded or the offline containers-storage lookup misses and fisherman
# falls back to a network pull.
#
# LUKS_PASSPHRASE (env, optional) installs to an ENCRYPTED root instead,
# by emitting an "encryption": {"type": "luks-passphrase"} recipe block.
# Callers that then want to BOOT the result need to answer a passphrase
# prompt — see mise/tasks/luks-install-test.
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

if $SSH "sudo podman image exists '${PAYLOAD_IMAGE}' 2>/dev/null"; then
    INSTALL_IMAGE="containers-storage:${PAYLOAD_IMAGE}"
    echo "Image found in local containers-storage — using offline install."
else
    INSTALL_IMAGE="docker://${PAYLOAD_IMAGE}"
    echo "Image not in local store — fisherman will pull from network."
fi

LIVE_TARGET=$(cat "${TARGET}/live_target" 2>/dev/null | tr -d '[:space:]' || echo "${TARGET}")
BOOTLOADER_VARIANT=$(echo "$LIVE_TARGET" | sed 's/-nvidia-open$//;s/-nvidia$//')
BOOTLOADER=$(cat "live/src/${BOOTLOADER_VARIANT}/bootloader" 2>/dev/null | tr -d '[:space:]' || echo "systemd")
if [[ "${BOOTLOADER}" == "grub" ]]; then BOOTLOADER="grub2"; fi

FILESYSTEM="btrfs"

RECIPE_TMP=$(mktemp /tmp/krytis-recipe-XXXXXX.json)
e2e_cleanup_add "${RECIPE_TMP}"

# json-escape via python so a passphrase is safe regardless of content.
if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
    ENCRYPTION=$(LUKS_PASSPHRASE="${LUKS_PASSPHRASE}" python3 -c \
        'import json,os; print(json.dumps({"type":"luks-passphrase","passphrase":os.environ["LUKS_PASSPHRASE"]}))')
    HOSTNAME_KEY="krytis-luks-test"
    echo "Encryption: LUKS passphrase (root will be a LUKS2 container)"
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
