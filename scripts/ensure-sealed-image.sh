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
set -euo pipefail

SEALED_TAG="localhost/krytis:sealed"
LATEST_TAG="localhost/krytis:latest"

if ! podman image exists "${LATEST_TAG}"; then
    echo "==> ERROR: ${LATEST_TAG} not found locally — run mise build first (needed as the freshness reference for the sealed image)" >&2
    exit 1
fi

LATEST_CREATED=$(date -d "$(podman inspect "${LATEST_TAG}" --format '{{.Created}}')" +%s)
if podman image exists "${SEALED_TAG}"; then
    SEALED_CREATED=$(date -d "$(podman inspect "${SEALED_TAG}" --format '{{.Created}}')" +%s)
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
