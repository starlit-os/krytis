# polkit-agent-sandbox.bst: let pam_u2f reach the token from inside polkit's
# sandboxed PAM helper. Closes #871.
#
# polkit 127 stopped fork/exec'ing its setuid helper for every authentication
# and now hands the conversation to a socket-activated systemd unit instead
# (polkit-agent-helper.socket -> polkit-agent-helper@.service, upstream
# polkit#501). The unit ships hardened, and two of its options make pam_u2f
# structurally incapable of succeeding:
#
#   PrivateDevices=yes    the helper gets a private /dev holding only the
#                         standard pseudo devices. /dev/hidraw* is simply
#                         absent, so libfido2 enumerates ZERO tokens and
#                         pam_u2f returns PAM_AUTHINFO_UNAVAIL.
#   ProtectHome=yes       systemd chases the /home -> var/home symlink when it
#                         builds the namespace, so /var/home is inaccessible
#                         too — pam_u2f's per-user authfile
#                         ~/.config/Yubico/u2f_keys cannot be opened.
#
# Either one alone is fatal, and both fail silently: the auth phase falls
# straight through to pam_unix and the user gets a password prompt with no
# FIDO2 attempt and no pam_u2f log line at all. Only the polkit path is
# affected — sudo, run0's own PAM stack, the greeter and console login do not
# go through this helper, which is why a key that works for sudo looks broken
# for polkit and for anything routed through polkit (run0, GUI privilege
# prompts, the noctalia polkit agent).
#
# Upstream is polkit#633 (see also #622, #623): acknowledged, unfixed, no ETA,
# and upstream's own advice in the meantime is a unit override. This is that
# override, relaxing exactly the two options that block the token and nothing
# else. #874 tracks the upstream fix and carries the removal condition — do
# not delete this element just because polkit drops the setuid helper
# (polkit#704) or because the socket unit stops being enabled; read #874
# first, both of those make the override MORE load-bearing, not less.
# Everything the sandbox is actually worth keeping stays: the helper
# still runs with NoNewPrivileges=yes, SystemCallFilter=@system-service,
# ProtectSystem=strict, RestrictAddressFamilies=AF_UNIX, PrivateNetwork=yes,
# MemoryDenyWriteExecute=yes and the rest of upstream's list.
#
# Why these exact values, rather than blanket `no`:
#
#   DevicePolicy=closed          keeps a cgroup device whitelist (standard
#                                pseudo devices + what is listed below) instead
#                                of opening /dev wholesale. PrivateDevices=no
#                                is unavoidable: with a private /dev the hidraw
#                                nodes do not exist to be allowed.
#   DeviceAllow=char-hidraw rw   USB HID is the only transport krytis's FIDO2
#                                keys use (libfido2 on Linux talks /dev/hidraw;
#                                NFC would need pcscd, not a device rule).
#   ProtectHome=read-only        pam_u2f only ever reads the authfile. The
#                                helper regains visibility of home, not write
#                                access to it.
#
# Verified on a live 127 system by reproducing each blocker and its fix under
# the unit's own options (see docs/skills/pam.md § polkit's sandboxed PAM
# helper). boot-test asserts the merged values on the booted image, because a
# drop-in is silently dead if upstream renames the unit.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system/polkit-agent-helper@.service.d/50-krytis-fido2.conf"
    cat > "%{install-root}%{indep-libdir}/systemd/system/polkit-agent-helper@.service.d/50-krytis-fido2.conf" <<'EOF'
    # krytis: polkit >= 127 runs the PAM conversation in a sandbox that hides
    # /dev/hidraw* and /var/home from pam_u2f, so FIDO2 authentication at a
    # polkit prompt can never succeed (upstream polkit#633). Relax exactly
    # those two, keep the rest of the sandbox. See
    # elements/config/polkit-agent-sandbox.bst for the full reasoning.
    [Service]
    PrivateDevices=no
    DevicePolicy=closed
    DeviceAllow=char-hidraw rw
    ProtectHome=read-only
    EOF
  - "%{install-extra}"
