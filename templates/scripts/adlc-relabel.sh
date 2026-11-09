#!/usr/bin/env bash
# One state per issue. Moves an issue to a stage:*/gate:* label and takes every OTHER stage:*/gate:*
# label off it, in ONE `gh issue edit` call, so the issue is never seen with two states.
#
# Why a script: every lane and every role prompt used to spell out its own pair
# (`--remove-label stage:build --add-label stage:qa`), and the pairs drifted: QA's prompt said
# "add gate:deploy" and nothing took stage:qa off, so on one host 25 issues ended with
# `stage:qa` + `gate:deploy`, six more with `stage:fast` + `gate:deploy`. Two labels at once
# means two states: the cycle clock, Mission Control's station view and a lane keyed on the
# older label each pick their own. The doctor flags such issues; this is what fixes them, and
# what the lanes and the prompts call instead of a pair.
#
# Usage:  adlc-relabel.sh <issue> <stage:…|gate:…>
#   Reads the issue's labels (one `gh issue view`), then one `gh issue edit` that removes every
#   other stage:/gate: label and adds the new one (nothing when the issue is already there and
#   alone). Other labels (adlc:auto, lane:fast, bug, …) are not touched. Issues only: PRs carry
#   adlc:changes-requested / needs:human, not the state machine. Exit 2 on bad arguments, 1 when
#   gh fails (the labels are then as they were: nothing is written before the read succeeds).
#   A role that may not edit an issue's labels may not run this either: the guard hook judges it
#   as the `gh issue edit` it is.
set -euo pipefail
n="${1:-}"; new="${2:-}"
case "$n" in ''|*[!0-9]*) echo "adlc-relabel: the issue must be a number, got '${n}'" >&2; exit 2 ;; esac
case "$new" in stage:?*|gate:?*) ;; *) echo "adlc-relabel: the label must be a stage:* or gate:* label, got '${new}'" >&2; exit 2 ;; esac
current="$(gh issue view "$n" --json labels --jq '.labels[].name')" || { echo "adlc-relabel: could not read the labels of #${n}" >&2; exit 1; }
args=(); gone=""; there=""
while IFS= read -r l; do
  case "$l" in
    "$new")          there=1 ;;
    stage:*|gate:*)  args+=(--remove-label "$l"); gone="${gone}${gone:+ }${l}" ;;
  esac
done <<<"$current"
if [ -n "$there" ] && [ "${#args[@]}" -eq 0 ]; then echo "#${n} is at ${new} already"; exit 0; fi
[ -n "$there" ] || args+=(--add-label "$new")
gh issue edit "$n" "${args[@]}" >/dev/null || { echo "adlc-relabel: gh issue edit failed for #${n}" >&2; exit 1; }
echo "#${n}: ${gone:-(no state label)} → ${new}"
