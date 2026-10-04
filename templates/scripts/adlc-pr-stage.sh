#!/usr/bin/env bash
# Guardrail helper: decide which diff-scope stage a PR is in. The lanes put `stage:*` on the
# linked ISSUE and never on the PR, so the issue decides; the PR's own labels are the fallback.
# Used by adlc-diff-scope.yml (which reads both label sets via `gh`) to pick the stage it
# hands to adlc-diff-scope.sh.
#
# Usage:  adlc-pr-stage.sh "<PR labels>" ["<linked-issue labels>"]     (one label per line)
# Prints exactly one of:
#   fast      PR `lane:fast` or issue `stage:fast`. Either is enough: the Builder adds the PR
#             label after `opened`, and a PASS moves the issue on to gate:deploy.
#   build     issue stage:build
#   build+qa  issue stage:qa (or gate:deploy with no stage left). QA commits its tests onto the
#             Builder's PR, so the PR diff holds both — a tests-only rule would fail it.
#   design | qa | build   from the PR's own stage:* label, when the issue gave no stage
#   other     not a lane PR — the scope check skips. This includes an issue at stage:design: no
#             lane opens a PR there, and a fast-lane PR bounced to design still holds its code.
set -euo pipefail
pr="${1:-}"; issue="${2:-}"
# exact, whole-label match (a `case`, not a pipe into grep -q: no SIGPIPE under pipefail)
has() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }

if   has "$pr" lane:fast || has "$issue" stage:fast; then echo fast
elif has "$issue" stage:qa;    then echo build+qa
elif has "$issue" stage:build; then echo build
elif has "$issue" gate:deploy; then echo build+qa
elif has "$pr" stage:design;   then echo design
elif has "$pr" stage:qa;       then echo qa
elif has "$pr" stage:build;    then echo build
else echo other
fi
