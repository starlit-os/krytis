FROM localhost/krytis-input:latest AS base

RUN bootc container lint

# Uncomment to set a temporary root password for VM login during debugging.
# Remove before shipping — not for production use.
# RUN echo 'root:krytis' | chpasswd

# Conditional secure boot sealing — gated by build arg.
# mise build (unsigned) skips this; mise run seal-uki enables it.
#
# Stage 2 (sealed): prepare the FINAL rootfs contents — sign systemd-boot —
# BEFORE the composefs digest is computed (see Containerfile.seal-uki, which
# picks up from this stage as a squashed, standalone image). `bootc install
# to-disk` recomputes the digest over whatever image it installs and
# verifies it against the composefs= parameter baked into the UKI; if the
# rootfs mutates between ukify and the final image, the digests differ and
# install fails with "The UKI has the wrong composefs= parameter". This is
# the LAST stage in this file on purpose — see docs/skills/secure-boot.md
# § `bootc container ukify` must run in a throwaway stage, never the final
# image for why UKI generation moved to a separate Containerfile entirely.
FROM base AS sealed
ARG SEAL_SECURE_BOOT=false

# Public Microsoft UEFI CA certs (files/microsoft-uefi-certs/, committed) —
# bundled into db.auth below so third-party EFI binaries keep working.
COPY files/microsoft-uefi-certs/ /tmp/microsoft-uefi-certs/

# PK/KEK secrets are needed by the .auth enrollment-file generation below, not by
# sbsign. The bind of `base` at /target that used to be here went away with the
# inline `bootc container ukify` — that now runs in Containerfile.seal-uki.
# The two halves of .auth generation deliberately use DIFFERENT toolkits, because
# each upstream gets one of them wrong (#438):
#
#   signature LISTS -> sbsigntools `sbsiglist`.  efitools'
#     `cert-to-efi-sig-list` takes PEM, and given the DER produced below it
#     writes a well-formed but EMPTY list and exits 0. Every .auth krytis shipped
#     before #438 enrolled an allow-list containing no certificates, so a machine
#     that enrolled them turned Secure Boot on and then refused krytis's own
#     correctly signed loader. Keep every input DER; do not "simplify" by
#     dropping the openssl conversions below.
#
#   SIGNATURES -> efitools `sign-efi-sig-list`.  This half was never broken.
#     sbsigntools' `sbvarsign` writes the EFI_TIME month straight from a 0-based
#     `tm_mon`, so an August build is stamped July and a January build would be
#     stamped month 0 — not a valid EFI_TIME, and UEFI compares these timestamps
#     for authenticated-variable rollback protection. Verified against the wall
#     clock: sbvarsign 2026-07-02, sign-efi-sig-list 2026-08-02.
#
# `assert_esl` is the build-time gate for the empty-list failure: one X509 entry
# is 28 + 16 + len(DER) bytes, so the SignatureSize field at offset 24 is 16 for
# an empty list and 16 + len(DER) for a real one. It fails the build instead of
# the boot. `mise run enroll-test` is the runtime gate.
#
# No `#` comments inside the RUN below — the Dockerfile parser joins
# `\`-continued lines, so a comment would swallow the command after it.
RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        set -ex && \
        mkdir -p /var/tmp /usr/lib/bootc/install/secureboot-keys/auto && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        GUID=$(cat /proc/sys/kernel/random/uuid) && \
        openssl x509 -in /run/secrets/pk_crt -outform DER -out /tmp/PK.der && \
        openssl x509 -in /run/secrets/kek_crt -outform DER -out /tmp/KEK.der && \
        openssl x509 -in /run/secrets/db_crt -outform DER -out /tmp/db.der && \
        assert_esl() { \
            sz=$(od -An -tu4 -j24 -N4 "$1" | tr -d ' ') && \
            [ "$sz" -gt 16 ] || { \
                echo "FATAL: $1 has SignatureSize=$sz — the signature list carries no certificate." >&2; \
                echo "       Enrolling it would turn Secure Boot on with an empty allow-list and" >&2; \
                echo "       the firmware would then refuse our own signed loader. See #438." >&2; \
                exit 1; \
            }; \
        }; \
        sbsiglist --owner "$GUID" --type x509 --output /tmp/PK.esl /tmp/PK.der && \
        sbsiglist --owner "$GUID" --type x509 --output /tmp/KEK.esl /tmp/KEK.der && \
        sbsiglist --owner "$GUID" --type x509 --output /tmp/db.esl /tmp/db.der && \
        assert_esl /tmp/PK.esl && assert_esl /tmp/KEK.esl && assert_esl /tmp/db.esl && \
        for ms in /tmp/microsoft-uefi-certs/*.der; do \
            sbsiglist --owner "$GUID" --type x509 --output /tmp/ms-entry.esl "$ms" && \
            assert_esl /tmp/ms-entry.esl && \
            cat /tmp/ms-entry.esl >> /tmp/db.esl && \
            rm /tmp/ms-entry.esl ; \
        done && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/pk_key -c /run/secrets/pk_crt \
            PK /tmp/PK.esl /usr/lib/bootc/install/secureboot-keys/auto/PK.auth && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/pk_key -c /run/secrets/pk_crt \
            KEK /tmp/KEK.esl /usr/lib/bootc/install/secureboot-keys/auto/KEK.auth && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/kek_key -c /run/secrets/kek_crt \
            db /tmp/db.esl /usr/lib/bootc/install/secureboot-keys/auto/db.auth && \
        assert_esl /tmp/microsoft-uefi-certs/dbx.esl && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/kek_key -c /run/secrets/kek_crt \
            dbx /tmp/microsoft-uefi-certs/dbx.esl \
            /usr/lib/bootc/install/secureboot-keys/auto/dbx.auth && \
        rm -f /tmp/PK.der /tmp/KEK.der /tmp/db.der /tmp/PK.esl /tmp/KEK.esl /tmp/db.esl \
    ; fi
