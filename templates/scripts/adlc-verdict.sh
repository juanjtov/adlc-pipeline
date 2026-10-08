#!/usr/bin/env bash
# Guardrail helper: print the LAST verdict (PASS|CHANGES) for a marker, read from text on STDIN.
# Used by adlc-review.yml to decide the build→qa advance from the agents' comment markers
# (NOT from GitHub's review state — a bot can't formally approve its own PR).
#
# Usage:  <text with markers> | adlc-verdict.sh <marker>     e.g. ADLC-ADV
# Prints PASS or CHANGES. Prints nothing if no marker is found, or if the LAST marker line does
# not carry a clear verdict (lowercase, PASSED, …) — an earlier PASS never stands in for it, so
# the caller must treat empty as not-PASS.
set -euo pipefail
m="${1:?marker required (e.g. ADLC-ADV)}"
last="$(grep -E "(^|[^[:alnum:]_-])${m}:" | tail -1 || true)"
printf '%s\n' "$last" \
  | sed -nE "s/.*(^|[^[:alnum:]_-])${m}:[*\`_[:space:]]*(PASS|CHANGES)([^[:alnum:]_].*)?$/\2/p"
