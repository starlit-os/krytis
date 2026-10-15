#!/usr/bin/env bash
# Decide which update a tracking branch carries and when it may leave draft.
# Run it after the update step and before anything reads the new version:
# when it holds back, it rewrites the working tree.
#
# Usage:
#   tracking-cooldown.sh <branch> <path>...
#
# <path>... must be the same paths later passed to
# scripts/commit-tracking-update.sh. The working tree holds the newest
# candidate, the only one the tracking jobs can produce.
#
# Every update cools for 24h from the first run that saw that exact content,
# like Renovate's minimumReleaseAge times each release from its own release.
# While the branch's open PR is still cooling (or cooled but unmerged), a
# newer candidate does not replace it. The PR's committed update is restored
# into the working tree, so the job's title and body describe what is
# committed. The newer candidate is only recorded, as Tracking-Next-*
# trailers. It is proposed when the held PR merges, or as soon as it has
# cooled itself. A fast mover therefore always has a PR that reaches ready:
# replacing the pending update on every new release never left draft
# (#1203, #1228), and carrying one clock across releases (#1270) let a release
# published minutes before Ready-At merge without cooling (#1271). See
# docs/skills/bst.md § Tracking cooldown: 24h per update.
#
# Writes the decision to $RUNNER_TEMP/tracking-cooldown/<branch>.env
# (TMPDIR or /tmp outside Actions), which commit-tracking-update.sh reads.
#
# Requires: gh (authenticated, pull-requests:read), git, GITHUB_REPOSITORY.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <branch> <path>..." >&2
  exit 2
fi

BRANCH="$1"
shift
PATHS=("$@")
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
COOLDOWN_SECONDS="${TRACKING_COOLDOWN_SECONDS:-86400}"
NOW=$(date -u +%s)

utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date -u -d "$1" +%s; }
log() { echo "tracking-cooldown: $*"; }

mapfile -t CANDIDATE < <(git diff --name-only HEAD -- "$@")
if [ "${#CANDIDATE[@]}" -eq 0 ]; then
  echo "tracking-cooldown: no changes under: $*" >&2
  exit 1
fi

# Content fingerprint: path + blob id of every changed file, sorted. It
# identifies the update itself, independent of the main it was diffed
# against, so a candidate recorded as Next still matches after the held PR
# merges. Rows are "<rev>:<path>" for a commit, or the working tree when <rev>
# is empty.
fingerprint() {
  local rev="$1" f blob
  shift
  for f in "$@"; do
    if [ -z "$rev" ]; then
      if [ -e "$f" ]; then blob=$(git hash-object -- "$f"); else blob=deleted; fi
    else
      blob=$(git rev-parse -q --verify "$rev:$f" 2>/dev/null) || blob=deleted
    fi
    printf '%s %s\n' "$blob" "$f"
  done | sort -k2 | sha256sum | cut -c1-64
}

# First-party sources skip the cooldown: the risk it guards against is a
# hijacked third-party release, not our own. That holds only when every
# changed file is an element whose primary (first) source lives under
# kitten-lily/ or starlit-os/. Anything else (a .bin, a mise task, a
# third-party element) cools.
first_party() {
  local f primary_url
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    if [[ "$f" != *.bst ]] || [ ! -f "$f" ]; then return 1; fi
    primary_url=$(grep -oP '^\s*url:\s*\K\S+' "$f" | head -n 1 || true)
    [[ "$primary_url" =~ (^|[:/])(kitten-lily|starlit-os)/ ]] || return 1
  done
}

STATE_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tracking-cooldown"
STATE_FILE="$STATE_DIR/${BRANCH//\//_}.env"
mkdir -p "$STATE_DIR"

# write_state <first-seen-epoch> [<next-fp> <next-seen-epoch>]
# The trailers describe the working tree as it is when this is called.
write_state() {
  local seen="$1" trailers
  mapfile -t FINAL < <(git diff --name-only HEAD -- "${PATHS[@]}")
  trailers="Tracking-First-Seen: $(utc "$seen")"
  if first_party "${FINAL[@]}"; then
    trailers+=$'\n'"Tracking-Cooldown: exempt (first-party source)"
    log "first-party source, no cooldown"
  else
    trailers+=$'\n'"Tracking-Ready-At: $(utc $((seen + COOLDOWN_SECONDS)))"
    log "first seen $(utc "$seen"), ready at $(utc $((seen + COOLDOWN_SECONDS)))"
  fi
  if [ "$#" -eq 3 ]; then
    trailers+=$'\n'"Tracking-Next-Fingerprint: $2"
    trailers+=$'\n'"Tracking-Next-First-Seen: $(utc "$3")"
    trailers+=$'\n'"Tracking-Next-Ready-At: $(utc $(($3 + COOLDOWN_SECONDS)))"
    log "newer candidate held back: first seen $(utc "$3"), cools at $(utc $(($3 + COOLDOWN_SECONDS)))"
  fi
  {
    printf 'TRACKING_PATHS=%q\n' "${PATHS[*]}"
    printf 'TRACKING_TRAILERS=%q\n' "$trailers"
  } >"$STATE_FILE"
}

CAND_FP=$(fingerprint "" "${CANDIDATE[@]}")

if first_party "${CANDIDATE[@]}"; then
  write_state "$NOW"
  exit 0
fi

# The newest PR for the branch is the only state there is: the branch is
# recreated on every run. An open PR's head is the held update. A merged PR's
# head still says when the candidate after it was first seen. A closed PR
# restarts the clock, and so does a failed lookup: it may delay, never skip.
PR=$(gh pr list -R "$REPO" --head "$BRANCH" --state all --limit 20 \
  --json number,state,headRefOid \
  --jq '(map(select(.state == "OPEN")) | first) // (max_by(.number)) // {}' \
  2>/dev/null) || PR=""
[ -n "$PR" ] || PR='{}'
PR_STATE=$(jq -r '.state // empty' <<<"$PR")
PR_NUMBER=$(jq -r '.number // empty' <<<"$PR")
HEAD_SHA=$(jq -r '.headRefOid // empty' <<<"$PR")

MESSAGE=""
if [ -n "$HEAD_SHA" ]; then
  # fetch-depth: 0 has every branch, and a merged head is reachable from main.
  # Fetch by id for anything else (a PR head pushed after checkout).
  git cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null ||
    git fetch -q --no-tags origin "$HEAD_SHA" 2>/dev/null || true
  MESSAGE=$(git log -1 --format=%B "$HEAD_SHA" 2>/dev/null) || {
    log "cannot read $HEAD_SHA, starting a fresh clock"
    PR_STATE=""
  }
fi
trailer() { sed -n "s/^$1: //p" <<<"$MESSAGE" | tail -n 1; }

# When was this exact candidate first seen? A previous run may have recorded
# it as the next update, on the open PR or on the PR that just merged.
CAND_SEEN="$NOW"
if [ "$PR_STATE" = OPEN ] || [ "$PR_STATE" = MERGED ]; then
  next_seen=$(trailer Tracking-Next-First-Seen)
  if [ "$(trailer Tracking-Next-Fingerprint)" = "$CAND_FP" ] && [ -n "$next_seen" ]; then
    CAND_SEEN=$(epoch "$next_seen")
  fi
fi

if [ "$PR_STATE" != OPEN ]; then
  log "no open PR (${PR_STATE:-none}): proposing the newest update"
  write_state "$CAND_SEEN"
  exit 0
fi

mapfile -t HELD < <(git diff --name-only "$HEAD_SHA^" "$HEAD_SHA" -- "${PATHS[@]}" 2>/dev/null || true)
HELD_SEEN_TRAILER=$(trailer Tracking-First-Seen)
HELD_SEEN=$NOW
if [ -n "$HELD_SEEN_TRAILER" ]; then HELD_SEEN=$(epoch "$HELD_SEEN_TRAILER"); fi

if [ "${#HELD[@]}" -gt 0 ] && [ "$(fingerprint "$HEAD_SHA" "${HELD[@]}")" = "$CAND_FP" ]; then
  log "PR #$PR_NUMBER already carries this update"
  write_state "$HELD_SEEN"
  exit 0
fi

if [ $((CAND_SEEN + COOLDOWN_SECONDS)) -le "$NOW" ]; then
  log "the newer update has cooled itself: it replaces PR #$PR_NUMBER's"
  write_state "$CAND_SEEN"
  exit 0
fi

# Hold: replay the PR's update onto the current main, as a 3-way merge
# against the main it was built on, so whatever main changed in the same files
# since then survives. A plain `git apply` refused any main edit within its 3
# context lines. If the merge conflicts, main changed the update's own lines
# (someone bumped the version by hand); if it comes out empty, main already
# has the update. Either way the hold is pointless and the newest candidate is
# proposed.
MERGED=""
if [ "${#HELD[@]}" -gt 0 ]; then
  MERGED=$(git merge-tree --write-tree --no-messages --merge-base="$HEAD_SHA^" HEAD "$HEAD_SHA" 2>/dev/null) || MERGED=""
fi
if [ -z "$MERGED" ] || git diff --quiet HEAD "$MERGED" -- "${PATHS[@]}"; then
  log "PR #$PR_NUMBER's update no longer applies to main: proposing the newest update"
  write_state "$CAND_SEEN"
  exit 0
fi

git restore --source="$MERGED" --worktree -- "${PATHS[@]}"
# Replayed onto a main that changed other lines of the same files, the held
# update can come out identical to the candidate. Then there is no newer one.
mapfile -t RESTORED < <(git diff --name-only HEAD -- "${PATHS[@]}")
if [ "$(fingerprint "" "${RESTORED[@]}")" = "$CAND_FP" ]; then
  log "PR #$PR_NUMBER already carries this update (replayed onto the newer main)"
  write_state "$HELD_SEEN"
else
  log "holding PR #$PR_NUMBER's update until it merges or the newer one cools"
  write_state "$HELD_SEEN" "$CAND_FP" "$CAND_SEEN"
fi
