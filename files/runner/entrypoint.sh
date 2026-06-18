#!/usr/bin/env bash
set -euo pipefail

cd /home/runner

# Fine-grained PAT: Administration Read+Write on starlit-os/krytis.
# Used only to obtain a removal token for deregistration on exit.
GH_TOKEN=$(cat /run/secrets/gh-token)

# Derive org/repo from REPO_URL for the deregistration API call.
REPO_PATH="${REPO_URL#https://github.com/}"

./config.sh \
    --url "${REPO_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME:-krytis-local}" \
    --labels "${RUNNER_LABELS:-self-hosted,linux,x64}" \
    --work "_work" \
    --unattended \
    --no-default-labels

cleanup() {
    echo "==> Runner shutting down, deregistering..."
    REMOVE_TOKEN=$(curl -fsSL \
        -X POST \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${REPO_PATH}/actions/runners/remove-token" \
        | jq -r .token)
    ./config.sh remove --token "${REMOVE_TOKEN}" --unattended
    echo "==> Deregistered."
}
trap cleanup EXIT

./run.sh
