#!/usr/bin/env bash
# Guardrail: fail if any pushed commit reached main without an associated PR (a direct push
# that bypassed the QA gate). Reads "<sha> <pr_count>" lines on STDIN. Used by
# adlc-main-tripwire.yml (which resolves pr_count per commit via `gh api`).
#
# Prints "OK" and exits 0 if every commit has a PR; prints "DIRECT: <shas>" and exits 1 otherwise.
# A count that is missing or not a whole number (a failed lookup) counts as no PR.
set -euo pipefail
direct=""
while read -r sha n _rest || [ -n "$sha" ]; do
  sha="${sha%$'\r'}"; n="${n%$'\r'}"
  [ -z "$sha" ] && continue
  case "$n" in ''|0|*[!0-9]*) direct="$direct $sha" ;; esac
done
if [ -n "$direct" ]; then echo "DIRECT:$direct"; exit 1; fi
echo "OK"
