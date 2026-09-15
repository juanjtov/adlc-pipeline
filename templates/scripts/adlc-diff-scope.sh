#!/usr/bin/env bash
# Guardrail: fail if any changed file is outside the scope allowed for a stage.
# Single source of truth — used by adlc-diff-scope.yml (CI) AND the local pre-commit hook.
#
# Usage:  adlc-diff-scope.sh <stage> [scope-file]
#   reads changed file paths on STDIN, one per line.
#   stage: design → docs/ only · qa → $ADLC_TEST_DIRS regex · build|fast → globs from
#          scope-file (default .adlc/scope.txt); anything else → skip (exit 0).
#   ADLC_TEST_DIRS (env): regex alternation for the qa stage, e.g. "tests|backend/tests".
set -euo pipefail
stage="${1:-}"; scope_file="${2:-.adlc/scope.txt}"
fail=0
deny() { echo "out-of-scope (stage:$stage): $1" >&2; fail=1; }

case "$stage" in
  design) pat='^docs/' ;;
  qa)     pat="^(${ADLC_TEST_DIRS:-tests})" ;;
  build|fast)
    if [ -f "$scope_file" ]; then
      pat="^($(paste -sd '|' "$scope_file"))"
    else
      echo "no $scope_file — $stage-stage scope is advisory (skipped)"; exit 0
    fi ;;
  *) echo "no ADLC stage — skipped"; exit 0 ;;
esac

while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$f" | grep -qE "$pat" || deny "$f"
done
exit "$fail"
