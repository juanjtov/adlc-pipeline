#!/usr/bin/env bash
# Guardrail: decide whether the fix loop should STOP (cap reached) or GO. Reads commit
# subjects on STDIN (one per line). Used by adlc-fix.yml to bound the review→fix→re-review loop.
# Feed it the commits of ONE pull request (`<base>..HEAD`), never a bare `git log`: the whole
# history also holds the fix commits of every PR already merged.
#
# Usage:  git log --format='%s' origin/<base>..HEAD | adlc-fix-cap.sh [max]     (default max=3)
# Prints STOP (>= max prior 'adlc-fix:' commits) or GO.
set -euo pipefail
max="${1:-3}"
n=$(grep -c '^adlc-fix:' || true)
if [ "${n:-0}" -ge "$max" ]; then echo STOP; else echo GO; fi
