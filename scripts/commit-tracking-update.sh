#!/usr/bin/env bash
# Point <branch> at one new commit on top of origin/main's tip, containing
# whatever changed (vs HEAD) under the given <path> arguments (files or
# directories), created via GitHub's createCommitOnBranch GraphQL mutation
# instead of `git commit && git push`.
#
# Why: github-actions[bot] has no settings page, so there is no way to
# attach a GPG/SSH signing key to it — its commits can never verify.
# GitHub auto-signs commits it creates itself via the API, regardless of
# caller credential, which is what lets these PRs merge once main
# requires signed commits. See #154, #699.
#
# Usage:
#   commit-tracking-update.sh <branch> <message-file> <path>...
#
# <path>... are files or directories, scanned for changes via
# `git diff --name-only HEAD` — this must run with the working tree still
# dirty from whatever step produced the update (mirrors the git-add scope
# of the block this replaces; a directory picks up every file that
# actually changed under it, not just the expected one).
#
# Requires: gh (authenticated, contents:write on the target repo), jq.

set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <branch> <message-file> <path>..." >&2
  exit 2
fi

BRANCH="$1"
MESSAGE_FILE="$2"
shift 2
# remaining args ("$@"): paths to scan for changes

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
MAIN_SHA=$(git rev-parse origin/main)

mapfile -t CHANGED < <(git diff --name-only HEAD -- "$@")
mapfile -t DELETED < <(git diff --name-only --diff-filter=D HEAD -- "$@")

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "commit-tracking-update: no changes detected under: $*" >&2
  exit 1
fi

# The commit is built on a throwaway scratch branch, and only then is $BRANCH
# moved onto it, in one ref update. $BRANCH must never point at main itself,
# not even for the moment between a reset and a commit: GitHub auto-closes an
# open PR whose head is 0 commits ahead of its base (PR #705), does so
# asynchronously (#1168 closed after this script had already listed it as
# open), and once it has registered the follow-up force-push it refuses to
# reopen the PR ("state cannot be changed. The … branch was force-pushed or
# recreated"). #1168 stranded an update that way until someone opened a
# new PR by hand. See docs/skills/bst.md § Signed commits via
# `scripts/commit-tracking-update.sh`.
#
# The scratch name sits outside auto/ so nothing that matches tracking
# branches by prefix sees it; run id + attempt keep parallel matrix jobs apart.
SCRATCH="tracking-scratch/${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-1}/$BRANCH"
cleanup_scratch() {
  gh api -X DELETE "repos/$REPO/git/refs/heads/$SCRATCH" >/dev/null 2>&1 || true
}
trap cleanup_scratch EXIT

echo "commit-tracking-update: building the commit on $SCRATCH (from main, $MAIN_SHA)"
gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$SCRATCH" -f sha="$MAIN_SHA" >/dev/null

# Build additions/deletions as proper JSON (not string concatenation) so
# base64 payloads and unicode paths can never break the request body.
ADDITIONS_JSON="[]"
for f in "${CHANGED[@]}"; do
  deleted=0
  for d in "${DELETED[@]:-}"; do
    [ -n "$d" ] && [ "$f" = "$d" ] && deleted=1
  done
  [ "$deleted" -eq 1 ] && continue
  content_b64=$(base64 -w0 -- "$f")
  ADDITIONS_JSON=$(jq -c --arg path "$f" --arg contents "$content_b64" \
    '. + [{path: $path, contents: $contents}]' <<<"$ADDITIONS_JSON")
done

DELETIONS_JSON="[]"
for f in "${DELETED[@]:-}"; do
  [ -z "$f" ] && continue
  DELETIONS_JSON=$(jq -c --arg path "$f" '. + [{path: $path}]' <<<"$DELETIONS_JSON")
done

echo "commit-tracking-update: committing ${#CHANGED[@]} file(s)"

QUERY='
mutation($repo: String!, $branch: String!, $oid: GitObjectID!, $headline: String!, $additions: [FileAddition!]!, $deletions: [FileDeletion!]!) {
  createCommitOnBranch(input: {
    branch: { repositoryNameWithOwner: $repo, branchName: $branch }
    message: { headline: $headline }
    expectedHeadOid: $oid
    fileChanges: { additions: $additions, deletions: $deletions }
  }) {
    commit { oid url }
  }
}'

COMMIT=$(jq -n \
  --arg query "$QUERY" \
  --arg repo "$REPO" \
  --arg branch "$SCRATCH" \
  --arg oid "$MAIN_SHA" \
  --rawfile headline "$MESSAGE_FILE" \
  --argjson additions "$ADDITIONS_JSON" \
  --argjson deletions "$DELETIONS_JSON" \
  '{
    query: $query,
    variables: {
      repo: $repo,
      branch: $branch,
      oid: $oid,
      headline: ($headline | rtrimstr("\n")),
      additions: $additions,
      deletions: $deletions
    }
  }' | gh api graphql --input - --jq '
    if .errors then
      (.errors | tostring) | halt_error(1)
    else
      .data.createCommitOnBranch.commit | .oid + " " + .url
    end
  ')
read -r NEW_OID NEW_URL <<<"$COMMIT"

echo "commit-tracking-update: moving $BRANCH to $NEW_OID"
if gh api "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" -f sha="$NEW_OID" -F force=true >/dev/null
else
  gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$NEW_OID" >/dev/null
fi
echo "Committed: $NEW_OID $NEW_URL"
