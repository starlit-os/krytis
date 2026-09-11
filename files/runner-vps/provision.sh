#!/usr/bin/env bash
# Provisions OS packages and the actions-runner binary on the always-on
# Debian CI VPS (issue #794). Copied to the box and run by
# `mise runner-vps:install` — see mise/tasks/runner-vps/install.
#
# Unlike Containerfile.runner (a privileged Podman container isolating the
# runner on a shared local dev workstation), this installs directly on a
# dedicated, single-purpose VM: the VM itself is the isolation boundary, so
# there's no container layer to build or maintain. Runs as root — the VM has
# no other tenant, matching the design note in issue #794.
set -euo pipefail

RUNNER_VERSION="${1:?usage: provision.sh <runner-version>}"
RUNNER_HOME="/opt/actions-runner"

echo "==> apt-get update..."
apt-get update -qq

# Same package set as Containerfile.runner's apt list (bubblewrap + BST's
# native-dep set from mise.toml's [bootstrap.packages] apt: entries), plus
# podman. podman is not used by cache-warm.yml today (it only runs
# `bst build`) — installed anyway per issue #794 so this box has parity for
# a future publish.yml migration, which is explicitly out of scope here.
# Deliberately NOT pinned to 4.9.3: docs/skills/ci-runner.md's own
# 2026-08-12 follow-up (docs/plans/done/2026-08-12-verify-baked-composefs-digest.md)
# found 4.9.3 and 5.8.2 both produce byte-identical, correctly-booting sealed
# images once `verify-composefs-digest` checks the digest directly — the
# version-pinning premise issue #794 cites (#524) was itself reverted by
# #527. Whatever Debian trixie's apt carries is fine.
apt-get install -y -qq --no-install-recommends \
    bubblewrap \
    bzip2 \
    gzip \
    lzip \
    xz-utils \
    patch \
    curl \
    git \
    ca-certificates \
    jq \
    sudo \
    podman

mkdir -p "${RUNNER_HOME}"
cd "${RUNNER_HOME}"

if [ ! -x ./config.sh ]; then
    echo "==> Downloading actions-runner v${RUNNER_VERSION}..."
    curl -fsSL -o /tmp/actions-runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar xzf /tmp/actions-runner.tar.gz -C "${RUNNER_HOME}"
    rm /tmp/actions-runner.tar.gz

    echo "==> Installing runner's own dependencies (.NET runtime, libicu, ...)..."
    ./bin/installdependencies.sh
else
    echo "==> ${RUNNER_HOME}/config.sh already present — skipping download."
fi

# The runner refuses to start as root without this. Written into .env (not
# just exported here) because runsvc.sh — the script the systemd service
# installed by svc.sh actually execs — sources .env itself; an export in
# this script's shell would not reach that later, separate process tree.
if ! grep -qxF 'RUNNER_ALLOW_RUNASROOT=1' .env 2>/dev/null; then
    echo 'RUNNER_ALLOW_RUNASROOT=1' >> .env
fi

echo "==> Provisioning complete. Run 'mise runner-vps:register' next."
