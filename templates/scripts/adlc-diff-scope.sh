#!/usr/bin/env bash
# Guardrail: fail if any changed file is outside the scope allowed for a stage.
# Single source of truth — used by adlc-diff-scope.yml (CI) AND the local pre-commit hook.
#
# Usage:  adlc-diff-scope.sh <stage> [scope-file]
#   reads changed file paths on STDIN, one per line.
#   stage: design → docs/ only · qa → $ADLC_TEST_DIRS regex · build|fast → the scope-file
#          (default .adlc/scope.txt) · build+qa → the scope-file OR $ADLC_TEST_DIRS (a Builder
#          PR that QA has committed tests onto); anything else → skip (exit 0).
#   scope-file: one path prefix per line (a regex anchored at the start of the path, e.g.
#          `src/api/`); blank lines and `#` comments are ignored. The scope file itself is
#          always in scope. No scope file → the stage is advisory (skip).
#   ADLC_TEST_DIRS (env): regex alternation for the test dirs, e.g. "tests|backend/tests".
#   ADLC_SCOPE_IGNORE_INHERITED=1 (env; CI sets it — STDIN must then be the whole PR diff):
#          build / build+qa hold a PR to the scope file only when the PR itself changes it.
#          One left on the base branch by an earlier merged PR is not this PR's scope, so it
#          is advisory. `fast` ignores this: the fast-lane Builder always writes one.
set -euo pipefail
stage="${1:-}"; scope_file="${2:-.adlc/scope.txt}"
fail=0; self=""
deny() { echo "out-of-scope (stage:$stage): $1" >&2; fail=1; }
changed="$(cat)"

case "$stage" in
  design) pat='^docs/' ;;
  qa)     pat="^(${ADLC_TEST_DIRS:-tests})" ;;
  build|fast|build+qa)
    if [ ! -f "$scope_file" ]; then
      echo "no $scope_file — $stage-stage scope is advisory (skipped)"; exit 0
    fi
    if [ "${ADLC_SCOPE_IGNORE_INHERITED:-}" = 1 ] && [ "$stage" != fast ]; then
      case $'\n'"$changed"$'\n' in
        *$'\n'"$scope_file"$'\n'*) ;;
        *) echo "$scope_file was not changed by this PR (left by an earlier one) — $stage-stage scope is advisory (skipped)"; exit 0 ;;
      esac
    fi
    self="$scope_file"
    # Drop blank lines and comments: an empty alternative would match every path.
    allow="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$scope_file" | grep -vE '^(#|$)' | paste -sd '|' - || true)"
    [ "$stage" = "build+qa" ] && allow="${allow:+$allow|}${ADLC_TEST_DIRS:-tests}"
    # An empty scope file declares nothing in scope ('^$' matches no path), not everything.
    if [ -n "$allow" ]; then pat="^(${allow})"; else pat='^$'; fi ;;
  *) echo "no ADLC stage — skipped"; exit 0 ;;
esac

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ "$f" = "$self" ] && continue
  printf '%s\n' "$f" | grep -qE "$pat" || deny "$f"
done <<< "$changed"
exit "$fail"
