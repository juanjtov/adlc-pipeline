#!/usr/bin/env bash
# Guardrail helper: print the issue number a lane branch names, or nothing. The Builder works on
# `feat/<issue>-<slug>`, so the branch says which .adlc/scope/<issue>.txt applies. Used by the
# local pre-commit hook, and by adlc-diff-scope.yml when a PR has no closing reference.
#
# Usage:  adlc-branch-issue.sh <branch>      feat/12-add-login → 12 · feat/012-x → 12 · main → (nothing)
set -euo pipefail
printf '%s\n' "${1:-}" | sed -n 's|^[^/]*/0*\([0-9][0-9]*\)\(-.*\)\{0,1\}$|\1|p'
