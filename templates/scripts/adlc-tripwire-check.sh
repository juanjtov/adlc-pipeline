#!/usr/bin/env bash
# Guardrail: fail if any pushed commit reached main without an associated PR (a direct push
# that bypassed the QA gate). Reads "<sha> <pr_count>" lines on STDIN. Used by
# adlc-main-tripwire.yml (which resolves pr_count per commit via `gh api`).
#
# Prints "OK" and exits 0 if every commit has a PR; prints "DIRECT: <shas>" and exits 1 otherwise.
# A count that is missing or not a whole number (a failed lookup) counts as no PR.
#
# Usage:  adlc-tripwire-check.sh range <forced> <before> <after>
#   Which commits a push event asks about, from the event's own fields, as `git rev-list`
#   arguments: `<before>..<after>`, or `<after> -n 1` when <before> is all zeros (the branch is
#   new). When <forced> is `true` the branch was force-pushed: <before> is no longer on it and
#   need not be in the clone at all, so there is no range to walk, and it prints `FORCED`
#   (exit 0; the workflow alerts on the rewrite itself). Exit 2 when <forced> is neither `true`
#   nor `false`, or a commit id is not hexadecimal: an event it cannot read is an error, not a pass.
set -euo pipefail
if [ "${1:-}" = range ]; then
  forced="${2:-}"; before="${3:-}"; after="${4:-}"
  for id in "$before" "$after"; do
    case "$id" in ''|*[!0-9a-fA-F]*) echo "adlc-tripwire-check: not a commit id: '${id}'" >&2; exit 2 ;; esac
  done
  case "$forced" in
    true)  echo FORCED ;;
    false) if [ -z "${before//0/}" ]; then echo "$after -n 1"; else echo "$before..$after"; fi ;;
    *)     echo "adlc-tripwire-check: forced must be true or false, got '${forced}'" >&2; exit 2 ;;
  esac
  exit 0
fi
direct=""
while read -r sha n _rest || [ -n "$sha" ]; do
  sha="${sha%$'\r'}"; n="${n%$'\r'}"
  [ -z "$sha" ] && continue
  case "$n" in ''|0|*[!0-9]*) direct="$direct $sha" ;; esac
done
if [ -n "$direct" ]; then echo "DIRECT:$direct"; exit 1; fi
echo "OK"
