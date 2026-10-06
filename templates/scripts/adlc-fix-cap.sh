#!/usr/bin/env bash
# Guardrail: decide whether the fix loop should STOP (cap reached) or GO. Reads commit
# subjects on STDIN (one per line). Used by adlc-fix.yml to bound the review→fix→re-review loop.
# Feed it the commits of ONE pull request (`<base>..HEAD`), never a bare `git log`: the whole
# history also holds the fix commits of every PR already merged. Read them in a statement of
# their own, not in a pipe from git: a failed read is empty input, and empty input prints GO.
#
# Usage:  subjects=$(git log --format='%s' origin/<base>..HEAD)
#         printf '%s\n' "$subjects" | adlc-fix-cap.sh [max]     (default max=3)
# Prints STOP (>= max prior 'adlc-fix:' commits) or GO.
set -euo pipefail
max="${1:-3}"
n=$(grep -c '^adlc-fix:' || true)
if [ "${n:-0}" -ge "$max" ]; then echo STOP; else echo GO; fi
