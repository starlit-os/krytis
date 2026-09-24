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
# podman. podman was unused by cache-warm.yml (the only workflow this box
# ran) when first installed for parity against a future publish.yml
# migration; build-iso.yml (#844) is that future arriving — mksquashfs,
# mtools, dosfstools and rclone are the additional host tools it needs
# that no workflow on this box required before:
#   - squashfs-tools: mksquashfs, run on the host inside `podman unshare`/
#     as root, never inside a container (iso-sd-boot.sh's
#     _ns_build_squashfs).
#   - dosfstools + mtools: mkfs.fat + mcopy/mmd, used by
#     live/src/build-iso.sh to assemble the FAT ESP image without a loop
#     mount (unprivileged-container-friendly).
#   - rclone: uploads the sealed ISO to Cloudflare R2 over the
#     S3-compatible API (#867), on build-iso.yml's `publish_r2` path only.
#     Credentials never reach this box's disk — the workflow passes them as
#     RCLONE_CONFIG_* environment variables scoped to that single step, so
#     there is no rclone.conf to provision, protect, or rotate here.
#     Unpinned, but not floorless, unlike the rest of this list: the
#     `provider = Cloudflare` value the workflow sets arrived in rclone
#     v1.59.0 (2022-07-09, "New S3 providers"). Trixie ships 1.60.1, which
#     clears it. If this box is ever rebuilt on an older base, check that
#     first — an unsupported provider value degrades to generic-S3
#     behaviour rather than failing loudly.
# xorriso/implantisomd5 are deliberately NOT installed here — build-iso.yml
# routes both through the iso-tools container it builds itself
# (ISO_TOOLS_IMAGE), so the host never needs them.
# nftables is required, not optional, despite apt only listing it as a
# netavark Recommends: --no-install-recommends never pulls it in on its
# own, but netavark (podman's default rootful network backend on Debian)
# has dropped iptables support and defaults to the nftables firewall
# driver, so the `nft` binary has to be present explicitly. Without it even
# a plain `podman run --privileged` with no custom network fails at
# CNI/netavark setup:
#   Error: netavark: nftables error: unable to execute nft: No such file or
#   directory (os error 2)
# (see docs/skills/ci-runner.md, issue #882).
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
    podman \
    nftables \
    squashfs-tools \
    mtools \
    dosfstools \
    rclone

# Swap: Contabo's Debian image ships none at all, which turns any RAM spike
# into an immediate kernel OOM kill rather than a slowdown. That is not
# hypothetical — the runner unit was OOM-killed twice inside 24h (2026-09-11
# 11.4G peak, 2026-09-12 11.1G peak, both against 11GiB total), taking the
# runner offline for 18h the first time. cache-warm.yml now bounds build
# concurrency to fit in RAM; this is the backstop for whatever that estimate
# misses. Sized at 8G — the box has ~130G free and swap it never touches
# costs nothing. Idempotent: re-running install must not corrupt live swap.
SWAPFILE=/swapfile
if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${SWAPFILE}"; then
    if [ ! -f "${SWAPFILE}" ]; then
        echo "==> Creating 8G ${SWAPFILE}..."
        fallocate -l 8G "${SWAPFILE}"
        chmod 600 "${SWAPFILE}"
        mkswap "${SWAPFILE}" >/dev/null
    fi
    echo "==> Enabling ${SWAPFILE}..."
    swapon "${SWAPFILE}"
else
    echo "==> ${SWAPFILE} already active — skipping."
fi
if ! grep -qs "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
fi

# Swap is emergency headroom for a build box, not a paging tier to live in:
# the default swappiness of 60 would push a long build's working set out to
# disk and slow every run down. 10 keeps it reserved for real pressure.
if [ "$(cat /proc/sys/vm/swappiness)" != "10" ]; then
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-krytis-runner-swappiness.conf
    sysctl -q -w vm.swappiness=10
fi

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
