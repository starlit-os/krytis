#!/bin/bash
# Pre-install krytis's system Flatpak applications. Closes #66.
#
# Each app is installed at most once per system. A file named after the app ID
# in ${LEDGER} records that it was handled, so:
#   - an app added to APPS later reaches existing installs on their next boot
#     (#1319: dev.zed.Zed replaced the native element on systems that had
#     finished the Bazaar-only run long before);
#   - an app the user uninstalls stays uninstalled.
# An app that is already installed (the live ISO copies its Flatpaks to the
# target) is recorded without a download: `flatpak install` prints "Skipping:
# … is already installed" and exits 0 (Flatpak 1.18.3, checked 2026-10-20).
#
# Runs every boot and exits at once when every app is recorded. A failed
# install (no network yet) leaves its apps unrecorded, so the next boot retries.
set -euo pipefail

LEDGER=/var/lib/flatpak/.krytis-preinstalled
# Written by the original script, which installed only Bazaar and then never ran
# again. Its presence means Bazaar was handled.
LEGACY_MARKER=/var/lib/flatpak/.krytis-preinstall-done

APPS=(
    # Bazaar: flatpak app-store frontend. Closes #66.
    io.github.kolunmi.Bazaar
    # Zed: code editor. Replaced desktop/zed.bst (#1319).
    dev.zed.Zed
)

mkdir -p "${LEDGER}"
if [[ -e "${LEGACY_MARKER}" ]]; then
    touch "${LEDGER}/io.github.kolunmi.Bazaar"
fi

PENDING=()
for app in "${APPS[@]}"; do
    [[ -e "${LEDGER}/${app}" ]] || PENDING+=("${app}")
done

if (( ${#PENDING[@]} == 0 )); then
    exit 0
fi

flatpak install --system --noninteractive --assumeyes flathub "${PENDING[@]}"

for app in "${PENDING[@]}"; do
    touch "${LEDGER}/${app}"
done
