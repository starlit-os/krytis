# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[Security → Report a vulnerability](https://github.com/starlit-os/krytis/security/advisories/new).
Please don't open a public issue for it.

Include what you saw, the image you run (`IMAGE_VERSION` from `/usr/lib/os-release`, or
the digest `bootc status` shows) or the commit, and how to reproduce it. krytis is a
small project maintained in spare time: expect a reply within two weeks, and a fix in a
newly published image if the report holds up.

## Supported versions

Only the newest published image gets fixes: `ghcr.io/starlit-os/krytis:latest` and its
Secure Boot variant `:sealed`. There are no maintained older branches. A machine picks up
a fix through its normal `bootc upgrade`.

## What is in scope

krytis builds an OS image out of upstream components (Freedesktop SDK, GNOME Build
Metadata and the projects its own elements build). In scope is what krytis itself
decides or ships:

- the configuration it installs: PAM stacks, greetd, sudoers drop-ins, polkit rules,
  systemd units, udev rules, `/etc` defaults;
- its own scripts and tasks that end up in the image, such as the `mise fido2:*` tasks
  and the update service;
- the boot chain it assembles: Secure Boot keys and enrollment, the signed UKI,
  composefs, LUKS unlock;
- the supply chain: image signing (`cosign.pub`, the container signature policy hosts
  enforce), the CI workflows that build and publish, and how sources are pinned and
  updated;
- a patch krytis carries against a component (`docs/design/carried-patches.md`), or a
  component kept on a version with a known vulnerability.

A bug in an upstream component that krytis ships unchanged belongs to that project's
tracker. You're still welcome to tell us, so the image can take the fix as soon as it
exists.
