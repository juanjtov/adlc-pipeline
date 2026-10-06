#!/usr/bin/env bash
# Guardrail: fail if any changed file is outside the scope allowed for a stage.
# Single source of truth — used by adlc-diff-scope.yml (CI) AND the local pre-commit hook.
#
# Usage:  adlc-diff-scope.sh <stage> [scope-file]
#   reads changed file paths on STDIN, one per line.
#   stage: design → docs/ only · qa → $ADLC_TEST_DIRS only · build|fast → the scope file ·
#          build+qa → the scope file OR $ADLC_TEST_DIRS (a Builder PR that QA has committed
#          tests onto) · other (or none) → skip (exit 0) · anything else → error (exit 2).
#   scope-file: the issue's declared scope, `.adlc/scope/<issue>.txt` — one path prefix per
#          line, matched literally (end a directory with `/`); blank lines and `#` comments are
#          ignored. The scope file itself is always in scope; ANOTHER issue's scope file never
#          is, whatever the prefixes say — left on the default branch it would be the scope a
#          later PR is held to, without that PR's diff showing it. A build/fast/build+qa stage
#          with no scope file FAILS: a lane PR must declare its scope.
#   ADLC_TEST_DIRS (env): regex alternation for the test dirs, e.g. "tests|backend/tests".
set -euo pipefail
stage="${1:-}"; scope_file="${2:-}"
fail=0; self=""; pat=""; prefixes=()
deny() { echo "out-of-scope (stage:$stage): $1" >&2; fail=1; }
changed="$(cat)"

case "$stage" in
  design) pat='^docs/' ;;
  qa)     pat="^(${ADLC_TEST_DIRS:-tests})" ;;
  build|fast|build+qa)
    if [ ! -f "$scope_file" ]; then
      echo "no scope file (${scope_file:-.adlc/scope/<issue>.txt}) — a $stage-stage PR must declare its scope" >&2
      exit 1
    fi
    self="$scope_file"
    while IFS= read -r p || [ -n "$p" ]; do prefixes+=("$p"); done \
      < <(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$scope_file" | head -n 501)
    if [ "${#prefixes[@]}" -gt 500 ]; then   # its size is the PR author's to choose
      echo "scope file $scope_file lists more than 500 prefixes — that is not a declared scope" >&2; exit 1
    fi
    if [ "$stage" = "build+qa" ]; then pat="^(${ADLC_TEST_DIRS:-tests})"; fi ;;
  ""|other) echo "no ADLC stage — skipped"; exit 0 ;;
  *) echo "unknown stage '$stage'" >&2; exit 2 ;;
esac

in_scope() { # <path>: the scope file itself, under a declared prefix, or matching the stage's regex
  local p
  [ "$1" = "$self" ] && return 0
  if [ "${#prefixes[@]}" -gt 0 ]; then
    for p in "${prefixes[@]}"; do case "$1" in "$p"*) return 0 ;; esac; done
  fi
  [ -n "$pat" ] && printf '%s\n' "$1" | grep -qE "$pat"
}

while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ -n "$self" ] && [ "$f" != "$self" ] && printf '%s\n' "$f" | grep -qE '^\.adlc/scope/[0-9]+\.txt$'; then
    deny "$f (another issue's scope file — a lane PR may change only its own)"
  else
    in_scope "$f" || deny "$f"
  fi
done <<< "$changed"
exit "$fail"
