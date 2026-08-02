#!/usr/bin/env bash
# ovmf-paths.sh — where this distro keeps OVMF, in one place (#458).
#
# Source it, then call a resolver; each prints a path on stdout or a diagnosis on
# stderr and returns 1:
#
#     . scripts/ovmf-paths.sh
#     OVMF_CODE=$(ovmf_code_secboot) || exit 1
#
# Six tasks used to carry their own candidate lists. They drifted, and the drift
# was invisible until CI ran on a distro none of them covered: Ubuntu ships a
# Secure Boot CODE but NO *VARS*secboot* file at all, so every lookup failed on
# the runner while passing on the workstation. See docs/skills/bootc-vm.md
# § Debian/Ubuntu ship no `*VARS*secboot*`.
#
# Four distinct things get resolved, and mixing them up is a silent test failure
# rather than a loud one, so they are separate functions with separate names:
#
#   ovmf_code_secboot   firmware that enforces signatures
#   ovmf_code_plain     firmware that does not
#   ovmf_vars_pristine  a varstore in SETUP MODE — no Platform Key, so the guest
#                       may enrol its own. This is what enroll-test/selfenroll-test
#                       need, and what generate-ovmf-vars bakes krytis's keys into.
#   ovmf_vars_plain     a varstore for a non-Secure-Boot boot
#
# Keep the CODE and VARS lists in the same distro order. OVMF_CODE and OVMF_VARS
# are a matched pair whose sizes must sum to 2MB or 4MB; drawing CODE from one
# distro's directory and VARS from another's can straddle the 2M/4M split, and the
# symptom is a firmware that produces no serial output at all rather than an error
# (the diagnosis boot-test prints for #414).
#
# `.fd` candidates come before `.qcow2` deliberately: every caller passes
# `format=raw` to QEMU, which silently misreads a qcow2.

_ovmf_first_existing() {
    local candidate
    for candidate in "$@"; do
        [ -f "${candidate}" ] || continue
        case "${candidate}" in
            *.qcow2)
                echo "WARNING: only a qcow2 firmware image was found (${candidate})." >&2
                echo "         Callers pass format=raw; pass format=qcow2 for this one." >&2
                ;;
        esac
        printf '%s\n' "${candidate}"
        return 0
    done
    return 1
}

# A varstore that already carries a Platform Key is not in Setup Mode, and a guest
# will not enrol anything into it. Substituting Ubuntu's OVMF_VARS_4M.ms.fd for a
# missing secboot varstore is the tempting version of this mistake: it looks like a
# working Secure Boot varstore, and it turns "watch the image enrol its own keys"
# into a test that asserts nothing at all.
_ovmf_assert_setup_mode() {
    local vars="$1"
    command -v virt-fw-vars >/dev/null 2>&1 || return 0   # unverifiable here; callers that
                                                          # care already depend on the tool
    virt-fw-vars --input "${vars}" --print 2>/dev/null | grep -qE '^ *PK +:' || return 0
    echo "ERROR: ${vars} already has a Platform Key enrolled, so the firmware will not" >&2
    echo "       be in Setup Mode and the guest cannot enrol its own keys." >&2
    echo "       Never substitute a *.ms.fd varstore here — it ships Microsoft's keys" >&2
    echo "       pre-enrolled and would make an enrollment test vacuous." >&2
    return 1
}

ovmf_code_secboot() {
    _ovmf_first_existing \
        /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd \
        /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.secboot.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE_4M.secboot.qcow2 && return 0
    echo "ERROR: no Secure Boot-capable OVMF firmware found." >&2
    echo "       Fedora: edk2-ovmf   Arch: edk2-ovmf   Debian/Ubuntu: ovmf" >&2
    return 1
}

ovmf_code_plain() {
    _ovmf_first_existing \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd && return 0
    echo "ERROR: no OVMF firmware found." >&2
    return 1
}

ovmf_vars_pristine() {
    local vars
    # Debian/Ubuntu have no *VARS*secboot* at all; their setup-mode varstore is the
    # bare OVMF_VARS_4M.fd, which pairs with the secboot CODE above. It is last so
    # distros that do ship an explicit secboot varstore keep using theirs.
    vars=$(_ovmf_first_existing \
        /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.fd \
        /usr/share/edk2/x64/OVMF_VARS.4m.secboot.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS_4M.secboot.qcow2) || {
        echo "ERROR: no OVMF varstore template found." >&2
        return 1
    }
    _ovmf_assert_setup_mode "${vars}" || return 1
    printf '%s\n' "${vars}"
}

ovmf_vars_plain() {
    _ovmf_first_existing \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/qemu/OVMF_VARS.fd && return 0
    echo "ERROR: no OVMF varstore found." >&2
    return 1
}
