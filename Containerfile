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

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    --mount=type=bind,from=base,target=/target \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        mkdir -p /var/tmp /boot/EFI/Linux && \
        bootc container ukify --rootfs /target -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
    ; fi
