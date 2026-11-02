# shellcheck shell=bash
# Offline access to the ESP of a raw disk image: FAT, so mtools reads and writes it at
# the partition's byte offset with no root, no loop device and no mount.
#
# Not a mise task: `mise` only scans `mise/tasks/`, so this file can be sourced
# without becoming a runnable task. Tasks source it with:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/esp.sh"

export MTOOLS_SKIP_CHECK=1

# The loader paths bootctl installs and `bootctl update` refreshes on x86_64.
# shellcheck disable=SC2034  # used by the tasks that source this file
ESP_LOADERS=(EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI)

# $1 = raw disk image → byte offset of its ESP (by GPT type, not partition number).
esp_offset() {
    sfdisk -J "$1" | python3 -c 'import json, sys
t = json.load(sys.stdin)["partitiontable"]
ss = t.get("sectorsize", 512)
print(next(p["start"] * ss for p in t["partitions"]
           if p["type"].upper() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"))'
}

# $1 = disk, $2 = ESP path (no leading ::/), $3 = local destination. Fails if absent.
esp_get() {
    mcopy -n -i "$1@@$(esp_offset "$1")" "::/$2" "$3" 2>/dev/null
}

# $1 = disk, $2 = local source, $3 = ESP path. Overwrites.
esp_put() {
    mcopy -o -i "$1@@$(esp_offset "$1")" "$2" "::/$3"
}

# $1 = disk → UKI file names under EFI/Linux/bootc, one per line.
esp_ukis() {
    mdir -b -i "$1@@$(esp_offset "$1")" ::/EFI/Linux/bootc 2>/dev/null || true
}

# $1 = a systemd-boot binary → its version from the .sdmagic LoaderInfo string ("262.1").
loader_version() {
    grep -aoE 'LoaderInfo: systemd-boot [0-9.]+' "$1" | head -1 | sed 's/^LoaderInfo: systemd-boot //'
}

# $1 = a systemd-boot binary → "<first 16 hex of sha256> systemd-boot <version>".
loader_info() {
    printf '%s systemd-boot %s' "$(sha256sum < "$1" | cut -c1-16)" "$(loader_version "$1")"
}
