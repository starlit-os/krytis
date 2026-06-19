# StarlitOS Krytis

StarlitOS Krytis is a bootc-based OCI image built on the [Freedesktop SDK](https://gitlab.com/freedesktop-sdk/freedesktop-sdk). It produces an immutable, composefs-rooted OS image suitable for `bootc install to-disk`.

## Stack

| Component | Details |
|-----------|---------|
| Build system | [BuildStream](https://buildstream.build/) 2.5+ |
| Base SDK | Freedesktop SDK 25 |
| Kernel | CachyOS `linux-cachyos` (BORE-EEVDF, x86_64_v3) |
| Root filesystem | composefs (EROFS over btrfs, set up by bootc) |
| Task runner | [mise](https://mise.jdx.dev/) |

## Setup

Install [mise](https://mise.jdx.dev/), then bootstrap the dev environment:

```bash
mise settings experimental=true   # required once, before first run
mise run bootstrap                 # installs system deps; sets up BST venv
```

`mise run bootstrap` (not `mise bootstrap` — `bootstrap` is a mise built-in keyword).

## Building

Prerequisites: `mise`, rootful podman, OVMF (for VM testing).

```bash
# Validate the element graph
mise validate

# Build and load the OCI image
mise load-image

# Apply Containerfile (bootc lint)
mise lint

# Write to a disk image
mise generate-disk

# Boot in a VM
mise boot-vm
```

## Source

<https://github.com/starlit-os/krytis>

> Entrapta: \[to herself] Krytis, Krytis, Krytis... \[the interface dings and flashes red] Hmm. There's something here, but it's locked. We need administrator clearance to access it.
