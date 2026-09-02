#!/usr/bin/env bash
# Reset <branch> to origin/main's tip and create one new commit there
# containing whatever changed (vs HEAD) under the given <path> arguments
# (files or directories), via GitHub's createCommitOnBranch GraphQL
# mutation instead of `git commit && git push`.
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

echo "commit-tracking-update: resetting $BRANCH to main ($MAIN_SHA)"
if gh api "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" -f sha="$MAIN_SHA" -F force=true >/dev/null
else
  gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$MAIN_SHA" >/dev/null
fi

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

echo "commit-tracking-update: committing ${#CHANGED[@]} file(s) to $BRANCH"

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

jq -n \
  --arg query "$QUERY" \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
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
      "Committed: " + .data.createCommitOnBranch.commit.oid + " " + .data.createCommitOnBranch.commit.url
    end
  '

# The ref-reset above briefly makes $BRANCH identical to main (0 commits
# ahead) before the commit above adds one back — GitHub reacts to that
# intermediate "nothing to merge" state by auto-closing any open PR for
# this branch (observed directly: #699 testing, PR #705). Reopen it if so
# — the alternative is a caller's `gh pr list --head "$BRANCH"` (open-only
# by default) finding nothing and creating a duplicate PR instead of
# updating the real one.
EXISTING_STATE=$(gh pr list --head "$BRANCH" --state all --json number,state,isDraft --jq '.[0]' 2>/dev/null || true)
if [ -n "$EXISTING_STATE" ]; then
  PR_NUMBER=$(jq -r '.number' <<<"$EXISTING_STATE")
  PR_STATE=$(jq -r '.state' <<<"$EXISTING_STATE")
  if [ "$PR_STATE" = "CLOSED" ]; then
    echo "commit-tracking-update: reopening PR #$PR_NUMBER (auto-closed by the ref reset above)"
    gh pr reopen "$PR_NUMBER" >/dev/null
  fi
fi
