# shellcheck shell=bash
# Shared checks for the Secure Boot key pairs in files/boot-keys/.
#
# Not a mise task: `mise` only scans `mise/tasks/`, so this file can be sourced
# without becoming a runnable task. Tasks source it with:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/boot-keys.sh"

# $1 = path, $2 = kind (key|crt) — present, non-empty, and openssl-valid
file_ok() {
    [ -s "$1" ] || return 1
    case "$2" in
        key) openssl rsa -check -in "$1" -noout >/dev/null 2>&1 || openssl ec -check -in "$1" -noout >/dev/null 2>&1 ;;
        crt) openssl x509 -noout -in "$1" >/dev/null 2>&1 ;;
    esac
}

# $1 = private key, $2 = cert — cert's public key matches the private key.
# Each half can be valid on its own and still not belong to the other (a
# vault field rotated without its partner); signing with such a pair builds
# fine and only fails at boot under enforcement (#1327).
pair_matches() {
    local kpub cpub
    kpub=$(openssl pkey -in "$1" -pubout 2>/dev/null) || return 1
    cpub=$(openssl x509 -in "$2" -pubkey -noout 2>/dev/null) || return 1
    [ "$kpub" = "$cpub" ]
}

# $1 = key directory — exit 1 unless PK, KEK and db are each a complete,
# valid, matching pair.
require_key_pairs() {
    local dir="$1" key bad=()
    for key in PK KEK db; do
        if ! file_ok "${dir}/${key}.key" key || ! file_ok "${dir}/${key}.crt" crt \
            || ! pair_matches "${dir}/${key}.key" "${dir}/${key}.crt"; then
            bad+=("$key")
        fi
    done
    if [ "${#bad[@]}" -gt 0 ]; then
        echo "ERROR: key pairs in ${dir}/ are missing, invalid, or mismatched: ${bad[*]}" >&2
        echo "Each <KEY>.key must be the private key for <KEY>.crt. Re-run 'mise run pull-keys'" >&2
        echo "or fix the vault item so both fields come from the same key pair." >&2
        exit 1
    fi
}
