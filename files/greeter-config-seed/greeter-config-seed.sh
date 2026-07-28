#!/bin/bash
# Seed /var/lib/noctalia-greeter/greeter.toml from the read-only template if
# absent. Runs once per deployment — the systemd unit is gated on the target
# file not existing, and the greeter takes over the file afterwards.
# Closes #296.
set -euo pipefail

STATE_DIR=/var/lib/noctalia-greeter
TEMPLATE=/usr/share/noctalia-greeter/greeter.toml

install -D -m 644 -o greeter -g greeter "${TEMPLATE}" "${STATE_DIR}/greeter.toml"
