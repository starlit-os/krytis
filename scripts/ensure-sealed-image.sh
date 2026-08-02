#!/usr/bin/env bash
# ensure-sealed-image.sh — guarantee localhost/krytis:sealed exists and is no
# older than localhost/krytis:latest, re-running `mise run seal-uki` if not.
#
# --squash-all erases parent/layer provenance, so `.Created` is the only usable
# content-identity proxy: podman build is content-addressed, so rebuilding
# :latest from byte-identical inputs reuses the image ID *and* its original
# Created timestamp. Only a genuine content change produces a fresh one. See
# docs/skills/secure-boot.md § `--squash-all` erases parent/layer provenance.
#
# Scope note: tracks :latest's content only, not signing-key freshness —
# rotating files/boot-keys/ without another content change will not re-seal.
#
# Callers: mise/tasks/push --sealed, mise/tasks/build-iso --sealed. Run from the
# repo root (it invokes ./mise/tasks/seal-uki).
#
# With an image ref as $1, the freshness half is skipped and that image is only
# checked for being a genuine sealed build. Building an ISO around an image
# somebody else produced — the published one, for release validation — has no
# local :latest to be "no older than", and re-sealing would defeat the point.
set -euo pipefail

SEALED_TAG="${1:-localhost/krytis:sealed}"
LATEST_TAG="localhost/krytis:latest"
EXPLICIT=$([[ -n "${1:-}" ]] && echo 1 || echo 0)

if [[ "${EXPLICIT}" -eq 1 ]]; then
    podman image exists "${SEALED_TAG}" || {
        echo "==> ERROR: ${SEALED_TAG} not found locally — pull it first" >&2
        exit 1
    }
elif ! podman image exists "${LATEST_TAG}"; then
    echo "==> ERROR: ${LATEST_TAG} not found locally — run mise build first (needed as the freshness reference for the sealed image)" >&2
    exit 1
fi

# `podman inspect --format '{{.Created}}'` renders Go's time.String(), e.g.
# "2026-08-02 16:21:14.125718274 +0000 UTC". GNU date rejects that trailing
# " UTC" outright ("date: invalid date"), which killed publish run 30754171738
# after 20 minutes. It parses fine on this project's usual workstation because
# CachyOS ships uutils coreutils as /usr/bin/date, and uutils is more permissive
# than GNU — so the bug is invisible to any amount of local testing here. See
# docs/skills/mise.md § uutils vs GNU coreutils.
#
# `--format json` is the stable interface: Go marshals time.Time as RFC3339Nano
# regardless of podman version, and both date implementations agree on it.
created_epoch() {
    podman inspect --format json "$1" | python3 -c '
import json, re, sys
from datetime import datetime
created = json.load(sys.stdin)[0]["Created"]
# podman emits 9 fractional digits; fromisoformat before 3.11 accepts only 3 or 6
created = re.sub(r"(\.\d{6})\d+", r"\1", created).replace("Z", "+00:00")
print(int(datetime.fromisoformat(created).timestamp()))
'
}

if [[ "${EXPLICIT}" -eq 0 ]]; then
    LATEST_CREATED=$(created_epoch "${LATEST_TAG}")
    if podman image exists "${SEALED_TAG}"; then
        SEALED_CREATED=$(created_epoch "${SEALED_TAG}")
    else
        SEALED_CREATED=0
    fi

    if [[ "${SEALED_CREATED}" -lt "${LATEST_CREATED}" ]]; then
        echo "==> ${SEALED_TAG} is missing or older than ${LATEST_TAG} — running mise run seal-uki..."
        ./mise/tasks/seal-uki
    fi

    if ! podman image exists "${SEALED_TAG}"; then
        echo "==> ERROR: ${SEALED_TAG} still missing after seal-uki" >&2
        exit 1
    fi
fi

# The tag existing is not proof it is sealed — a hand-tagged or half-built image
# would otherwise be pushed, or embedded in an ISO, as "the signed one" and only
# surface as a firmware rejection much later. The UKI is the one artifact only the
# sealed build produces. Same guard boot-test applies before an enforcing boot.
if ! podman run --rm "${SEALED_TAG}" sh -c '[ -f /boot/EFI/Linux/krytis.efi ]' 2>/dev/null; then
    echo "==> ERROR: ${SEALED_TAG} has no /boot/EFI/Linux/krytis.efi — that is not a sealed build." >&2
    echo "    Rebuild it:  mise run seal-uki" >&2
    exit 1
fi
