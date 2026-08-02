#!/usr/bin/env python3
"""Print what an EFI_VARIABLE_AUTHENTICATION_2 (.auth) file would actually enroll.

Exits non-zero if any signature list carries a zero-length certificate — the
failure that shipped as #438, where `cert-to-efi-sig-list` was handed DER
(it takes PEM), silently wrote empty lists, and the firmware duly enrolled an
allow-list containing nothing. Secure Boot then came up refusing every binary,
including krytis's own correctly signed loader.

The cheap tell is arithmetic: one X509 entry occupies 28 (EFI_SIGNATURE_LIST
header) + 16 (owner GUID) + len(DER) bytes, so a list at 44 bytes is empty by
construction and SignatureSize is 16 rather than 16 + len(DER).

Usage: parse-efi-auth.py <file.auth> [...]
"""

import pathlib
import struct
import subprocess
import sys
import uuid

X509_GUID = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
SHA256_GUID = uuid.UUID("c1c41626-504c-4092-aca9-41f936934328")
PKCS7_GUID = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7")


def subject(der: bytes) -> str:
    """Certificate subject via openssl, or "" when the DER does not parse."""
    if not der:
        return ""
    out = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-subject"],
        input=der, capture_output=True,
    ).stdout.decode(errors="replace").strip()
    return out.removeprefix("subject=").strip()


def check(path: str) -> bool:
    data = pathlib.Path(path).read_bytes()
    if len(data) < 16 + 24:
        print(f"{path}: FAIL — too short to be an EFI_VARIABLE_AUTHENTICATION_2 ({len(data)} bytes)")
        return False

    year, month, day, hour, minute, sec = struct.unpack_from("<HBBBBB", data, 0)
    dw_length, _rev, _ctype = struct.unpack_from("<IHH", data, 16)
    cert_type = uuid.UUID(bytes_le=data[24:40])
    payload = data[16 + dw_length:]

    print(f"{path} ({len(data)} bytes)")
    print(f"  timestamp {year:04d}-{month:02d}-{day:02d} {hour:02d}:{minute:02d}:{sec:02d}"
          f"   signature {'PKCS7' if cert_type == PKCS7_GUID else f'UNEXPECTED {cert_type}'}"
          f" ({dw_length - 24} bytes)   payload {len(payload)} bytes")

    if not payload:
        print("  FAIL — no signature-list payload at all")
        return False

    ok, pos, lists = True, 0, 0
    while pos + 28 <= len(payload):
        list_type = uuid.UUID(bytes_le=payload[pos:pos + 16])
        list_size, header_size, sig_size = struct.unpack_from("<III", payload, pos + 16)
        if list_size < 28 or pos + list_size > len(payload):
            print(f"  FAIL — malformed signature list at offset {pos} (size {list_size})")
            return False

        entries = (list_size - 28 - header_size) // sig_size if sig_size else 0
        base = pos + 28 + header_size

        if list_type == SHA256_GUID:
            # dbx is mostly SHA-256 image hashes, not certificates. A revocation
            # entry is 16 bytes of owner GUID + a 32-byte digest, so SignatureSize
            # is 48 and there is nothing for openssl to parse. Counting them is the
            # check that matters: an empty dbx revokes nothing, which is exactly the
            # #446 hazard.
            if sig_size != 48:
                print(f"  FAIL — SHA-256 list with SignatureSize={sig_size}, expected 48")
                ok = False
            elif entries == 0:
                print("  FAIL — SHA-256 list with no entries: this revokes nothing")
                ok = False
            else:
                print(f"  {entries} revoked sha256 image hash(es)")
        elif list_type == X509_GUID:
            for _ in range(entries):
                der = payload[base + 16:base + sig_size]
                if not der:
                    print(f"  FAIL — empty certificate (SignatureSize={sig_size}, "
                          f"so this list enrolls nothing)")
                    ok = False
                else:
                    name = subject(der)
                    if name:
                        print(f"  cert {len(der):5d} bytes  {name}")
                    else:
                        print(f"  FAIL — {len(der)} bytes of certificate data that openssl cannot parse")
                        ok = False
                base += sig_size
        else:
            # Not a failure by itself — the UEFI spec allows other signature types
            # (SHA-1/384/512, RSA2048) — but flag it so an unexpected list is seen.
            print(f"  note — {entries} entry(s) of unhandled list type {list_type}")
            if entries == 0:
                print("  FAIL — list carries no entries")
                ok = False

        pos += list_size
        lists += 1

    if lists == 0:
        print("  FAIL — payload contains no signature lists")
        ok = False
    return ok


def count_esl(path: str) -> int:
    """Print how many entries a bare signature list holds. Used by CI to describe a
    dbx refresh ("443 -> 461 revocations") without re-implementing the walk."""
    payload = pathlib.Path(path).read_bytes()
    total = pos = 0
    while pos + 28 <= len(payload):
        size, header, sig = struct.unpack_from("<III", payload, pos + 16)
        if size < 28 or pos + size > len(payload) or sig == 0:
            sys.exit(f"malformed signature list at offset {pos}")
        total += (size - 28 - header) // sig
        pos += size
    print(total)
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["--count-esl"]:
        if len(argv) != 2:
            sys.exit(f"usage: {sys.argv[0]} --count-esl <file.esl>")
        return count_esl(argv[1])
    if not argv:
        sys.exit(f"usage: {sys.argv[0]} [--count-esl] <file.auth> [...]")
    failures = [p for p in argv if not check(p)]
    if failures:
        print(f"\nFAIL: {len(failures)} of {len(argv)} file(s) would enrol nothing: "
              f"{', '.join(failures)}", file=sys.stderr)
        print("See #438 — cert-to-efi-sig-list takes PEM; feeding it DER yields empty lists.",
              file=sys.stderr)
        return 1
    print(f"\nOK: {len(argv)} file(s), every signature list carries entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
