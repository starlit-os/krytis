# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted ROOT/U commands expand in the guest, on purpose
# Sourced by mise/tasks/oomd-test for --scenario swap (#1752). Uses that task's
# ROOT, U, pass, fail, APP_SLICE, TEST_UID, WORKDIR, IMAGE, OOMD_CONFIG, PARTS,
# RUNS and RESULTS. See the task header for what a run records.

# Guest-side helpers. All three write with line buffering so a kill or a stalled
# harness loses at most the line in flight.
OOMDTEST_HOG='import os, sys, time
# argv[1]: MiB/s. Pages are half random, half 0x01: ~2:1 under zswap, like real memory.
rate = int(sys.argv[1]) << 20
chunk = 16 << 20
chunks = []
t0 = time.monotonic()
n = 0
while True:
    page = os.urandom(2048) + b"\x01" * 2048
    chunks.append(page * (chunk // 4096))
    n += chunk
    ahead = n / rate - (time.monotonic() - t0)
    if ahead > 0:
        time.sleep(ahead)
'
OOMDTEST_CANARY='import sys, time
# Sleeps 100 ms at a time and keeps the worst overshoot, in ms, in argv[1].
worst = 0.0
while True:
    t = time.monotonic()
    time.sleep(0.1)
    late = time.monotonic() - t - 0.1
    if late > worst:
        worst = late
        with open(sys.argv[1], "w") as f:
            f.write(f"{worst * 1000:.0f}\n")
'
OOMDTEST_MON='import sys, time
# Every 250 ms: epoch MemTotal MemAvailable SwapTotal SwapFree (KiB) and argv[1]/memory.pressure full avg10.
out = open(sys.argv[2], "a", buffering=1)
while True:
    m = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            m[k] = v.split()[0]
    try:
        with open(sys.argv[1] + "/memory.pressure") as f:
            full = f.read().splitlines()[1].split()[1].split("=")[1]
    except (OSError, IndexError):
        full = "-"
    row = [f"{time.time():.3f}"] + [m[k] for k in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree")] + [full]
    out.write("\t".join(row) + "\n")
    time.sleep(0.25)
'

oomd_swap_run() {
    local part="$1" run="$2"
    local units=() t0 rd="${WORKDIR}/swap-${part}-${run}"
    mkdir -p "${rd}"
    case "${part}" in
        fast) units=(oomdtest-hog) ;;
        slow) units=(oomdtest-hog-1 oomdtest-hog-2 oomdtest-hog-3 oomdtest-hog-4) ;;
    esac
    t0=$(ROOT 'date +%s')
    U systemd-run --user --quiet --unit=oomdtest-lat --slice=session.slice \
        python3 /run/oomdtest-canary.py "/run/user/${TEST_UID}/oomdtest-lat"
    local u
    for u in "${units[@]}"; do
        U systemd-run --user --quiet --unit="${u}" python3 /run/oomdtest-hog.py "$([ "${part}" = fast ] && echo 1024 || echo 50)"
    done
    echo "    ${part} run ${run}: ${#units[@]} hog(s) started, waiting up to 900 s for a kill..."
    # A hog that stops is a kill: nothing else ends them. Polls can time out while the
    # guest thrashes, so a failed poll is just another wait.
    local deadline=$((SECONDS + 900)) states rc
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        # is-active exits 3 when any unit is inactive; 255 or 124 is ssh or timeout,
        # which says nothing about the hogs.
        rc=0; states=$(U systemctl --user is-active "${units[@]}" 2>/dev/null) || rc=$?
        if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 3 ]; then
            [ "$(grep -cx active <<<"${states}" || true)" -lt "${#units[@]}" ] && break
        fi
        sleep 3
    done
    # Let oomd and the kernel finish logging, then end the run.
    sleep 5
    U systemctl --user stop "${units[@]}" oomdtest-lat.service >/dev/null 2>&1 || true

    ROOT "journalctl -q -u systemd-oomd --since @${t0} -o short-unix -g 'Marked |conditions met'" >"${rd}/oomd.log" 2>/dev/null || true
    ROOT "journalctl -q _TRANSPORT=kernel --since @${t0} -o short-unix -g 'invoked oom-killer|oom-kill:'" >"${rd}/kernel.log" 2>/dev/null || true
    ROOT "awk -v t0=${t0} '\$1 >= t0' /run/oomdtest-mon.tsv" >"${rd}/mon.tsv" 2>/dev/null || true
    local lat idle canary
    lat=$(U cat "/run/user/${TEST_UID}/oomdtest-lat" 2>/dev/null || echo -)
    U rm -f "/run/user/${TEST_UID}/oomdtest-lat" >/dev/null 2>&1 || true
    idle=$(U systemctl --user is-active oomdtest-app-idle.service 2>/dev/null || true)
    canary=$(U systemctl --user is-active oomdtest-session-canary.service 2>/dev/null || true)
    # oomd logs a ruleset kill as "Rule ... conditions met for cgroup <app.slice>" and
    # never names the victim (oomd-manager.c ruleset_execute_action), so the victim is
    # the hog whose unit ended with Result=oom-kill.
    local oom_units=""
    for u in "${units[@]}"; do
        [ "$(U systemctl --user show -P Result "${u}.service" 2>/dev/null || true)" = oom-kill ] && oom_units+="${u}.service,"
    done
    U systemctl --user reset-failed "${units[@]}" oomdtest-lat.service >/dev/null 2>&1 || true

    local row rc=0
    row=$(python3 -I scripts/oomd-test-analyse.py --dir "${rd}" --app-slice "${APP_SLICE}" \
        --image "${IMAGE_VERSION}" --oomd "${OOMD_CONFIG}" --part "${part}" --run "${run}" \
        --canary-ms "${lat:--}" --oom-units "${oom_units%,}" --idle "${idle:-gone}" --canary "${canary:-gone}") || rc=$?
    [ -n "${row}" ] || { fail "${part} run ${run}: analysis produced no row"; return; }
    [ -e "${RESULTS}" ] || python3 -I scripts/oomd-test-analyse.py --header >"${RESULTS}"
    printf '%s\n' "${row}" >>"${RESULTS}"
    python3 -I scripts/oomd-test-analyse.py --describe "${row}" | sed 's/^/    /'
    case "${rc}" in
        0) pass "${part} run ${run}: killed inside app.slice, session.slice and the idle sibling intact" ;;
        3) fail "${part} run ${run}: nothing was killed within 900 s" ;;
        *) fail "${part} run ${run}: disqualifying kill or loss (#1752 rule 1), see the row above" ;;
    esac

    # Wait for the guest to settle before the next run: half of RAM available again.
    local _
    for _ in $(seq 30); do
        ROOT "awk '/^MemTotal:/ {t=\$2} /^MemAvailable:/ {a=\$2} END {exit !(a * 2 > t)}' /proc/meminfo" 2>/dev/null && break
        sleep 2
    done
}

oomd_swap_scenario() {
    echo "==> [5/6] Swap exhaustion (--oomd ${OOMD_CONFIG}, parts ${PARTS}, ${RUNS} run(s) each)..."
    local swaps
    swaps=$(ROOT 'cat /proc/swaps; echo "zswap=$(cat /sys/module/zswap/parameters/enabled)"')
    printf '%s\n' "${swaps}" | sed 's/^/    | /'
    if ! grep -q '^/var/swap/swapfile ' <<<"${swaps}" || ! grep -qx 'zswap=Y' <<<"${swaps}"; then
        fail "no zswap + /var/swap/swapfile in the guest: not the #1750 image, or the disk is too small for the swapfile"
        return
    fi
    IMAGE_VERSION=$(ROOT '. /etc/os-release; echo "${IMAGE_VERSION:-${VERSION_ID:-unknown}}"')
    printf '%s' "${OOMDTEST_HOG}" | ROOT 'cat > /run/oomdtest-hog.py && chmod 644 /run/oomdtest-hog.py'
    printf '%s' "${OOMDTEST_CANARY}" | ROOT 'cat > /run/oomdtest-canary.py && chmod 644 /run/oomdtest-canary.py'
    printf '%s' "${OOMDTEST_MON}" | ROOT 'cat > /run/oomdtest-mon.py'
    # The monitor is root's and exempt from the kernel OOM killer, so it records up to
    # the kill and past it.
    ROOT "systemd-run --quiet --unit=oomdtest-mon -p OOMScoreAdjust=-1000 python3 /run/oomdtest-mon.py /sys/fs/cgroup${APP_SLICE} /run/oomdtest-mon.tsv"
    mkdir -p "$(dirname "${RESULTS}")"

    echo "==> [6/6] Runs (one row each to ${RESULTS})..."
    local part run
    for part in ${PARTS//,/ }; do
        for run in $(seq "${RUNS}"); do
            oomd_swap_run "${part}" "${run}"
        done
    done
}
