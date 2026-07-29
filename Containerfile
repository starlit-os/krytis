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

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        mkdir -p /var/tmp && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
        mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
            /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
    ; fi
