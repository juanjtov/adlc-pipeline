#!/usr/bin/env bash
# Guardrail: decide whether the fix loop should STOP (cap passed) or GO. Used by adlc-fix.yml
# and the RUNBOOK's fix cycle to bound the review→fix→re-review loop.
#
# Usage:  adlc-fix-cap.sh --pr <pr> [max]      (default max=3; needs gh + jq, as adlc-rounds.sh)
#   Counts the PR's fix ROUNDS, the reviews that sent it back, as adlc-rounds.sh reads them from
#   the PR's own label events and verdict comments. Prints GO while rounds <= max, STOP when
#   rounds > max. The request being handled is itself one of the counted rounds: with max 3 the
#   first three requests for changes each get a Builder round and the fourth prints STOP.
#   Commits play no part, so several commits in one round, a subject without `adlc-fix:`, and
#   the fix commits a branch carries from another PR all change nothing. A count that cannot be
#   read is exit 1 with nothing on stdout, never a GO.
#
# Older form, kept for a workflow or RUNBOOK copy that still pipes `git log` into it. It counts
# COMMITS, not rounds:
#         subjects=$(git log --format='%s' origin/<base>..HEAD)
#         printf '%s\n' "$subjects" | adlc-fix-cap.sh [max]     (default max=3)
#   Reads commit subjects on STDIN (one per line) and prints STOP (>= max 'adlc-fix:' or
#   'adlc-fix(<scope>):' subjects) or GO. Feed it the commits of ONE pull request, and read them
#   in a statement of their own, not in a pipe from git: a failed read is empty input, and empty
#   input prints GO. A bare number is this form's max, never a PR: `adlc-fix-cap.sh 42` with
#   nothing on stdin prints GO. The PR form needs `--pr`.
# A max, or a PR number, that is not a whole number is an error (exit 2), never a GO.
set -euo pipefail
if [ "${1:-}" = "--pr" ]; then
  pr="${2:-}"; max="${3:-3}"
  case "$pr" in ''|*[!0-9]*) echo "--pr needs a PR number, got '$pr'" >&2; exit 2 ;; esac
  case "$max" in ''|*[!0-9]*) echo "max must be a whole number, got '$max'" >&2; exit 2 ;; esac
  # through bash, by this script's own folder: a copy without its exec bit, or run from another
  # directory, still finds it
  n="$(bash "$(dirname "$0")/adlc-rounds.sh" "$pr")" \
    || { echo "adlc-fix-cap: could not count the fix rounds of PR #$pr; no decision" >&2; exit 1; }
  case "$n" in ''|*[!0-9]*) echo "adlc-fix-cap: adlc-rounds.sh did not print a number for PR #$pr; no decision" >&2; exit 1 ;; esac
  if [ "$n" -gt "$max" ]; then echo STOP; else echo GO; fi
  exit 0
fi
max="${1:-3}"
case "$max" in ''|*[!0-9]*) echo "max must be a whole number, got '$max'" >&2; exit 2 ;; esac
n=$(grep -cE '^adlc-fix(\([^)]*\))?:' || true)
if [ "${n:-0}" -ge "$max" ]; then echo STOP; else echo GO; fi
