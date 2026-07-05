# chunkah — composefs rechunking pipeline

Ported from dakota (`projectbluefin/dakota`) per #15. Splits the single-layer
krytis OCI image into up to 120 component-keyed layers so `bootc install
to-disk --composefs-backend` gets valid ostree splitstreams and OTA deltas
stay small.

## fakecap-restore (#29)

`files/fakecap/fakecap-restore.c` is a **host-side build tool**, not a BST
element — it is compiled ad hoc with `gcc -O2` by the `chunkify` mise task
(see below), matching dakota's own approach. It is *not* the same thing as
`freedesktop-sdk.bst:components/fakecap.bst` (an `LD_PRELOAD` shim used
during BST sandbox builds for fake capabilities) — same author lineage,
completely different purpose. Do not conflate the two when grepping for
"fakecap" in this repo.

chunkah reads `user.component` xattrs via rustix raw syscalls, bypassing
`LD_PRELOAD` — so the xattrs must be physically present on disk before
chunkah runs (coreos/chunkah#113, closed; overlay+physical-xattr is the
permanent resolution, not a future libc fallback).

fakecap-restore treats `ENOENT` (file absent in this image variant) and
`EPERM`/`ENOTSUP`/`EOPNOTSUPP` (symlinks and special files don't support
`user.*` xattrs) as expected skips, not errors — only genuine I/O errors
count toward its exit code.
