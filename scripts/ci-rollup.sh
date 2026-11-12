#!/usr/bin/env bash
# Roll every pull_request workflow run on one commit up into a single verdict
# (#1562). ci-passed.yml runs it so the ruleset can require one check, "CI
# passed", instead of a hand-kept list that silently misses each new gate.
#
#   scripts/ci-rollup.sh <head-sha> [required workflow name]...
#
# Waits until every pull_request-triggered workflow run on <head-sha> has
# finished, then exits 0 when each one's conclusion is success, skipped or
# neutral, and 1 otherwise. Needs `gh` and `jq` and a token that can read
# Actions (GH_TOKEN). Runs locally too: `scripts/ci-rollup.sh <sha>` against a
# PR's head tells you what the check would say.
#
# Why workflow runs, not check runs: a job behind `needs:` has no check run
# until the jobs it waits on finish. Between vuln-diff's `scan` jobs ending and
# its `diff` job being queued, every check run that exists is complete, and a
# check-run poll would pass a PR whose required gate hasn't started. A workflow
# run stays in_progress until its last job ends.
#
# Required names are a floor against the opposite race: this workflow can poll
# before GitHub has created a sibling run for the same event. A name that never
# appears within CI_ROLLUP_GRACE seconds fails the rollup rather than passing a
# commit that a gate never saw. Every other pull_request workflow is included
# automatically, so a new gate needs no edit here.
#
# Only the newest run of each workflow counts. checks.yml also runs on
# `edited`, and its concurrency cancels the older run; that cancelled run is
# superseded, not a failure.
#
# Env: GITHUB_REPOSITORY (owner/name), CI_ROLLUP_SELF (this workflow's name,
# excluded; default $GITHUB_WORKFLOW), CI_ROLLUP_POLL (seconds, default 30),
# CI_ROLLUP_GRACE (seconds, default 600).
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <head-sha> [required workflow name]..." >&2
  exit 2
fi

sha=$1
shift
repo=${GITHUB_REPOSITORY:-starlit-os/krytis}
self=${CI_ROLLUP_SELF:-${GITHUB_WORKFLOW:-CI passed}}
poll=${CI_ROLLUP_POLL:-30}
grace=${CI_ROLLUP_GRACE:-600}
required_json=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))')
start=$(date +%s)

while :; do
  # Newest run per workflow, this workflow excluded. --paginate --slurp keeps
  # it correct past 100 runs (a PR description edited many times).
  runs=$(gh api --paginate --slurp \
      "repos/${repo}/actions/runs?head_sha=${sha}&event=pull_request&per_page=100" |
    jq -c --arg self "$self" '
      [.[].workflow_runs[]]
      | map(select(.name != $self))
      | group_by(.workflow_id)
      | map(max_by(.created_at, .run_number))
      | map({name, status, conclusion, url: .html_url})
      | sort_by(.name)')

  missing=$(jq -r --argjson req "$required_json" \
    '($req - map(.name)) | .[]' <<<"$runs")
  pending=$(jq -r 'map(select(.status != "completed")) | .[] | "\(.name) (\(.status))"' <<<"$runs")
  elapsed=$(( $(date +%s) - start ))

  if [ -z "$missing" ] && [ -z "$pending" ]; then
    break
  fi
  if [ -n "$missing" ] && [ "$elapsed" -ge "$grace" ]; then
    echo "::error::required workflow(s) never started on ${sha} within ${grace}s:"
    sed 's/^/  /' <<<"$missing"
    exit 1
  fi

  echo "[$(date -u +%H:%M:%S)] waiting (${elapsed}s):" \
    "$(printf '%s' "$pending" | paste -sd ';' -)" \
    "${missing:+| not started: $(printf '%s' "$missing" | paste -sd ';' -)}"
  sleep "$poll"
done

echo "Workflow runs on ${sha}:"
jq -r '.[] | "  \(.conclusion // "none")\t\(.name)\t\(.url)"' <<<"$runs"

{
  echo "### CI rollup for \`${sha:0:12}\`"
  echo
  echo "| Workflow | Conclusion |"
  echo "|---|---|"
  jq -r '.[] | "| [\(.name)](\(.url)) | \(.conclusion) |"' <<<"$runs"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

failed=$(jq -r 'map(select(.conclusion as $c | ["success","skipped","neutral"] | index($c) | not))
  | .[] | "\(.name): \(.conclusion)"' <<<"$runs")
if [ -n "$failed" ]; then
  echo "::error::not every workflow passed:"
  sed 's/^/  /' <<<"$failed"
  exit 1
fi
echo "All $(jq length <<<"$runs") workflow(s) passed."
