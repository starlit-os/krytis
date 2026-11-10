#!/bin/bash
# Seed noctalia-greeter's state in /var/lib/noctalia-greeter once, from the
# read-only templates in /usr/share/noctalia-greeter. The unit runs only while
# one of the two files is missing, and this script never overwrites either.
#
#   greeter.toml  declarative config (hide_logo, #296). Since v1.7.0 the greeter
#                 never writes it.
#   sync.toml     the greeter's own state: last session, scheme, outputs. We
#                 seed `[session] last = "Umbriel"` so a fresh install preselects
#                 Umbriel (#1566). With nothing saved, noctalia-greeter picks the
#                 first session sorted by name, which is niri.
#
# "Preselect, not pin" (owner decision on #1566, 2026-11-09): a saved choice
# always wins. So sync.toml is seeded only when the greeter has no session
# state at all, including the two legacy places v1.7.0 still migrates from:
# state.toml (the old name of sync.toml) and a `[session] last` key in
# greeter.toml. If sync.toml were written while either holds a choice, the
# greeter's migrateLegacyRuntimeKeysToSync() would see sync.toml present, skip
# the migration, and the user's saved niri would be replaced by Umbriel.
# [session] default or --session would pin rather than preselect, which is why
# neither is used.
set -euo pipefail

STATE_DIR=${KRYTIS_GREETER_STATE_DIR:-/var/lib/noctalia-greeter}
TEMPLATE_DIR=${KRYTIS_GREETER_TEMPLATE_DIR:-/usr/share/noctalia-greeter}
OWNER=(-o greeter -g greeter)
[ -n "${KRYTIS_GREETER_NO_CHOWN:-}" ] && OWNER=()

# Does greeter.toml carry a non-empty `last` key in its [session] table?
legacy_last_session() {
    [ -f "${STATE_DIR}/greeter.toml" ] || return 1
    awk '
        /^[[:space:]]*\[/ { in_session = ($0 ~ /^[[:space:]]*\[session\][[:space:]]*(#.*)?$/); next }
        in_session && /^[[:space:]]*last[[:space:]]*=[[:space:]]*"[^"]+"/ { found = 1 }
        END { exit !found }
    ' "${STATE_DIR}/greeter.toml"
}

# sync.toml first: its guard reads greeter.toml as the user left it, before a
# fresh greeter.toml lands.
if [ ! -e "${STATE_DIR}/sync.toml" ]; then
    if [ -e "${STATE_DIR}/state.toml" ] || legacy_last_session; then
        echo "greeter has a saved session in legacy state; not seeding sync.toml"
    else
        install -D -m 644 "${OWNER[@]}" "${TEMPLATE_DIR}/sync.toml" "${STATE_DIR}/sync.toml"
        echo "seeded ${STATE_DIR}/sync.toml (preselects Umbriel)"
    fi
fi

if [ ! -e "${STATE_DIR}/greeter.toml" ]; then
    install -D -m 644 "${OWNER[@]}" "${TEMPLATE_DIR}/greeter.toml" "${STATE_DIR}/greeter.toml"
    echo "seeded ${STATE_DIR}/greeter.toml"
fi
