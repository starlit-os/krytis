#!/usr/bin/env bash
# Reclaim disk on the always-on krytis-vps runner (issue #938).
#
# Run weekly by .github/workflows/runner-vps-gc.yml (on the box, as a job)
# and on demand by `mise run runner-vps:gc` (over SSH, from a dev machine).
# Both paths execute this exact file, so they cannot drift apart.
#
# Set GC_DRY_RUN=1 to report reclaimable space without deleting anything.
#
# ---------------------------------------------------------------------------
# THE CAS DISTINCTION — read before editing anything below
#
# Measured 2026-09-24, with no build running:
#
#     /root/.cache/buildstream/cas/objects   47G
#     /root/.cache/buildstream/cas/tmp       24G
#     /root/.cache/buildstream/cas/staging   56K
#
# These two large directories need opposite treatment, and conflating them
# is the easiest way to turn this script into a corruption source.
#
# objects/ is casd-managed content-addressed storage. NEVER delete from it
# by hand: removing a blob some artifact still references breaks the
# invariant that a referenced digest is present, and it surfaces later as a
# corrupt-cache error in an unrelated build rather than here.
# docs/skills/ci-runner.md § Clearing the CAS records that BuildStream has
# no native `artifact gc`, so there is no safe incremental command either —
# the only supported operation is removing the whole cache, a recovery
# procedure rather than a weekly job. It also does not need one: 47G sits
# under the `cache: quota: 50G` that cache-warm.yml writes, so casd is
# enforcing its cap correctly.
#
# tmp/ is casd's per-session scratch, and 24G of it is orphaned. casd unlinks
# these on clean shutdown; a killed casd never does, and nothing else ever
# will. This box has a documented history of exactly that — see
# docs/skills/ci-runner.md § An OOM must not decommission the runner, which
# records two OOM kills inside 24h. That 24G accounts for essentially the
# whole 91G (2026-09-17) → 115G (2026-09-24) ratchet.
#
# Clearing tmp/ is safe only while no casd is running, which this script
# verifies rather than assumes. Two independent things make that check
# reliable rather than a race: a self-hosted runner executes one job at a
# time, so the weekly GC job cannot overlap a build, and the guard below
# refuses to proceed if a casd process exists anyway.
# ---------------------------------------------------------------------------
#
# Shared box: it also carries ghcr.io/stryan/materia:stable,
# henrygd/beszel-agent, fedora-minimal, debian:bookworm and busybox.
# `podman system prune -a` would delete those, which is why this script only
# ever prunes *dangling* images plus krytis-owned tags named explicitly.

set -euo pipefail

DRY_RUN="${GC_DRY_RUN:-0}"
BST_CACHE="/root/.cache/buildstream"

if [ "${DRY_RUN}" = "1" ]; then
    echo "==> DRY RUN — reporting only, nothing will be deleted."
fi

BEFORE_KB=$(df -Pk / | awk 'NR==2 {print $3}')
echo "==> Disk before:"
df -h /

run() {
    if [ "${DRY_RUN}" = "1" ]; then
        echo "    would run: $*"
    else
        "$@" || echo "    (non-fatal: $* failed)"
    fi
}

# --- Orphaned casd scratch --------------------------------------------------
# The single largest reclaim on this box. Guarded, not assumed: if any casd
# is alive its tmp/ entries may be live staging for an in-flight write.
echo "==> casd scratch (${BST_CACHE}/cas/tmp):"
if [ ! -d "${BST_CACHE}/cas/tmp" ]; then
    echo "    absent — nothing to do"
elif pgrep -x buildbox-casd >/dev/null 2>&1; then
    echo "    SKIPPED: buildbox-casd is running, so tmp/ entries may be live."
    echo "    $(pgrep -a -x buildbox-casd)"
else
    echo "    $(du -sh "${BST_CACHE}/cas/tmp" | cut -f1) orphaned, no casd running"
    # Delete contents, not the directory: casd expects tmp/ to exist and
    # recreating it with the wrong owner or mode would break the next build.
    run find "${BST_CACHE}/cas/tmp" -mindepth 1 -delete
fi

# --- Dangling podman images -------------------------------------------------
# Untagged layers orphaned when a tag is rebuilt or moved. build-iso.yml
# rebuilds localhost/krytis-installer and the iso-tools image on every run,
# so each dispatch strands the previous build's layer set. Dangling-only: an
# image still referenced by a tag, a running container, or another project
# on this shared box is never a candidate.
echo "==> Dangling images:"
podman images --filter dangling=true --format '    {{.ID}} {{.Size}}' 2>/dev/null || true
run podman image prune -f

# --- krytis build intermediates ---------------------------------------------
# localhost/krytis:iso-payload (8.23G) is produced by `mise run build-iso`
# and is absent from build-iso.yml's own "Clean up local images" list, so it
# survives every run. That list is the durable fix and is corrected
# alongside this script; this is the backstop for images already stranded,
# and for any run killed before its cleanup step could execute.
#
# Safe unconditionally: each is rebuilt from the published image on the next
# dispatch, and podman refuses to remove an image a running container uses.
for tag in \
    localhost/krytis:iso-payload \
    localhost/krytis-installer:latest \
    localhost/iso-tools:latest
do
    if podman image exists "${tag}" 2>/dev/null; then
        echo "==> Removing stale build intermediate: ${tag}"
        run podman rmi -f "${tag}"
    fi
done

# --- BuildStream logs -------------------------------------------------------
# 275M as measured — small, but pure history BuildStream never reads back,
# and it only grows. Unlike objects/ these are plain files under no
# content-addressed invariant. Keeps a week for post-mortems on a failed
# scheduled build.
if [ -d "${BST_CACHE}/logs" ]; then
    echo "==> BuildStream logs: $(du -sh "${BST_CACHE}/logs" | cut -f1)"
    run find "${BST_CACHE}/logs" -type f -mtime +7 -delete
fi

# --- Journal ----------------------------------------------------------------
# The box ships no retention policy, so the journal grows unbounded. 137M
# today; the cap matters more than today's reclaim.
echo "==> Journal: $(journalctl --disk-usage 2>/dev/null || echo unknown)"
run journalctl --vacuum-size=200M

# --- apt cache --------------------------------------------------------------
# 276M of .debs already installed by provision.sh; apt never needs them again.
echo "==> apt cache: $(du -sh /var/cache/apt 2>/dev/null | cut -f1 || echo unknown)"
run apt-get clean

# --- Report -----------------------------------------------------------------
AFTER_KB=$(df -Pk / | awk 'NR==2 {print $3}')
echo "==> Disk after:"
df -h /

if [ "${DRY_RUN}" = "1" ]; then
    echo "==> Dry run complete — no space reclaimed by design."
else
    echo "==> Reclaimed $(( (BEFORE_KB - AFTER_KB) / 1024 )) MB."
fi

echo "==> cas/objects (deliberately untouched): $(du -sh "${BST_CACHE}/cas/objects" 2>/dev/null | cut -f1 || echo absent)"

# Reclaiming nothing is a success: the box was already tidy. A weekly cron
# that goes red for that trains people to ignore it.
exit 0
