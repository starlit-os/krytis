FROM localhost/krytis-input:latest AS base

RUN bootc container lint

# Uncomment to set a temporary root password for VM login during debugging.
# Remove before shipping — not for production use.
# RUN echo 'root:krytis' | chpasswd

# Conditional secure boot sealing — gated by build arg.
# mise build (unsigned) skips this; mise run seal-uki enables it.
#
# A second stage is required: `bootc container ukify` refuses to compute the
# composefs digest against the currently-building (active/mutable) rootfs and
# needs a separate, already-completed image bind-mounted as --rootfs. See
# docs/skills/secure-boot.md § bootc container ukify needs a separate rootfs.
FROM base AS sealed
ARG SEAL_SECURE_BOOT=false

# Public Microsoft UEFI CA certs (files/microsoft-uefi-certs/, committed) —
# bundled into db.auth below so third-party EFI binaries keep working.
COPY files/microsoft-uefi-certs/ /tmp/microsoft-uefi-certs/

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    --mount=type=bind,from=base,target=/target \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        set -ex && \
        mkdir -p /var/tmp /boot/EFI/Linux /usr/lib/bootc/install/secureboot-keys/auto && \
        bootc container ukify --rootfs /target -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        GUID=$(cat /proc/sys/kernel/random/uuid) && \
        openssl x509 -in /run/secrets/pk_crt -outform DER -out /tmp/PK.der && \
        openssl x509 -in /run/secrets/kek_crt -outform DER -out /tmp/KEK.der && \
        openssl x509 -in /run/secrets/db_crt -outform DER -out /tmp/db.der && \
        cert-to-efi-sig-list /tmp/PK.der /tmp/PK.esl && \
        cert-to-efi-sig-list /tmp/KEK.der /tmp/KEK.esl && \
        cert-to-efi-sig-list /tmp/db.der /tmp/db.esl && \
        for ms in /tmp/microsoft-uefi-certs/*.der; do \
            cert-to-efi-sig-list "$ms" /tmp/ms-entry.esl && \
            cat /tmp/ms-entry.esl >> /tmp/db.esl && \
            rm /tmp/ms-entry.esl ; \
        done && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/pk_key -c /run/secrets/pk_crt \
            PK /tmp/PK.esl /usr/lib/bootc/install/secureboot-keys/auto/PK.auth && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/pk_key -c /run/secrets/pk_crt \
            KEK /tmp/KEK.esl /usr/lib/bootc/install/secureboot-keys/auto/KEK.auth && \
        sign-efi-sig-list -g "$GUID" -k /run/secrets/kek_key -c /run/secrets/kek_crt \
            db /tmp/db.esl /usr/lib/bootc/install/secureboot-keys/auto/db.auth && \
        rm -f /tmp/PK.der /tmp/KEK.der /tmp/db.der /tmp/PK.esl /tmp/KEK.esl /tmp/db.esl \
    ; fi
