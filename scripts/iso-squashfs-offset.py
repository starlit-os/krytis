#!/usr/bin/env python3
"""Print the byte offset of LiveOS/squashfs.img inside a live ISO.

Feed the result to `unsquashfs -offset <n> <iso> …` to read the live rootfs
straight out of the ISO: no root, no loop mount, and no ~5GB extract. xorriso
is not installed on a Krytis host at all (dakota-iso routes it through the
iso-tools container), so an `-osirrox` extract would be both slower and less
portable here.

File data in an ISO 9660 image is contiguous — including across the
multi-extent records `-iso-level 3` uses for files over 4GB — so the first
directory record's extent is the start of the squashfs. The squashfs magic is
asserted at the computed offset, so a layout change fails loudly here instead
of as a confusing unsquashfs error downstream.
"""

import sys

SECTOR = 2048


def main(path: str) -> int:
    iso = open(path, "rb")

    def read_sectors(lba: int, count: int = 1) -> bytes:
        iso.seek(lba * SECTOR)
        return iso.read(count * SECTOR)

    def records(lba: int, length: int):
        """Yield (NAME, extent_lba, size, is_dir) for each record in a directory extent."""
        data = read_sectors(lba, (length + SECTOR - 1) // SECTOR)
        pos = 0
        while pos < len(data):
            rec_len = data[pos]
            if rec_len == 0:
                # Zero padding runs to the end of the sector; resume at the next one.
                pos = (pos // SECTOR + 1) * SECTOR
                continue
            rec = data[pos:pos + rec_len]
            name = rec[33:33 + rec[32]].decode("latin-1").split(";")[0].upper()
            yield (
                name,
                int.from_bytes(rec[2:6], "little"),
                int.from_bytes(rec[10:14], "little"),
                bool(rec[25] & 0x02),
            )
            pos += rec_len

    pvd = read_sectors(16)
    if pvd[0] != 1 or pvd[1:6] != b"CD001":
        sys.exit("not an ISO 9660 image (no primary volume descriptor at sector 16)")

    root = pvd[156:190]
    lba = int.from_bytes(root[2:6], "little")
    length = int.from_bytes(root[10:14], "little")

    for want, want_dir in (("LIVEOS", True), ("SQUASHFS.IMG", False)):
        for name, extent, size, is_dir in records(lba, length):
            if name == want and is_dir == want_dir:
                lba, length = extent, size
                break
        else:
            sys.exit(f"{want} not found while walking the ISO's LiveOS path")

    offset = lba * SECTOR
    iso.seek(offset)
    if iso.read(4) != b"hsqs":
        sys.exit(f"no squashfs magic at offset {offset} — the ISO layout changed")

    print(offset)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <iso>")
    raise SystemExit(main(sys.argv[1]))
