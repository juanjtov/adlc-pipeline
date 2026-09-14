#!/usr/bin/env bash
# Guardrail helper: print the LAST verdict (PASS|CHANGES) for a marker, read from text on STDIN.
# Used by adlc-review.yml to decide the build→qa advance from the agents' comment markers
# (NOT from GitHub's review state — a bot can't formally approve its own PR).
#
# Usage:  <text with markers> | adlc-verdict.sh <marker>     e.g. ADLC-ADV
# Prints PASS or CHANGES (empty if no marker found).
set -euo pipefail
m="${1:?marker required (e.g. ADLC-ADV)}"
grep -oE "${m}:[[:space:]]*(PASS|CHANGES)" | grep -oE '(PASS|CHANGES)' | tail -1 || true
