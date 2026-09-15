#!/bin/bash
# Assigns a deterministic, non-colliding subuid/subgid range to every local
# regular-login account that does not already have one in /etc/subuid /
# /etc/subgid: classic accounts via UID_MIN..UID_MAX (/etc/login.defs), and
# systemd-homed accounts via their own reserved UID range -- see #852 for why
# both are needed.
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

# systemd-homed's own reserved "regular home user" UID range starts at
# 60001 -- one past the stock shadow-utils UID_MAX=60000 that /etc/login.defs
# ships by default and krytis never overrides. That single-UID gap meant
# every homed account fell outside UID_MIN..UID_MAX and was silently
# skipped below (#852) -- exactly the accounts this script was written for
# (see commit 9bb344b). Stable systemd constant, visible via `userdbctl`'s
# own boundary markers ("begin/end systemd-homed users"); not derived from
# /etc/login.defs because homed doesn't write there.
#
# It gets its own subuid anchor too: reusing the classic sub_uid_min=100000
# base with homed's ~60000 UID offset would overflow SUB_UID_MAX almost
# immediately ((60001-1000)*65536 is already ~3.9 billion). Anchor instead
# on systemd's separately-reserved "container users" range floor (524288,
# also a stable systemd constant -- src/basic/user-util.h, same boundary
# markers), which has over a billion UIDs of headroom for the ~500-UID
# homed range.
home_uid_min=60001
home_sub_uid_min=524288

while IFS=: read -r name _ uid _ _ _ shell; do
    case "${shell}" in
        */nologin | */false) continue ;;
    esac

    if [ "${uid}" -ge "${uid_min}" ] && [ "${uid}" -le "${uid_max}" ]; then
        # Deterministic per-UID offset so ranges never collide between
        # accounts without needing to scan existing assignments first.
        start=$((sub_uid_min + (uid - uid_min) * sub_uid_count))
    elif [ "${uid}" -ge "${home_uid_min}" ]; then
        # Outside the classic window. Only provision it if userdbctl
        # actually classifies the account as a real human ("regular") --
        # NSS-only pass-through accounts (system services, dynamic users)
        # report no disposition at all here and fall through unassigned.
        disposition=$(userdbctl user "${name}" --output=json 2>/dev/null |
            sed -n 's/^[[:space:]]*"disposition"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ "${disposition}" = "regular" ] || continue
        start=$((home_sub_uid_min + (uid - home_uid_min) * sub_uid_count))
    else
        continue
    fi

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
