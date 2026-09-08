#!/bin/bash
# Assigns a deterministic, non-colliding subuid/subgid range to every local
# regular-login account (UID_MIN..UID_MAX per /etc/login.defs) that does not
# already have one in /etc/subuid / /etc/subgid.
#
# Neither systemd-sysusers nor systemd-homed populate these files the way
# `useradd` does -- this is a confirmed, still-open upstream gap
# (systemd/systemd#21952, systemd/systemd#29297, containers/podman#20040,
# containers/podman#24828), not a krytis oversight. Without a range, rootless
# podman fails for that account with "potentially insufficient UIDs or GIDs
# available in user namespace" / "no subuid ranges found" -- breaking
# per-user podman-restart.service and podman-auto-update.service on every
# boot, and any manual rootless podman use (mise run runner/build,
# renovate-check). See docs/skills/pam.md and docs/skills/ci-runner.md.
#
# Idempotent and safe to re-run: skips any account that already has an
# entry in the relevant file, per file. Runs every boot rather than once,
# so an account created since the last boot is picked up without a
# reboot-order dependency on account creation.
set -euo pipefail

uid_min=$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs)
uid_max=$(awk '$1=="UID_MAX"{print $2}' /etc/login.defs)
sub_uid_min=$(awk '$1=="SUB_UID_MIN"{print $2}' /etc/login.defs)
sub_uid_count=$(awk '$1=="SUB_UID_COUNT"{print $2}' /etc/login.defs)
sub_uid_max=$(awk '$1=="SUB_UID_MAX"{print $2}' /etc/login.defs)

: "${uid_min:=1000}"
: "${uid_max:=60000}"
: "${sub_uid_min:=100000}"
: "${sub_uid_count:=65536}"
: "${sub_uid_max:=600100000}"

while IFS=: read -r name _ uid _ _ _ shell; do
    [ "${uid}" -ge "${uid_min}" ] && [ "${uid}" -le "${uid_max}" ] || continue
    case "${shell}" in
        */nologin | */false) continue ;;
    esac

    # Deterministic per-UID offset so ranges never collide between accounts
    # without needing to scan existing assignments first.
    start=$((sub_uid_min + (uid - uid_min) * sub_uid_count))
    if [ "${start}" -ge "${sub_uid_max}" ]; then
        echo "krytis-subuid-provision: ${name} (uid ${uid}) would exceed SUB_UID_MAX=${sub_uid_max}, skipping" >&2
        continue
    fi
    range="${start}-$((start + sub_uid_count - 1))"

    args=()
    grep -q "^${name}:" /etc/subuid 2>/dev/null || args+=(--add-subuids "${range}")
    grep -q "^${name}:" /etc/subgid 2>/dev/null || args+=(--add-subgids "${range}")
    if [ "${#args[@]}" -gt 0 ]; then
        echo "krytis-subuid-provision: assigning ${range} to ${name} (uid ${uid})"
        usermod "${args[@]}" "${name}"
    fi
done < <(getent passwd)
