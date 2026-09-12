#!/usr/bin/env bash
# runner-vps-host.sh — resolve the always-on CI VPS's ssh destination (#794).
#
# Source it; it exports RUNNER_VPS_HOST and defines ssh_vps/scp_vps:
#
#     . scripts/runner-vps-host.sh
#     ssh_vps "systemctl is-active actions.runner.*"
#
# Resolution order, first hit wins:
#
#   1. RUNNER_VPS_HOST already in the environment (.mise.local.toml, or an
#      ad-hoc override when talking to a replacement box before the vault
#      entry is updated).
#   2. fnox, joining the Krytis vault item "Krytis Build VPS"'s Username and
#      IP Address fields (fnox.toml's RUNNER_VPS_USER / RUNNER_VPS_IP).
#
# Step 2 exists because step 1 alone made the tasks unrunnable on any machine
# whose gitignored .mise.local.toml had not been hand-populated — which is how
# a 2026-09-12 runner outage went undiagnosed: the box was up and reachable the
# whole time, but nothing in the checkout knew its address. The vault already
# held it. See docs/skills/ci-runner.md § Always-on VPS runner.

if [ -z "${RUNNER_VPS_HOST:-}" ]; then
    if ! command -v fnox >/dev/null 2>&1 || [ ! -f fnox.toml ]; then
        echo "ERROR: RUNNER_VPS_HOST is unset and fnox is not usable here." >&2
        echo "  Run from the repo root (fnox.toml must be visible), or set" >&2
        echo "  RUNNER_VPS_HOST=user@host explicitly." >&2
        return 1 2>/dev/null || exit 1
    fi

    # One `fnox get` per field: the Proton Pass item keeps user and address
    # apart, and fnox has no template provider to join them vault-side.
    _vps_user=$(fnox get RUNNER_VPS_USER) || {
        echo "ERROR: fnox get RUNNER_VPS_USER failed — check 'pass-cli login' state." >&2
        return 1 2>/dev/null || exit 1
    }
    _vps_ip=$(fnox get RUNNER_VPS_IP) || {
        echo "ERROR: fnox get RUNNER_VPS_IP failed — check 'pass-cli login' state." >&2
        return 1 2>/dev/null || exit 1
    }
    if [ -z "${_vps_user}" ] || [ -z "${_vps_ip}" ]; then
        echo "ERROR: vault item 'Krytis Build VPS' returned an empty Username or IP Address." >&2
        return 1 2>/dev/null || exit 1
    fi

    RUNNER_VPS_HOST="${_vps_user}@${_vps_ip}"
    unset _vps_user _vps_ip
fi
export RUNNER_VPS_HOST

RUNNER_VPS_SSH_KEY="${RUNNER_VPS_SSH_KEY:-${HOME}/.ssh/id_ed25519_sk_rk_KrytisBuild}"
export RUNNER_VPS_SSH_KEY

# SSH_AUTH_SOCK/IdentityAgent are stripped so the FIDO2 resident key is used
# directly rather than whatever the agent happens to offer first — the box
# authorises exactly this credential.
ssh_vps() {
    env -u SSH_AUTH_SOCK ssh -i "${RUNNER_VPS_SSH_KEY}" \
        -o IdentitiesOnly=yes -o IdentityAgent=none "${RUNNER_VPS_HOST}" "$@"
}

scp_vps() {
    env -u SSH_AUTH_SOCK scp -i "${RUNNER_VPS_SSH_KEY}" \
        -o IdentitiesOnly=yes -o IdentityAgent=none "$@"
}
