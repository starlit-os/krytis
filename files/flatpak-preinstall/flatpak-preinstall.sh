#!/bin/bash
# Pre-install initial system Flatpak applications on first boot.
# Retries on subsequent boots until successful (marker file absent = not done).
# Closes #66.
set -euo pipefail

MARKER=/var/lib/flatpak/.krytis-preinstall-done

APPS=(
    # Bazaar: flatpak app-store frontend. Closes #66.
    io.github.kolunmi.Bazaar
)

flatpak install --system --noninteractive --assumeyes flathub "${APPS[@]}"

touch "${MARKER}"
