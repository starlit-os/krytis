# Extra `dbx` revocations, beyond Microsoft's published list

Certificate-level (X509) revocations appended to `files/microsoft-uefi-certs/dbx.esl` by
`mise run fetch-microsoft-dbx`. Microsoft's `DBXUpdate.bin` for amd64 carries **443
sha256 hashes and zero X509 entries**, so these cannot come from that source and have to
be committed here.

## Why they exist — #502

Enrollment **replaces** `dbx` rather than merging. A Lenovo ThinkPad captured during T4
(#535) shipped a factory `dbx` of 430 sha256 hashes **plus two X509 CA revocations**.
Enrolling krytis's keys gained 13 hashes and lost both certificate revocations, so a
binary signed by either CA — whose chains reach `Microsoft Corporation UEFI CA 2011`,
which krytis's `db` trusts — became bootable on a machine whose firmware had refused it.

Shipping them restores parity with what the OEM enforced.

## What is revoked, and what is deliberately not

| file | subject | valid | superseded by |
|---|---|---|---|
| `canonical-secure-boot-signing-2012.der` | `C=GB, ST=Isle of Man, O=Canonical Ltd., OU=Secure Boot, CN=Canonical Ltd. Secure Boot Signing` | 2012-04-12 → 2042-04-11 | `… Secure Boot Signing (2022 v1)` |
| `debian-secure-boot-signer-2016.der` | `CN=Debian Secure Boot Signer` | 2016-08-16 → 2026-08-16 | Debian's rotated signer |

**Current Ubuntu and Debian media are unaffected.** Ubuntu's `shim-signed` 1.58+15.8
is signed by `Canonical Ltd. Secure Boot Signing (2022 v1)` — a different certificate,
not revoked here. What these entries refuse is anything still signed with the
pre-rotation certificates, which is the BootHole-era (CVE-2020-10713) material a
revocation exists to refuse.

That distinction matters: an earlier draft of #502 claimed option 1 would make
"Ubuntu/Debian shims unbootable". It does not — it makes *old* ones unbootable.

## Provenance

Extracted from the `dbx` EFI variable of a Lenovo ThinkPad (MTM 21HES06C1G, UEFI
N3QET52W) before enrollment, during the T4 run recorded in #535. Both entries carried
owner GUID `77fa9abd-0359-4d32-bd60-28f4e78f784b` — Microsoft's — so they originate from
a Microsoft-sourced revocation set even though they are absent from the currently
published `DBXUpdate.bin`.

```
canonical-secure-boot-signing-2012.der
  sha256 fingerprint  90:24:4C:C2:21:E0:0C:1F:E0:A7:B7:8B:3C:E9:45:DD:
                      73:BF:16:33:01:9E:B6:C1:5F:A5:64:6F:9C:8D:2E:1E
debian-secure-boot-signer-2016.der
  sha256 fingerprint  F1:56:D2:4F:5D:4E:77:5D:A0:E6:A9:11:1F:07:4C:FC:
                      E7:01:93:9D:68:8C:64:DB:A0:93:F9:77:53:43:4F:2C
```

Independently corroborated: Canonical's certificate name and issuer chain match the
`Canonical Ltd. Master Certificate Authority` chain visible in Ubuntu's own
`shim-signed` package, whose current signing certificate differs only by the
`(2022 v1)` suffix.

## Adding to this directory

Any `*.der` here is appended as its own X509 signature list. Before adding one, confirm
it is genuinely absent from Microsoft's list — a duplicate wastes `dbx` space and
obscures provenance:

```bash
mise run fetch-microsoft-dbx        # prints sha256/x509 counts and asserts each extra landed
```

Revoking a certificate is a **Security Gate** decision (AGENTS.md): it makes every
binary signed by that CA unbootable on an enrolled machine, and the blast radius is not
recoverable from inside the running system.
