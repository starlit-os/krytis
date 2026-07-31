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
