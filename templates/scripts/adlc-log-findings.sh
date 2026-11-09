#!/usr/bin/env bash
# Findings logger — turn reviewer comment text into ledger JSONL. The durable store is the PR
# COMMENTS themselves (per-repo, native, and the reviewer can already write them); this
# materializes .adlc/metrics/findings.jsonl from them, so nothing has to commit files from CI.
#
# Reviewers emit one machine-readable line per finding in their PR comment:
#     ADLC-FINDING: <severity> | <class> | <file>
# This reads such text on STDIN and prints one JSONL object per finding. The marker must start
# the line (list, numbered, quote, heading, bold or code markup aside) and carry all three
# fields; anything else is skipped. A skipped line that still looks like a finding (a literal
# `ADLC-FINDING:` followed by three `|`-separated fields, the first not a `<placeholder>`) is
# reported on stderr, so a marker shape this script does not read shows up instead of silently
# thinning the ledger. Other spellings (another pipe character, a backtick before the colon,
# lower case) are neither read nor reported.
#
# The class is a CLOSED vocabulary (the list in the `edd-spec` skill; `adlc-log-findings.sh classes`
# prints it). The retro ranks by class x frequency, so one failure under five names reads as five
# small classes and never looks recurring: one host had 53 names for 144 findings, 78 four days
# later. The class is lower-cased, `_` and spaces become `-`, and a known synonym is written as its
# canonical name (`logic-bug` -> `logic-contradiction`, `test-coverage` -> `test-gap`, ...). A name
# outside the list is kept as written and reported once per run on stderr, so the retro can list it
# apart (or add it to the list, in the plugin, if it recurs).
#
# Usage:  <comment text> | adlc-log-findings.sh <pr> <stage> [ts]
#         adlc-log-findings.sh classes          the canonical class names, one per line
#   ts    the comment's own time (ISO 8601, e.g. 2026-10-08T14:03:00Z), so the ledger can be
#         windowed by date: adlc-metrics.sh keeps the rows whose ts falls in its window. Without
#         it every row carries the time of this rebuild, and no window applies.
#   e.g.  gh pr view 42 --json comments,reviews \
#           --jq '(.comments[] | {ts: .createdAt, body}), (.reviews[] | {ts: (.submittedAt // ""), body}) | @json' \
#         | while IFS= read -r c; do
#             jq -r .body <<<"$c" | adlc-log-findings.sh 42 review "$(jq -r .ts <<<"$c")"
#           done >> .adlc/metrics/findings.jsonl
#   (both comment kinds: a reviewer that posts its findings as a review leaves them in a review
#   body, which `--json comments` alone never returns)
set -euo pipefail
# The closed list. Canonical names first; each case line maps the spellings seen in the wild onto one.
# Keep this list and the table in skills/edd-spec/SKILL.md the same (a test checks it).
CLASSES="tenant-leak authz-gap injection secret-in-code hallucinated-api missing-edge-case logic-contradiction contract-violation test-gap flaky-test perf-regression doc-drift other"
canon() {
  local c
  c="$(printf '%s' "$1" | tr 'A-Z_ ' 'a-z--')"
  case "$c" in
    tenant-leak|tenant-isolation|cross-tenant|tenant-scope|scope-leak|idor)                    c=tenant-leak ;;   # idor: the security gate's tenant probe
    authz-gap|authz|authorization|auth-gap|authn-bypass|auth-bypass|permission-gap)               c=authz-gap ;;
    injection|sql-injection|sqli|command-injection|xss|prompt-injection|template-injection)      c=injection ;;
    secret-in-code|secret|secrets|hardcoded-secret|leaked-secret|credential-in-code)             c=secret-in-code ;;
    hallucinated-api|nonexistent-api|wrong-api|api-misuse|phantom-api|hallucination)             c=hallucinated-api ;;
    missing-edge-case|edge-case|edge-cases|boundary|unhandled-case|null-handling|error-handling)  c=missing-edge-case ;;
    logic-contradiction|logic-bug|logic-error|logic|wrong-logic|off-by-one|race-condition|correctness) c=logic-contradiction ;;
    contract-violation|contract-drift|spec-violation|spec-drift|spec-deviation|spec-gap|scope-breach|diff-scope|scope-violation) c=contract-violation ;;
    # not mapped on purpose: `drift`, `adr-drift`, `design-drift` — code that breaks a current ADR is
    # contract-violation, an ADR whose text went stale is doc-drift; the name alone cannot tell, so
    # it is reported and the reviewer picks.
    test-gap|test-coverage|missing-test|missing-tests|no-test|vacuous-test|weak-test|guard-gap|untested) c=test-gap ;;
    flaky-test|flaky|flakiness|nondeterministic-test)                                             c=flaky-test ;;
    perf-regression|performance|perf|n-plus-one|n+1|slow-query)                                   c=perf-regression ;;
    doc-drift|docs-drift|doc|docs|documentation|stale-docs|doc-gap|docs-gap)                      c=doc-drift ;;
    other|misc|uncategorized|unknown)                                                             c=other ;;
  esac
  printf '%s' "$c"
}
if [ "${1:-}" = classes ]; then printf '%s\n' $CLASSES; exit 0; fi
pr="${1:-0}"; stage="${2:-review}"; ts="${3:-}"
case "$pr" in ''|*[!0-9]*) echo "pr must be a number, got '$pr'" >&2; exit 2 ;; esac
if [ -z "$ts" ]; then
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) echo "adlc-log-findings: PR $pr: ts must be a UTC ISO 8601 time (YYYY-MM-DDThh:mm:ssZ, as GitHub prints it), got '$ts'" >&2; exit 2 ;;
  esac
fi
trim() { sed -E 's/^[[:space:]*`]+//; s/[[:space:]*`]+$//'; }   # markup at the ends only: src/db/*.py keeps its *

# the marker may follow list, numbered, quote, heading, bold or code markup, nothing else
lead='^([[:space:]>*_#`-]|[0-9]+[.)])*ADLC-FINDING:'
skipped=0
unknown=""
skip() { skipped=$((skipped+1)); printf 'adlc-log-findings: PR %s: skipped a finding-shaped line it could not read: %.160s\n' "$pr" "$1" >&2; }

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in *ADLC-FINDING:*) ;; *) continue ;; esac
  body="${line#*ADLC-FINDING:}"
  # finding-shaped: three fields after the marker, and not the format line quoted in a comment
  # (its first field is a <placeholder>)
  shaped=0
  case "$body" in *'|'*'|'*) case "${body%%|*}" in *'<'*) ;; *) shaped=1 ;; esac ;; esac
  if ! [[ "$line" =~ $lead ]]; then [ "$shaped" = 1 ] && skip "$line"; continue; fi
  sev="$(printf '%s\n' "$body" | cut -s -d'|' -f1 | trim)"
  cls="$(printf '%s\n' "$body" | cut -s -d'|' -f2 | trim)"
  fil="$(printf '%s\n' "$body" | cut -s -d'|' -f3)"
  # a code-wrapped marker ends at its closing backtick: prose after it is not part of the file
  case "${line%%ADLC-FINDING:*}" in *'`') fil="${fil%%\`*}" ;; esac
  fil="$(printf '%s\n' "$fil" | trim)"
  if [ -z "$sev" ] || [ -z "$cls" ] || [ -z "$fil" ]; then [ "$shaped" = 1 ] && skip "$line"; continue; fi
  case "$sev" in *'<'*) continue ;; esac   # the format line itself, quoted in a comment
  cls="$(canon "$cls")"
  case " $CLASSES " in *" $cls "*) ;; *)
    case " $unknown " in *" $cls "*) ;; *)
      unknown="$unknown $cls"
      echo "adlc-log-findings: PR $pr: class '$cls' is not in the list (adlc-log-findings.sh classes); logged as written" >&2 ;;
    esac ;;
  esac
  jq -cn --arg ts "$ts" --argjson pr "$pr" --arg stage "$stage" \
         --arg severity "$sev" --arg class "$cls" --arg file "$fil" \
    '{ts:$ts, pr:$pr, stage:$stage, severity:$severity, class:$class, file:$file}'
done
