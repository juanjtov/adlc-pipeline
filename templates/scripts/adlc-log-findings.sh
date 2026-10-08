#!/usr/bin/env bash
# Findings logger — turn reviewer comment text into ledger JSONL. The durable store is the PR
# COMMENTS themselves (per-repo, native, and the reviewer can already write them); this
# materializes .adlc/metrics/findings.jsonl from them, so nothing has to commit files from CI.
#
# Reviewers emit one machine-readable line per finding in their PR comment:
#     ADLC-FINDING: <severity> | <class> | <file>
# This reads such text on STDIN and prints one JSONL object per finding. The marker must start
# the line (list, numbered, quote, heading or bold markup aside) and carry all three fields;
# anything else is skipped.
#
# Usage:  <comment text> | adlc-log-findings.sh <pr> <stage>
#   e.g.  gh pr view 42 --json comments --jq '.comments[].body' \
#           | adlc-log-findings.sh 42 review >> .adlc/metrics/findings.jsonl
set -euo pipefail
pr="${1:-0}"; stage="${2:-review}"
case "$pr" in ''|*[!0-9]*) echo "pr must be a number, got '$pr'" >&2; exit 2 ;; esac
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
trim() { sed -E 's/^[[:space:]*`]+//; s/[[:space:]*`]+$//'; }   # markup at the ends only: src/db/*.py keeps its *

# the marker may follow list, numbered, quote, heading or bold markup, nothing else
{ grep -E '^([[:space:]>*_#-]|[0-9]+[.)])*ADLC-FINDING:' || true; } | while IFS= read -r line; do
  body="${line#*ADLC-FINDING:}"
  sev="$(printf '%s\n' "$body" | cut -s -d'|' -f1 | trim)"
  cls="$(printf '%s\n' "$body" | cut -s -d'|' -f2 | trim)"
  fil="$(printf '%s\n' "$body" | cut -s -d'|' -f3 | trim)"
  if [ -z "$sev" ] || [ -z "$cls" ] || [ -z "$fil" ]; then continue; fi
  case "$sev" in *'<'*) continue ;; esac   # the format line itself, quoted in a comment
  jq -cn --arg ts "$ts" --argjson pr "$pr" --arg stage "$stage" \
         --arg severity "$sev" --arg class "$cls" --arg file "$fil" \
    '{ts:$ts, pr:$pr, stage:$stage, severity:$severity, class:$class, file:$file}'
done
