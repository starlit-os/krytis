#!/usr/bin/env python3
"""Attribute every file in the built krytis image to its owning BST element.

Reads the element list from a built image's /usr/manifest.json (produced by
elements/oci/krytis/manifest.bst), then for each element asks BuildStream for
that element's own artifact file list via `bst artifact checkout --tar -`,
and writes files/fakecap-manifest.tsv (path\telement\tinterval) for
fakecap-restore to consume.
"""
import json
import subprocess
import sys
import tarfile
import io
from pathlib import Path

MANIFEST_JSON = Path("usr-manifest.json")
OUTPUT_TSV = Path("files/fakecap-manifest.tsv")
DEFAULT_INTERVAL = "monthly"

# manifest.json records elements by their bare in-project name even when the
# element is actually owned by a content junction, so a bare checkout can
# 404 for junction-owned elements. This repo only has two content junctions
# (checked via `kind: junction` in elements/*.bst) — try the bare name first,
# then each of these, before giving up.
JUNCTION_PREFIXES = ["freedesktop-sdk.bst:", "gnome-build-meta.bst:"]


def element_names(manifest_path: Path) -> list[str]:
    data = json.loads(manifest_path.read_text())
    return sorted({m["name"] for m in data["modules"]})


def _checkout_tar(ref: str) -> bytes:
    # --deps none: an element's *own* artifact only, not its runtime closure
    # (default --deps run merges in every runtime dependency's files too).
    # --no-integrate: skip running integration commands (glib-compile-schemas,
    # update-mime-database, etc.) against the checked-out tree — their stdout
    # output otherwise interleaves with and corrupts the tar stream on fd 1.
    proc = subprocess.run(
        [
            "./mise/tasks/bst",
            "artifact",
            "checkout",
            "--tar",
            "-",
            "--deps",
            "none",
            "--no-integrate",
            ref,
        ],
        stdout=subprocess.PIPE,
        check=True,
    )
    return proc.stdout


def files_for_element(element: str) -> list[str]:
    """Return absolute in-image paths (leading '/') contributed by one element."""
    refs = [element] + [prefix + element for prefix in JUNCTION_PREFIXES]
    last_exc: subprocess.CalledProcessError | None = None
    tar_bytes: bytes | None = None
    for ref in refs:
        try:
            tar_bytes = _checkout_tar(ref)
            last_exc = None
            break
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            continue
    if last_exc is not None:
        raise last_exc

    paths = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tar:
        for member in tar.getmembers():
            if member.isfile() or member.issym():
                paths.append("/" + member.name.lstrip("/"))
    return paths


def main() -> int:
    if not MANIFEST_JSON.exists():
        print(
            f"error: {MANIFEST_JSON} not found. Extract /usr/manifest.json from "
            "localhost/krytis:latest first, e.g.:\n"
            "  podman run --rm localhost/krytis:latest cat /usr/manifest.json "
            f"> {MANIFEST_JSON}",
            file=sys.stderr,
        )
        return 1

    elements = element_names(MANIFEST_JSON)
    print(f"==> {len(elements)} elements in manifest", file=sys.stderr)

    rows: list[tuple[str, str, str]] = []
    for i, element in enumerate(elements, 1):
        print(f"==> [{i}/{len(elements)}] {element}", file=sys.stderr)
        try:
            paths = files_for_element(element)
        except (subprocess.CalledProcessError, tarfile.TarError) as exc:
            print(f"    skip (checkout/tar failed): {exc}", file=sys.stderr)
            continue
        for path in paths:
            rows.append((path, element, DEFAULT_INTERVAL))

    OUTPUT_TSV.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_TSV.open("w") as out:
        for path, element, interval in sorted(rows):
            out.write(f"{path}\t{element}\t{interval}\n")

    print(f"==> Wrote {len(rows)} rows to {OUTPUT_TSV}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
