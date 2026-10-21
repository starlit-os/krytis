# Build and test environment for a kitten-lily/seance checkout, used by
# `mise run seance-fork:ci`. Mirrors upstream's .github/workflows/ci.yml:
# ubuntu-24.04, its apt list and Zig 0.16.0. krytis hosts have no zig or
# pkg-config, and the fork's own GitHub workflows are disabled.
# gcc: the fullscreen and IME suites compile a helper with `cc`.
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      libgtk-4-dev libadwaita-1-dev libnotify-dev libcanberra-dev libx11-dev libwayland-dev \
      libegl-dev libgl-dev libfontconfig-dev libonig-dev xdotool x11-xkb-utils openbox zsh xvfb xauth \
      python3 nodejs gcc libc6-dev curl ca-certificates xz-utils git pkg-config dbus-x11 \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/zig \
 && curl -fsSL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
      | tar -xJ -C /opt/zig --strip-components=1 \
 && ln -s /opt/zig/zig /usr/local/bin/zig && zig version
