#!/usr/bin/env bash
# Print the tag of the newest GitHub release that carries every named asset.
#
# Use this instead of `gh api repos/<repo>/releases/latest` in any updater
# that downloads a release asset by a fixed name. `releases/latest` only says
# which release is newest, not whether it has the file. It fails two ways:
#   - a release without our asset: libqalculate v5.13.2 (2026-10-10) is a
#     Windows-only rebuild with no source tarball, and track-libqalculate
#     404'd on every run;
#   - a release published before its assets finish uploading: any run inside
#     that window 404s on an asset that appears minutes or hours later.
# Here such a release is skipped. The updater stays on, or moves to, the
# newest release that has the files. See docs/skills/bst.md §
# `releases/latest` is not "the latest source release".
#
# Usage:
#   github-release-with-assets.sh [--current VER] [--strip-suffix SUFFIX] \
#       <owner/repo> <asset>...
#
# <asset> is an exact asset name, with these placeholders filled in per
# release:
#   {tag}  the release's tag_name
#   {ver}  the tag minus a leading "v" and minus SUFFIX (--strip-suffix),
#          e.g. libsodium's "1.0.20-RELEASE" -> "1.0.20"
#
# Releases are read newest first (the last 30); drafts and prereleases are
# ignored, as `releases/latest` ignores them. The walk stops at the first
# release that has every asset. It also stops at the release whose {ver}
# equals --current, and prints that release's tag: a newer release that lacks
# its assets must never send an updater backwards, and a current release
# whose assets were later deleted must read as "up to date", not as an error.
#
# Every newer release that was skipped is reported on stderr. Under GitHub
# Actions it is also appended to the step summary. A release that stays
# skipped because upstream renamed or dropped the asset is otherwise
# indistinguishable from "no new release" (#640).
#
# Exit status: 0 with the tag on stdout; 1 if no release among the last 30
# qualifies and none matches --current.

set -euo pipefail

CURRENT=""
SUFFIX=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --current) CURRENT="$2"; shift 2 ;;
    --strip-suffix) SUFFIX="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "github-release-with-assets: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ "$#" -lt 2 ]; then
  echo "usage: $0 [--current VER] [--strip-suffix SUFFIX] <owner/repo> <asset>..." >&2
  exit 2
fi

REPO="$1"
shift
TEMPLATES_JSON=$(jq -cn '$ARGS.positional' --args "$@")

# One row per published release, newest first: tag, ver, and which of the
# expanded asset names it lacks.
ROWS=$(gh api "repos/${REPO}/releases?per_page=30" | jq -c \
  --arg suffix "$SUFFIX" --argjson templates "$TEMPLATES_JSON" '
  .[] | select((.draft or .prerelease) | not)
  | .tag_name as $tag
  | ($tag | ltrimstr("v") | if $suffix == "" then . else rtrimstr($suffix) end) as $ver
  | [.assets[].name] as $have
  | {
      tag: $tag,
      ver: $ver,
      missing: [ $templates[]
                 | split("{tag}") | join($tag)
                 | split("{ver}") | join($ver)
                 | select(. as $n | $have | index($n) | not) ]
    }')

CHOSEN=""
SKIPPED=()
while IFS= read -r row; do
  [ -n "$row" ] || continue
  tag=$(jq -r '.tag' <<<"$row")
  ver=$(jq -r '.ver' <<<"$row")
  missing=$(jq -r '.missing | join(", ")' <<<"$row")
  if [ -z "$missing" ] || { [ -n "$CURRENT" ] && [ "$ver" = "$CURRENT" ]; }; then
    CHOSEN="$tag"
    break
  fi
  SKIPPED+=("${tag} (missing: ${missing})")
done <<<"$ROWS"

if [ "${#SKIPPED[@]}" -gt 0 ]; then
  for s in "${SKIPPED[@]}"; do
    echo "github-release-with-assets: ${REPO}: skipping ${s}" >&2
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "- \`${REPO}\`: skipped release ${s}" >>"$GITHUB_STEP_SUMMARY"
    fi
  done
fi

if [ -z "$CHOSEN" ]; then
  echo "github-release-with-assets: ${REPO}: no release among the last 30 carries: $*" >&2
  exit 1
fi

echo "$CHOSEN"
