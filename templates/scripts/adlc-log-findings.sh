#!/usr/bin/env bash
# Findings logger — turn reviewer comment text into ledger JSONL. The durable store is the PR
# COMMENTS themselves (per-repo, native, and the reviewer can already write them); this
# materializes .adlc/metrics/findings.jsonl from them, so nothing has to commit files from CI.
#
# Reviewers emit one machine-readable line per finding in their PR comment:
#     ADLC-FINDING: <severity> | <class> | <file>
# This reads such text on STDIN and prints one JSONL object per finding.
#
# Usage:  <comment text> | adlc-log-findings.sh <pr> <stage>
#   e.g.  gh pr view 42 --json comments --jq '.comments[].body' \
#           | adlc-log-findings.sh 42 review >> .adlc/metrics/findings.jsonl
set -euo pipefail
pr="${1:-0}"; stage="${2:-review}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

{ grep 'ADLC-FINDING:' || true; } | while IFS= read -r line; do
  body="${line#*ADLC-FINDING:}"
  sev="$(printf '%s' "$body" | cut -d'|' -f1 | trim)"
  cls="$(printf '%s' "$body" | cut -d'|' -f2 | trim)"
  fil="$(printf '%s' "$body" | cut -d'|' -f3 | trim)"
  [ -z "$sev$cls$fil" ] && continue
  printf '{"ts":"%s","pr":%s,"stage":"%s","severity":"%s","class":"%s","file":"%s"}\n' \
    "$ts" "$pr" "$stage" "$sev" "$cls" "$fil"
done
