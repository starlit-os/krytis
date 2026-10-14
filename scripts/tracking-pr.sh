#!/usr/bin/env bash
# Open or update the PR for a tracking branch. The PR stays a draft until the
# update on that branch has cooled.
#
# Usage:
#   tracking-pr.sh <branch> <title> <body-file>
#
# Run it right after scripts/commit-tracking-update.sh has moved <branch>. The
# cooldown state is read from the trailers that script writes on the branch
# head commit:
#   Tracking-First-Seen: <UTC>  when this PR's update was first committed
#   Tracking-Ready-At:   <UTC>  First-Seen + 24h
#   Tracking-Cooldown: exempt   source is first-party (kitten-lily/, starlit-os/)
#
# Before Ready-At, the PR is opened as a draft, or converted back to one, so
# it cannot be merged by accident. From Ready-At on, it is marked ready for
# review. A head commit with no trailers fails closed and counts as cooling.
# This is the BST-tracking counterpart of Renovate's minimumReleaseAge (see
# docs/skills/bst.md § Tracking cooldown: 24h from first sighting).
#
# Requires: gh (authenticated, pull-requests:write), GITHUB_REPOSITORY.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <branch> <title> <body-file>" >&2
  exit 2
fi

BRANCH="$1"
TITLE="$2"
BODY_FILE="$3"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"

HEAD_SHA=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
MESSAGE=$(gh api "repos/$REPO/git/commits/$HEAD_SHA" --jq '.message')
trailer() { sed -n "s/^$1: //p" <<<"$MESSAGE" | tail -n 1; }

FIRST_SEEN=$(trailer Tracking-First-Seen)
READY_AT=$(trailer Tracking-Ready-At)
EXEMPT=$(trailer Tracking-Cooldown)

BODY=$(cat "$BODY_FILE")
if [ -n "$EXEMPT" ]; then
  READY=1
  NOTE="> First-party source: no cooldown (\`Tracking-Cooldown: ${EXEMPT}\`)."
elif [ -n "$READY_AT" ] && [ "$(date -u +%s)" -ge "$(date -u -d "$READY_AT" +%s)" ]; then
  READY=1
  NOTE="> Cooled: first seen ${FIRST_SEEN}, ready since ${READY_AT}."
elif [ -n "$READY_AT" ]; then
  READY=0
  NOTE="> [!IMPORTANT]
> **Cooling until ${READY_AT}.** This update was first seen ${FIRST_SEEN}, and the PR stays a draft for 24h after that. A newer upstream release in the meantime keeps the clock; closing the PR restarts it. See \`docs/skills/bst.md\` § Tracking cooldown: 24h from first sighting."
else
  READY=0
  NOTE="> [!WARNING]
> **Cooling: the head commit carries no \`Tracking-Ready-At\` trailer**, so this PR stays a draft until a tracking run recommits it."
fi
printf '%s\n\n%s\n' "$NOTE" "$BODY" >"$BODY_FILE.cooldown"

EXISTING=$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number,isDraft,url \
  --jq '.[0] // empty' 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  PR_NUMBER=$(jq -r '.number' <<<"$EXISTING")
  IS_DRAFT=$(jq -r '.isDraft' <<<"$EXISTING")
  PR_URL=$(jq -r '.url' <<<"$EXISTING")
  echo "Updating existing PR #$PR_NUMBER"
  gh pr edit "$PR_NUMBER" -R "$REPO" --title "$TITLE" --body-file "$BODY_FILE.cooldown" >/dev/null
  if [ "$READY" -eq 1 ] && [ "$IS_DRAFT" = "true" ]; then
    echo "Cooled or exempt: marking PR #$PR_NUMBER ready for review"
    gh pr ready "$PR_NUMBER" -R "$REPO" >/dev/null
  elif [ "$READY" -eq 0 ] && [ "$IS_DRAFT" = "false" ]; then
    echo "Not cooled: converting PR #$PR_NUMBER back to draft"
    gh pr ready --undo "$PR_NUMBER" -R "$REPO" >/dev/null
  fi
else
  DRAFT=()
  [ "$READY" -eq 0 ] && DRAFT=(--draft)
  PR_URL=$(gh pr create -R "$REPO" "${DRAFT[@]}" \
    --base main \
    --head "$BRANCH" \
    --title "$TITLE" \
    --body-file "$BODY_FILE.cooldown")
fi
rm -f "$BODY_FILE.cooldown"

if [ "$READY" -eq 1 ]; then
  echo "PR (ready): $PR_URL"
else
  echo "PR (draft, cooling until ${READY_AT:-unknown}): $PR_URL"
fi
