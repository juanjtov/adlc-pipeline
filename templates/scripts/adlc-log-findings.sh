#!/usr/bin/env bash
# Findings logger — turn reviewer comment text into ledger JSONL. The durable store is the PR
# COMMENTS themselves (per-repo, native, and the reviewer can already write them); this
# materializes .adlc/metrics/findings.jsonl from them, so nothing has to commit files from CI.
#
# Reviewers emit one machine-readable line per finding in their PR comment:
#     ADLC-FINDING: <severity> | <class> | <file>
# This reads such text on STDIN and prints one JSONL object per finding. The marker must start
# the line (list, numbered, quote, heading, bold or code markup aside) and carry all three
# fields; anything else is skipped. A skipped line that still looks like a finding (three
# fields after the marker) is reported on stderr, so a marker shape this script does not read
# shows up instead of silently thinning the ledger.
#
# Usage:  <comment text> | adlc-log-findings.sh <pr> <stage> [ts]
#   ts    the comment's own time (ISO 8601, e.g. 2026-10-08T14:03:00Z), so the ledger can be
#         windowed by date: adlc-metrics.sh keeps the rows whose ts falls in its window. Without
#         it every row carries the time of this rebuild, and no window applies.
#   e.g.  gh pr view 42 --json comments,reviews \
#           --jq '(.comments[] | {ts: .createdAt, body}), (.reviews[] | {ts: .submittedAt, body}) | @json' \
#         | while IFS= read -r c; do
#             jq -r .body <<<"$c" | adlc-log-findings.sh 42 review "$(jq -r .ts <<<"$c")"
#           done >> .adlc/metrics/findings.jsonl
#   (both comment kinds: a reviewer that posts its findings as a review leaves them in a review
#   body, which `--json comments` alone never returns)
set -euo pipefail
pr="${1:-0}"; stage="${2:-review}"; ts="${3:-}"
case "$pr" in ''|*[!0-9]*) echo "pr must be a number, got '$pr'" >&2; exit 2 ;; esac
if [ -z "$ts" ]; then
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
    *) echo "ts must be an ISO 8601 time (YYYY-MM-DDThh:mm:ssZ), got '$ts'" >&2; exit 2 ;;
  esac
fi
trim() { sed -E 's/^[[:space:]*`]+//; s/[[:space:]*`]+$//'; }   # markup at the ends only: src/db/*.py keeps its *

# the marker may follow list, numbered, quote, heading, bold or code markup, nothing else
lead='^([[:space:]>*_#`-]|[0-9]+[.)])*ADLC-FINDING:'
skipped=0
skip() { skipped=$((skipped+1)); printf 'adlc-log-findings: PR %s: skipped a finding-shaped line it could not read: %.160s\n' "$pr" "$1" >&2; }

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in *ADLC-FINDING:*) ;; *) continue ;; esac
  body="${line#*ADLC-FINDING:}"
  # finding-shaped: three fields after the marker, and not the format line quoted in a comment
  shaped=0
  case "$body" in *'|'*'|'*) case "$body" in *'<'*) ;; *) shaped=1 ;; esac ;; esac
  if ! [[ "$line" =~ $lead ]]; then [ "$shaped" = 1 ] && skip "$line"; continue; fi
  sev="$(printf '%s\n' "$body" | cut -s -d'|' -f1 | trim)"
  cls="$(printf '%s\n' "$body" | cut -s -d'|' -f2 | trim)"
  fil="$(printf '%s\n' "$body" | cut -s -d'|' -f3 | trim)"
  if [ -z "$sev" ] || [ -z "$cls" ] || [ -z "$fil" ]; then [ "$shaped" = 1 ] && skip "$line"; continue; fi
  case "$sev" in *'<'*) continue ;; esac   # the format line itself, quoted in a comment
  jq -cn --arg ts "$ts" --argjson pr "$pr" --arg stage "$stage" \
         --arg severity "$sev" --arg class "$cls" --arg file "$fil" \
    '{ts:$ts, pr:$pr, stage:$stage, severity:$severity, class:$class, file:$file}'
done
