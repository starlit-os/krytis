#!/usr/bin/env bash
# qemu-hostfwd.sh — launch a daemonized QEMU with a user-net SSH forward on a
# host port nothing else holds (#1373).
#
#     . scripts/qemu-hostfwd.sh
#     launch_qemu() {
#         qemu-system-x86_64 … \
#             -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
#             … -daemonize -pidfile "${WORKDIR}/qemu.pid"
#     }
#     qemu_launch_hostfwd 2299 launch_qemu
#     QEMU_PID=$(cat "${WORKDIR}/qemu.pid")
#
# Several VM tasks can run at once (two boot-tests from two sessions, a
# boot-test next to an oomd-test), and each starts its search at a fixed port.
# The tasks used to pick the port at startup and bind it only when QEMU
# launched, after generate-disk, about 14 minutes later in boot-test. A second
# run starting in that window found the same port free, took it first, and the
# first run's QEMU died with "Could not set up host forwarding rule" after the
# sudo install had already happened.
#
# So the probe runs immediately before the launch, and because a probe can
# never reserve a port, a launch that still loses the bind moves to the next
# port and tries again.

# hostfwd_port_free <port> — 0 when no TCP socket listens on <port>. Matches the
# port exactly, on any address: a listener on :22990 does not make 2299 busy.
hostfwd_port_free() {
    [ -z "$(ss -Htln "sport = :$1" 2>/dev/null)" ]
}

# qemu_launch_hostfwd <first-port> <launch-fn>
#
# Sets SSH_PORT to the first free port at or above <first-port> and calls
# <launch-fn>, which must start QEMU with -daemonize and forward ${SSH_PORT}.
# -daemonize makes QEMU exit non-zero, with the error on stderr, when the
# forward can't bind, so the failure shows up here and not as an SSH timeout.
# Retries on the next free port only for that error; any other launch failure
# is returned at once, with QEMU's stderr.
qemu_launch_hostfwd() {
    local port="$1" launch="$2" err attempt rc=1
    err=$(mktemp)
    for attempt in 1 2 3 4 5; do
        while ! hostfwd_port_free "${port}"; do port=$((port + 1)); done
        SSH_PORT="${port}"
        if "${launch}" 2>"${err}"; then
            rc=0
            break
        fi
        cat "${err}" >&2
        grep -q 'Could not set up host forwarding rule' "${err}" || break
        echo "==> Port ${port} was taken between the probe and the QEMU launch (attempt ${attempt}/5)." >&2
        port=$((port + 1))
    done
    # Warnings from a successful launch still belong on the console.
    if [ "${rc}" -eq 0 ]; then cat "${err}" >&2; fi
    rm -f "${err}"
    return "${rc}"
}
