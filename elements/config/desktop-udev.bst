kind: manual

# Desktop performance and hardware tuning — ported from CachyOS-Settings.
#
# udev rules (usr/lib/udev/rules.d/):
#   20-audio-pm      — disable snd_hda_intel power save on AC (prevents HDA crackling)
#   40-hpet-perms    — give audio group access to rtc0 and hpet (low-latency audio)
#   50-sata          — SATA link power = max_performance (prevents latency spikes)
#   60-ioschedulers  — BFQ for HDDs, mq-deadline for SSDs, kyber for NVMe
#   99-cpu-dma-lat   — cpu_dma_latency device: group=audio, mode=0660
#
# Omitted: 69-hdparm.rules (hdparm not in fdsdk), 30-zram.rules (conflicts with
# zram-generator), 71-nvidia.rules (out of scope), 85-iw-regulatory.rules.
#
# modprobe.d (usr/lib/modprobe.d/):
#   amdgpu.conf — force amdgpu for GCN 1.0+ (SI/CIK) cards; disable radeon fallback
#
# modules-load.d (usr/lib/modules-load.d/):
#   ntsync.conf — autoload ntsync kernel module (NT sync primitives for Wine/Proton)
#
# tmpfiles.d (usr/lib/tmpfiles.d/):
#   thp.conf          — THP defrag=defer+madvise (improves tcmalloc/jemalloc perf)
#   thp-shrinker.conf — THP shrinker max_ptes_none=409 (kernel ≥6.12; reduces OOM risk)
#   amd-pstate-epp.conf — set EPP=balance_performance for amd-pstate-epp driver. Closes #220.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  install-commands:
  - |
    for f in udev/*.rules; do
      install -Dm644 "$f" "%{install-root}/usr/lib/udev/rules.d/$(basename "$f")"
    done
  - install -Dm644 modprobe.d/amdgpu.conf "%{install-root}/usr/lib/modprobe.d/amdgpu.conf"
  - install -Dm644 modules-load.d/ntsync.conf "%{install-root}/usr/lib/modules-load.d/ntsync.conf"
  - |
    for f in tmpfiles.d/*.conf; do
      install -Dm644 "$f" "%{install-root}/usr/lib/tmpfiles.d/$(basename "$f")"
    done

sources:
- kind: local
  path: files/desktop-tweaks
