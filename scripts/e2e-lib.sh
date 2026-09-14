#!/usr/bin/bash
# scripts/e2e-lib.sh — host-portability helpers for the QEMU E2E gate.
#
# Source this, do not execute it:
#     source "${REPO_ROOT}/scripts/e2e-lib.sh"
#
# The gate historically hard-required two host binaries that a bootc host does
# not ship and cannot install (no dnf, no apt — StarlitOS Krytis is the machine
# the sealed gate runs on, and it is the same reason iso-sd-boot.sh grew the
# ISO_TOOLS_IMAGE path):
#
#   sshpass — feeds the live session's password to ssh/scp
#   socat   — talks HMP on QEMU's monitor unix socket
#
# Both are still used when installed, so an Ubuntu CI host keeps its exact
# current behaviour; the fallbacks engage only when the binary is missing and
# need nothing beyond OpenSSH >= 8.4 and python3.

# ── Deferred cleanup ─────────────────────────────────────────────────────────
# One EXIT trap, owned here. Callers register work instead of installing their
# own EXIT trap, which would silently replace this one (and leak the askpass
# shim, which holds the live password).
_E2E_EXIT_CMDS=()

_e2e_cleanup() {
    local c
    for c in "${_E2E_EXIT_CMDS[@]}"; do
        eval "${c}" || true
    done
    return 0
}

# e2e_on_exit <command string> — run at exit, in registration order.
e2e_on_exit() {
    if [[ ${#_E2E_EXIT_CMDS[@]} -eq 0 ]]; then
        trap _e2e_cleanup EXIT
    fi
    _E2E_EXIT_CMDS+=("$1")
}

# e2e_cleanup_add <path>... — remove these at exit.
e2e_cleanup_add() {
    local p
    for p in "$@"; do
        e2e_on_exit "rm -rf -- '${p}'"
    done
}

# ── Non-interactive password auth for ssh/scp ────────────────────────────────
# Sets, for the caller to interpolate:
#   E2E_SSH_WRAP      — command prefix ("sshpass -p live", or empty)
#   E2E_SSH_AUTH_OPTS — extra ssh/scp -o flags the chosen mechanism needs
#
# The fallback is OpenSSH's own askpass hook. SSH_ASKPASS_REQUIRE=force (OpenSSH
# 8.4+) makes ssh call SSH_ASKPASS even when it has a controlling terminal, which
# is what removes the need for sshpass' PTY trickery. The shim is written into a
# private mkdtemp and removed on exit — it contains the password, so it must
# never outlive the run.
e2e_ssh_auth_init() {
    local password="${1:-live}"
    if command -v sshpass >/dev/null 2>&1; then
        E2E_SSH_WRAP="sshpass -p ${password}"
        E2E_SSH_AUTH_OPTS=""
        return 0
    fi
    local dir shim
    dir=$(mktemp -d "${TMPDIR:-/tmp}/krytis-e2e-askpass-XXXXXX")
    e2e_cleanup_add "${dir}"
    shim="${dir}/askpass"
    printf '#!/bin/sh\necho %s\n' "${password}" > "${shim}"
    chmod 0700 "${shim}"
    export SSH_ASKPASS="${shim}"
    export SSH_ASKPASS_REQUIRE=force
    export DISPLAY="${DISPLAY:-:0}"
    E2E_SSH_WRAP=""
    E2E_SSH_AUTH_OPTS="-o NumberOfPasswordPrompts=1"
    echo "sshpass not found — using OpenSSH SSH_ASKPASS_REQUIRE=force" >&2
    return 0
}

# ── QEMU HMP monitor ─────────────────────────────────────────────────────────
# e2e_monitor <monitor-socket> <hmp command...>
#
# Never fails the caller: a monitor that has already gone away is normal at
# teardown. sudo is used when the socket is not writable — QEMU runs under sudo
# on hosts where the user cannot open /dev/kvm, and the socket is then root-owned
# (docs/skills/qa-policy.md § permission denied on root-owned monitor sockets).
e2e_monitor() {
    local sock="$1"; shift
    local cmd="$*"
    [[ -S "${sock}" ]] || return 0
    local prefix=""
    if ! test -w "${sock}" 2>/dev/null; then prefix="sudo"; fi
    if command -v socat >/dev/null 2>&1; then
        echo "${cmd}" | $prefix socat - "UNIX-CONNECT:${sock}" 2>/dev/null || true
        return 0
    fi
    # python3 fallback, copied from krytis mise/tasks/boot-test. The 0.3s settle
    # plus the discarded first recv are load-bearing: HMP writes a banner before
    # it will accept a command, and a command sent into that banner is dropped.
    $prefix python3 - "${sock}" "${cmd}" <<'PY' 2>/dev/null || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sys.argv[1])
time.sleep(0.3)
try:
    s.recv(65536)
except OSError:
    pass
s.sendall(sys.argv[2].encode() + b"\n")
time.sleep(0.5)
s.close()
PY
    return 0
}

# ── QEMU lifecycle ───────────────────────────────────────────────────────────
# A daemonized QEMU outlives the recipe that started it, so a phase that gives up
# without killing its own VM leaves the ISO, the install disk and the hostfwd port
# held by a process nothing tracks any more — the next run then fails on a disk
# lock or a bound port, far away from the real cause.
#
# The boot recipes pass `-pidfile "<monitor-socket>.pid"`, so the monitor socket
# path alone identifies a VM.

# /proc, not `kill -0`: for a QEMU started under sudo, `kill -0` from the
# unprivileged user fails with EPERM and is indistinguishable from "not running".
_e2e_pid_running() { [[ -n "${1:-}" ]] && [[ -d "/proc/$1" ]]; }

# e2e_qemu_stop <monitor-socket> [label] — always returns 0.
e2e_qemu_stop() {
    local sock="$1" label="${2:-QEMU}"
    local pidfile="${sock}.pid" pid i
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    pid="${pid//[[:space:]]/}"
    [[ -S "${sock}" ]] || _e2e_pid_running "${pid}" || { rm -f "${pidfile}" 2>/dev/null || true; return 0; }
    echo "${label}: stopping (monitor ${sock}${pid:+, pid ${pid}})"
    e2e_monitor "${sock}" quit
    for i in $(seq 1 10); do
        _e2e_pid_running "${pid}" || break
        sleep 1
    done
    if _e2e_pid_running "${pid}"; then
        echo "${label}: pid ${pid} survived the monitor quit — SIGKILL" >&2
        kill -9 "${pid}" 2>/dev/null || sudo kill -9 "${pid}" 2>/dev/null || true
        sleep 1
    fi
    rm -f "${pidfile}" "${sock}" 2>/dev/null || true
    return 0
}

# e2e_port_free <port> — 0 when nothing is listening on 127.0.0.1:<port>.
e2e_port_free() {
    python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}
