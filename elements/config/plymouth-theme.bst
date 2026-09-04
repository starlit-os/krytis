# plymouth-theme — pins the boot-splash theme to "spinner" and swaps in a
# krytis watermark logo in place of the freedesktop-sdk swirl.
#
# fdsdk's plymouth.bst ships plymouthd.defaults with Theme=bgrt, which
# renders the UEFI firmware logo (ACPI BGRT) behind the spinner. "spinner"
# has no firmware-background dependency — it's the same two-step module
# and animation assets bgrt reuses, minus the firmware layer. "glow" (an
# earlier candidate, see docs/skills/desktop.md) was dropped for being too
# visually heavy (pie-chart fill + merge-fade logo reveal).
#
# spinner already has a watermark slot: fdsdk's plymouth-logo.bst (a
# transitive dep of plymouth.bst) installs freedesktop-sdk-40.png to
# %{datadir}/plymouth/themes/spinner/watermark.png. We overwrite that same
# path with our own logo rather than inventing a separate theme directory.
# The logo itself is pre-scaled to 80% of the original artwork (629x469 ->
# 503x375 via ffmpeg) so it doesn't dominate the screen. We also overwrite
# spinner.plymouth to move WatermarkVerticalAlignment from the stock .96
# (bottom of screen) to .4 (slightly above center) — the two-step module
# has no separate "scale" knob, alignment is the only thing it exposes, so
# sizing is baked into the source PNG and position is baked into the ini.
# Dialog/Title (LUKS unlock prompt) moved from .382 to .7 — at .382 they
# sat almost on top of the .4 watermark, and .6 was still too close.
# Spinner animation nudged .7 -> .85 to keep clearance below the dialog.
# Colors follow Rosé Pine Moon (rose-pine.dev): Background{Start,End}Color
# is Moon's "base" (#232136, coincidentally what krytis already used),
# ProgressBarBackgroundColor is Moon's "highlightMed" (#44415a),
# ProgressBarForegroundColor is Moon's "iris" (#c4a7e7).
#
# This file must be depended on by BOTH stacks/desktop.bst (so the theme
# is set on the final rootfs) and core/initramfs.bst (so dracut's plymouth
# module bakes the "spinner" theme assets into the initramfs instead of the
# default "bgrt" ones — dracut only packages the currently-configured
# theme, not all of them).
kind: manual

sources:
- kind: local
  path: files/plymouth/krytis-watermark.png

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

depends:
- freedesktop-sdk.bst:components/plymouth.bst

# Upstream plymouth ships /etc/plymouth/plymouthd.conf itself (a fully
# commented-out "Administrator customizations go in this file" template).
# plymouth-logo.bst (transitive dep of plymouth.bst) ships spinner's
# watermark.png and spinner.plymouth. We intentionally overwrite all three,
# which BST's overlap detection (fatal-warnings: overlaps in project.conf)
# flags unless whitelisted here.
public:
  bst:
    overlap-whitelist:
    - /etc/plymouth/plymouthd.conf
    - /usr/share/plymouth/themes/spinner/watermark.png
    - /usr/share/plymouth/themes/spinner/spinner.plymouth

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{sysconfdir}/plymouth/plymouthd.conf"
    cat > "%{install-root}%{sysconfdir}/plymouth/plymouthd.conf" <<'EOF'
    [Daemon]
    Theme=spinner
    EOF

  # Hold the last splash frame on the scanout until the greeter's compositor
  # modesets. Upstream's plymouth-quit.service runs a plain `plymouth quit`,
  # which tears the splash down and hands the display back to the text console
  # — and greetd is ordered `After=plymouth-quit-wait.service`, so it is
  # *guaranteed* not to have started yet. The display is unowned for ~0.55s
  # (measured: quit finished 18:00:37.0107, compositor DRM init 18:00:37.5633),
  # and whatever sits in the framebuffer underneath shows through: an empty
  # tty1 plus blinking cursor on the desktop (greetd's
  # Conflicts=getty@tty1.service means no getty is there), the firmware BGRT
  # logo and systemd-boot/systemd-stub version lines on the laptop, where the
  # EFI framebuffer was never overwritten. --retain-splash leaves the frame in
  # place instead, so there is nothing to reveal. See #727.
  #
  # Deliberately a drop-in and NOT an ordering change. Adding
  # `After=display-manager.service` here is the obvious fix and it deadlocks:
  # plymouth-quit-wait runs `plymouth --wait` with TimeoutSec=0 and blocks
  # until plymouthd exits, plymouthd exits only when plymouth-quit runs, and
  # plymouth-quit would then be waiting on greetd. systemd sees no cycle — that
  # link is a runtime dependency through plymouthd, not a declared edge — so it
  # breaks nothing and the boot hangs forever.
  #
  # config/greetd-config.bst carries the other half: retaining the splash also
  # removes the only feedback a wedged greeter gives, so greetd gets an
  # OnFailure unit that switches to the rescue VT.
  - |
    dropin="%{install-root}%{indep-libdir}/systemd/system/plymouth-quit.service.d/10-retain-splash.conf"
    install -Dm644 /dev/null "${dropin}"
    cat > "${dropin}" <<'EOF'
    [Service]
    # ExecStart= clears upstream's plain `plymouth quit` before appending ours;
    # without the reset systemd would run both.
    ExecStart=
    ExecStart=-/usr/bin/plymouth quit --retain-splash
    EOF
  - install -Dm644 krytis-watermark.png "%{install-root}%{datadir}/plymouth/themes/spinner/watermark.png"
  - |
    # Stock spinner.plymouth (from fdsdk plymouth-logo.bst), trimmed of
    # translated Name[xx] lines (cosmetic only, not read by the two-step
    # module) and with WatermarkVerticalAlignment moved from .96 to .4.
    install -Dm644 /dev/null \
      "%{install-root}%{datadir}/plymouth/themes/spinner/spinner.plymouth"
    cat > "%{install-root}%{datadir}/plymouth/themes/spinner/spinner.plymouth" <<'EOF'
    [Plymouth Theme]
    Name=Spinner
    Description=A theme designed by jimmac that features a simple spinner.
    ModuleName=two-step

    [two-step]
    Font=Cantarell 12
    TitleFont=Cantarell Light 30
    ImageDir=/usr/share/plymouth/themes//spinner
    DialogHorizontalAlignment=.5
    DialogVerticalAlignment=.7
    TitleHorizontalAlignment=.5
    TitleVerticalAlignment=.7
    HorizontalAlignment=.5
    VerticalAlignment=.85
    WatermarkHorizontalAlignment=.5
    WatermarkVerticalAlignment=.4
    Transition=none
    TransitionDuration=0.0
    BackgroundStartColor=0x232136
    BackgroundEndColor=0x232136
    ProgressBarBackgroundColor=0x44415a
    ProgressBarForegroundColor=0xc4a7e7
    MessageBelowAnimation=true

    [boot-up]
    UseEndAnimation=false

    [shutdown]
    UseEndAnimation=false

    [reboot]
    UseEndAnimation=false

    [updates]
    SuppressMessages=true
    ProgressBarShowPercentComplete=true
    UseProgressBar=true
    Title=Installing Updates...
    SubTitle=Do not turn off your computer

    [system-upgrade]
    SuppressMessages=true
    ProgressBarShowPercentComplete=true
    UseProgressBar=true
    Title=Upgrading System...
    SubTitle=Do not turn off your computer

    [firmware-upgrade]
    SuppressMessages=true
    ProgressBarShowPercentComplete=true
    UseProgressBar=true
    Title=Upgrading Firmware...
    SubTitle=Do not turn off your computer

    [system-reset]
    SuppressMessages=true
    ProgressBarShowPercentComplete=true
    UseProgressBar=true
    Title=Resetting System...
    SubTitle=Do not turn off your computer
    EOF
