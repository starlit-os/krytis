#!/usr/bin/env python3
"""Verify the OCI layout at /OCI in a live ISO and print a JSON summary.

The layout is the ISO's offline install payload (scripts/iso-sd-boot.sh), read
by fisherman at /run/initramfs/live/OCI. This re-does on the finished ISO the
digest and size checks fisherman makes before it touches a disk
(PreflightBoundOCIMediaInput in tuna-os/fisherman), so a broken layout fails the
build instead of an install. Unprivileged, no loop mount, no extract.

Paths are resolved through the Joliet tree, not the primary ISO 9660 one: blob
names are 64 hex characters, which the primary tree mangles and Joliet
(`-J --joliet-long`, live/src/build-iso.sh) keeps. A file larger than 4 GiB is
split across several directory records (multi-extent, `-iso-level 3`); their
extents are read in order.

Output (stdout): {"manifestDigest", "configDigest", "refName", "layers",
"bytes"}. Any mismatch exits non-zero with the reason on stderr.
"""

import hashlib
import json
import sys

SECTOR = 2048
CHUNK = 8 << 20
LAYOUT = "OCI"


class Iso:
    def __init__(self, path: str):
        self.f = open(path, "rb")
        self.root = self._joliet_root()

    def _sectors(self, lba: int, count: int = 1) -> bytes:
        self.f.seek(lba * SECTOR)
        return self.f.read(count * SECTOR)

    def _joliet_root(self):
        for n in range(16, 64):
            vd = self._sectors(n)
            if vd[1:6] != b"CD001" or vd[0] == 255:
                break
            # Supplementary descriptor with a UCS-2 escape sequence = Joliet.
            if vd[0] == 2 and vd[88:91] in (b"%/@", b"%/C", b"%/E"):
                rec = vd[156:190]
                return int.from_bytes(rec[2:6], "little"), int.from_bytes(rec[10:14], "little")
        sys.exit("no Joliet volume descriptor — was the ISO built without -J?")

    def _entries(self, lba: int, length: int) -> dict:
        data = self._sectors(lba, (length + SECTOR - 1) // SECTOR)
        out: dict = {}
        pos = 0
        while pos < len(data):
            rec_len = data[pos]
            if rec_len == 0:
                # Zero padding runs to the end of the sector; resume at the next one.
                pos = (pos // SECTOR + 1) * SECTOR
                continue
            rec = data[pos:pos + rec_len]
            pos += rec_len
            ident = rec[33:33 + rec[32]]
            if ident in (b"\x00", b"\x01"):  # "." and ".."
                continue
            name = ident.decode("utf-16-be").split(";")[0]
            out.setdefault(name, []).append((
                int.from_bytes(rec[2:6], "little"),
                int.from_bytes(rec[10:14], "little"),
                bool(rec[25] & 0x02),
            ))
        return out

    def extents(self, path: str):
        lba, length = self.root
        parts = path.split("/")
        for i, part in enumerate(parts):
            found = self._entries(lba, length).get(part)
            if not found:
                raise FileNotFoundError(path)
            if i < len(parts) - 1:
                lba, length, is_dir = found[0]
                if not is_dir:
                    raise NotADirectoryError(path)
        return [(e[0], e[1]) for e in found]

    def stream(self, path: str):
        for lba, size in self.extents(path):
            self.f.seek(lba * SECTOR)
            left = size
            while left:
                chunk = self.f.read(min(CHUNK, left))
                if not chunk:
                    raise EOFError(path)
                left -= len(chunk)
                yield chunk

    def read(self, path: str) -> bytes:
        return b"".join(self.stream(path))


def fail(msg: str):
    sys.exit(f"ERROR: {msg}")


def main(iso_path: str) -> int:
    iso = Iso(iso_path)

    def blob(desc: dict, what: str) -> int:
        digest, size = desc.get("digest", ""), desc.get("size")
        alg, _, hexpart = digest.partition(":")
        if alg != "sha256" or len(hexpart) != 64:
            fail(f"{what} has no sha256 digest: {digest!r}")
        path = f"{LAYOUT}/blobs/sha256/{hexpart}"
        h, n = hashlib.sha256(), 0
        try:
            for chunk in iso.stream(path):
                h.update(chunk)
                n += len(chunk)
        except FileNotFoundError:
            fail(f"{what} {digest} is not on the ISO ({path})")
        if n != size:
            fail(f"{what} {digest} is {n} bytes, its descriptor says {size}")
        if h.hexdigest() != hexpart:
            fail(f"{what} {digest} hashes to sha256:{h.hexdigest()}")
        return n

    def blob_json(desc: dict, what: str):
        blob(desc, what)
        return json.loads(iso.read(f"{LAYOUT}/blobs/sha256/{desc['digest'].split(':', 1)[1]}"))

    try:
        layout = json.loads(iso.read(f"{LAYOUT}/oci-layout"))
        index = json.loads(iso.read(f"{LAYOUT}/index.json"))
    except FileNotFoundError as e:
        fail(f"/{e.args[0]} is not on the ISO — no embedded OCI layout")
    if layout.get("imageLayoutVersion") != "1.0.0":
        fail(f"oci-layout is {layout!r}, not imageLayoutVersion 1.0.0")
    manifests = index.get("manifests") or []
    if index.get("schemaVersion") != 2 or len(manifests) != 1:
        fail(f"index.json must be schemaVersion 2 with one manifest, has {len(manifests)}")
    desc = manifests[0]

    manifest = blob_json(desc, "manifest")
    if manifest.get("schemaVersion") != 2 or not manifest.get("layers"):
        fail("manifest is not a schemaVersion 2 image manifest with layers")
    config = blob_json(manifest["config"], "config")
    if (config.get("os"), config.get("architecture")) != ("linux", "amd64"):
        fail(f"config platform is {config.get('os')}/{config.get('architecture')}, not linux/amd64")
    total = sum(blob(layer, f"layer {i}") for i, layer in enumerate(manifest["layers"]))

    json.dump({
        "manifestDigest": desc["digest"],
        "configDigest": manifest["config"]["digest"],
        "refName": (desc.get("annotations") or {}).get("org.opencontainers.image.ref.name", ""),
        "layers": len(manifest["layers"]),
        "bytes": total,
    }, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <iso>")
    raise SystemExit(main(sys.argv[1]))
