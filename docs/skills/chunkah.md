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

## fakecap-manifest.tsv generation (#28)

`mise generate-fakecap-manifest` extracts `/usr/manifest.json` from
`localhost/krytis:latest` (must already be built via `mise load-image &&
mise lint`), then for each element name in the manifest runs
`bst artifact checkout --tar - <element>` and records every file path that
element's own artifact contributes. This is `bst`'s per-element artifact
output, not a scan of the assembled image filesystem — it walks every
element in the closure, so it is slow (one `bst artifact checkout` per
element) but attributes files exactly the way dakota's dakota-side
"rechunk" process does conceptually, without needing dakota's tooling.

`files/fakecap-manifest.tsv` should be committed (same convention as
dakota) and regenerated whenever elements meaningfully change — there is
no CI job auto-regenerating it yet (dakota's `update-filemap.yml` has no
krytis equivalent); re-run the mise task manually and commit the diff.

All rows currently get `interval=monthly` — krytis doesn't yet distinguish
weekly/daily-changing components the way dakota's finer-grained interval
tagging does. This is fine for the initial port (YAGNI); revisit only if
OTA delta size becomes a problem.

**`--deps none --no-integrate` are required, not optional, on the checkout
command.** `bst artifact checkout --tar -` defaults to `--deps run
--integrate`. `--deps run` merges the target element's own artifact with
every one of its *runtime* dependencies' artifacts into one tree — so
without `--deps none` you get wildly over-broad attribution (e.g.
`config/greetd-config.bst`, whose own output is ~17 small config files,
pulled in `desktop/greetd.bst`, `desktop/noctalia-greeter.bst`,
`desktop/cage.bst`, `desktop/wlr-randr.bst`, `core/pam-u2f.bst` and their
transitive closures — a 2.6GB tarball for one config element). `--integrate`
(also default-on) runs integration commands (`glib-compile-schemas`,
`update-mime-database`, `gdk-pixbuf-query-loaders --update-cache`, etc.)
against the checked-out tree, and those commands' own stdout output gets
interleaved with the tar stream on the same fd — corrupting it
(`tarfile.ReadError: bad checksum`, reproduced on `config/greetd-config.bst`
specifically, but latent for any element with runtime `depends:` and an
integration command that prints to stdout). Both flags together give the
element's true own-artifact contents, matching the docstring's claim.

**Junction-owned elements need a junction-prefixed ref, but
`/usr/manifest.json` doesn't record which junction owns them.** Element
names in the manifest are bare in-project paths (e.g. `components/curl.bst`,
`core-deps/upower.bst`) even when the element actually lives inside
`freedesktop-sdk.bst` or `gnome-build-meta.bst` — of the 565 elements in a
real krytis manifest, only ~96 are natively krytis's own (`config/*`,
`core/*`, `desktop/*`, `deps/*`, `integration/*`, `oci/*`, `overrides/*`,
`public-stacks/*`, `stacks/*`); the rest need `freedesktop-sdk.bst:` or
`gnome-build-meta.bst:` prepended to resolve
(`bst artifact checkout ... components/curl.bst` 404s;
`bst artifact checkout ... freedesktop-sdk.bst:components/curl.bst`
succeeds). `scripts/generate-fakecap-manifest.py` handles this by trying
the bare name first, then each of `JUNCTION_PREFIXES = ["freedesktop-sdk.bst:",
"gnome-build-meta.bst:"]` in order, before giving up — this repo only has
two content junctions (confirmed via `kind: junction` in `elements/*.bst`),
so a small hardcoded list is deliberate, not a stand-in for a general
junction-discovery mechanism.

With both fixes, a real run against `localhost/krytis:latest` (565
elements) attributed 539/565 (357043 rows); the remaining 26 are elements
with no own content under `--deps none` (e.g. `oci/krytis/stack.bst`,
`kind: stack` — pure dependency grouping with nothing of its own to check
out) plus a couple of `kind: script`-style elements — expected misses, not
a regression.

**Known low-severity risks, worth knowing but not worth fixing:** ~4.6% of
distinct paths in `files/fakecap-manifest.tsv` are attributed to more than
one element (e.g. shared config files installed by multiple related
elements, like `pipewire-base.bst` and `pipewire.bst` both touching the
same alsa conf file). Since the TSV is sorted by `(path, element)` and
`fakecap-restore` applies xattrs row-by-row, the alphabetically-last
element for a shared path wins the `user.component` xattr — deterministic,
and the file still lands in a valid chunkah layer either way, but which
element "owns" a shared file is arbitrary rather than semantically
meaningful. Separately, the junction-prefix retry above (bare name, then
each `JUNCTION_PREFIXES` entry in order) takes the first ref that resolves
successfully with no collision guard: if a bare-name checkout ever failed
and then coincidentally resolved under the *wrong* junction prefix (an
element with the same relative path existing in both junctions), files
would be silently misattributed to the wrong owning element. This hasn't
been observed in practice — the two junctions' element namespaces are
cleanly segregated by convention (`components/*`, `core-deps/*`,
`bootstrap/*` → freedesktop-sdk; `gnomeos*/*`, `vm/*`, `extensions/*` →
gnome-build-meta) — but nothing in the code enforces it. Both risks share
the same blast radius: at most a shared/ambiguous file lands in a
suboptimal but still-valid composefs layer for OTA-delta purposes — never
a boot failure or a missing/corrupted xattr.

**Cosmetic quirk:** every path in `files/fakecap-manifest.tsv` contains a
literal `/./` segment (e.g. `/./bin`, `/./etc/UPower/UPower.conf`) instead
of a clean `/bin` — `tarfile` member names come out of the tar as
`./bin`-style relative paths, and `"/" + member.name.lstrip("/")` only
strips leading slashes, not the leading `./`. Harmless (the kernel and
`lsetxattr` resolve `/merged/./bin` and `/merged/bin` identically) and not
worth fixing for a non-functional issue — just don't be confused by it when
reading the TSV.

## chunkify task (#30)

`mise chunkify` mounts `localhost/krytis:latest` as a writable overlay,
runs `fakecap-restore` to physically set `user.component` xattrs from
`files/fakecap-manifest.tsv`, then runs the pinned `chunkah` container
against the overlay and re-tags the result back onto the same image tag —
no new tag, so `mise generate-disk`'s existing `--composefs-backend` flag
(`mise/tasks/generate-disk:39`) needed no change.

**Overlay tmpdir disk-pressure fix**, ported from dakota's `e0b5a52`
(upstream `projectbluefin/dakota`, 2026-06-13 — confirmed via `git log
HEAD..upstream/main` that this is dakota's *current* logic, not a stale
snapshot): `fakecap-restore` triggers an overlayfs copy-up for every file
it touches, and the manifest can be hundreds of thousands of entries. On
a machine where root has little free space (BTRFS loopback CI runners,
constrained dev VMs), that exhausts `/var/tmp`. The task picks whichever
of `/var/lib/containers` or `/var/tmp` reports more free space via `df
--output=avail` for the overlay's upper/work/merged dirs.

**Podman "Loaded image" parsing** handles three known output formats
(`Loaded image: <ref>`, `Loaded image(s): <ref>`, and bare 64-char sha256
for untagged archives on some podman versions) — this is copied from
dakota verbatim since it is itself a defensive workaround for
podman-version skew, not something worth re-deriving.
