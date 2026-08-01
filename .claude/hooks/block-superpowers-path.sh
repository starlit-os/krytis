#!/usr/bin/env bash
# PreToolUse hook — reject writes under docs/superpowers/.
#
# The `writing-plans` skill defaults to `docs/superpowers/plans/`. This repo
# uses `docs/design/` (living reference) and `docs/plans/` (dated execution
# plans) instead — see AGENTS.md § Plan & Design Docs. Prose alone does not
# reliably beat a skill default, so block the path.
set -euo pipefail

payload=$(cat)

if [[ "$payload" == *docs/superpowers* ]]; then
    echo 'docs/superpowers/ does not exist in this repo. Design docs go in docs/design/<topic>.md (undated, living reference); execution plans go in docs/plans/YYYY-MM-DD-<slug>.md, archived to docs/plans/done/ on merge. See AGENTS.md § Plan & Design Docs.' >&2
    exit 2
fi

exit 0
