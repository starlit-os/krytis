# Masks systemd-sysupdate-update.timer and systemd-sysupdate-reboot.timer (#1794).
#
# systemd ships both timers with [Install] WantedBy=timers.target and no
# preset names them, so `systemctl preset-all` enables them by default: the
# image's own /etc/systemd/system/timers.target.wants/ links both. krytis
# updates through bootc (starlit-update.timer) and ships no sysupdate.d
# transfer definitions, so neither timer has anything to do:
#
# - systemd-sysupdate-reboot.service exits 1 with "No transfer definitions
#   found." every time the timer fires, which leaves `systemctl
#   is-system-running` at `degraded`. Seen on adora (image
#   26.08.202611251856, systemd 262.2), where the persistent journal had 30 of
#   these failures from 2026-09-07 to 2026-11-26. Found while verifying #1713.
# - systemd-sysupdate-update.service logs the same line but exits 0. It still
#   pulls in network-online.target every 2-6 h for nothing, and
#   systemd-sysupdate-auto-enable.service runs before it ("No components
#   selected.").
#
# Masking the timers is enough. The services start only from them, or by
# hand. The systemd-sysupdate-notify-*.socket units are left alone: they only
# listen, and systemd-sysupdate-notify-pcrlock.socket is cited by
# config/pcrlock-policy-mask.bst.
#
# The mask lives in /etc, the same pattern as config/networkd-mask.bst and
# config/pcrlock-policy-mask.bst. bootc's three-way /etc merge adds it to
# installed machines, which keep their timers.target.wants symlinks. A wants
# symlink to a masked unit pulls in nothing. Masking systemd-sysupdate-update.timer
# also covers its alias systemd-sysupdate.timer.
#
# Removal condition: krytis ships sysupdate.d transfers (for example to update
# sysexts). Then delete this element and let the timers run.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -d "%{install-root}%{sysconfdir}/systemd/system"
    ln -sf /dev/null "%{install-root}%{sysconfdir}/systemd/system/systemd-sysupdate-update.timer"
    ln -sf /dev/null "%{install-root}%{sysconfdir}/systemd/system/systemd-sysupdate-reboot.timer"
