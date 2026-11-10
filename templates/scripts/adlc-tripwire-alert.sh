#!/usr/bin/env bash
# Guardrail: file the tripwire's alert issue, once. Called by adlc-main-tripwire.yml when
# adlc-tripwire-check.sh found commits with no PR, or when the push event says the branch was
# force-pushed.
#
# Usage:  adlc-tripwire-alert.sh direct <sha>...           commits that reached the branch with no PR
#         adlc-tripwire-alert.sh forced <before> <after>   the branch was force-pushed
#   ADLC_TRIPWIRE_BRANCH (env): the branch's name, for the text (default main).
#   Requires: gh authenticated for the repo (issues: write), jq.
#
# One alert per event. The body ends with a machine-readable line, `ADLC-TRIPWIRE: direct <the
# commit ids, sorted>` or `ADLC-TRIPWIRE: forced <before> <after>`. Before filing, the script
# lists the OPEN issues labelled adlc:tripwire and files nothing when one of them carries that
# exact line: the tripwire once filed the same four commits twice, a minute apart. It then
# prints that issue's number and adds no comment to it (the workflow run fails either way). A
# closed alert does not count: the same commits flagged again after a close are filed again.
# A listing that fails holds nothing back: when in doubt the alert is filed. The check trusts
# the line wherever it is: any open issue it lists whose body already holds the exact line, put
# there by whoever could write that issue, holds back the alert for that set of commits (the
# workflow run still fails).
#
# The issue is filed with the label adlc:tripwire (labels.sh creates it; a direct push is a
# process breach, not a defect, so not `bug`). If that fails, as it does in a repo whose labels
# predate this one, it is filed without a label, after one more look for the same line among the
# newest 200 open issues of any label, since the first listing cannot see an unlabelled alert.
#
# Exit: 0 the alert is open (filed now, or it was already) · 1 it could not be filed ·
#       2 bad arguments.
set -uo pipefail
LABEL="adlc:tripwire"
branch="${ADLC_TRIPWIRE_BRANCH:-main}"
kind="${1:-}"; [ $# -gt 0 ] && shift
for id in "$@"; do
  case "$id" in ''|*[!0-9a-fA-F]*) echo "adlc-tripwire-alert: not a commit id: '${id}'" >&2; exit 2 ;; esac
done
case "$kind" in
  direct)
    [ $# -ge 1 ] || { echo "usage: adlc-tripwire-alert.sh direct <sha>..." >&2; exit 2; }
    shas="$(printf '%s\n' "$@" | LC_ALL=C sort -u | tr '\n' ' ')"; shas="${shas% }"
    key="ADLC-TRIPWIRE: direct ${shas}"
    title="⚠️ Direct push to ${branch} — bypassed the QA gate"
    body="These commits reached \`${branch}\` with no associated merged PR: ${shas}

Gate 2 requires merges go through the QA gate and Principal approval. If unintended,
revert and re-land through a PR. (ADLC tripwire — the Free-plan stand-in for branch protection.)" ;;
  forced)
    [ $# -eq 2 ] || { echo "usage: adlc-tripwire-alert.sh forced <before> <after>" >&2; exit 2; }
    key="ADLC-TRIPWIRE: forced $1 $2"
    title="⚠️ Force-push to ${branch} — its history was rewritten"
    body="\`${branch}\` was force-pushed: its tip moved from $1 to $2, so commits that were on the branch may no longer be on it.

Gate 2 requires merges go through the QA gate and Principal approval, and a rewrite of the
branch goes through neither. This run did not check the commits now on the branch one by one.
If unintended, restore the branch to $1 from a clone that still has that commit.
(ADLC tripwire — the Free-plan stand-in for branch protection.)" ;;
  *) echo "usage: adlc-tripwire-alert.sh direct <sha>... | forced <before> <after>" >&2; exit 2 ;;
esac
body="${body}

${key}"

open_alert() { # [gh issue list filters…]: prints the number of an open issue whose body has the key line, or nothing; fails when the listing does
  local list
  list=$(gh issue list --state open "$@" --limit 200 --json number,body) || return 1
  printf '%s' "$list" | jq -r --arg key "$key" \
    '[.[] | select((.body // "") | split("\n") | map(sub("\r$"; "")) | index($key)) | .number] | first // empty'
}
dup() { echo "already open: issue #$1 carries '${key}' — no second alert filed"; exit 0; }

if n=$(open_alert --label "$LABEL"); then
  [ -z "$n" ] || dup "$n"
else
  echo "adlc-tripwire-alert: could not list the open ${LABEL} issues — filing without the duplicate check" >&2
fi
if url=$(gh issue create --title "$title" --label "$LABEL" --body "$body"); then
  echo "filed: ${url}"; exit 0
fi
echo "adlc-tripwire-alert: could not file with the label ${LABEL} (labels.sh creates it) — filing without a label" >&2
if n=$(open_alert) && [ -n "$n" ]; then dup "$n"; fi
if url=$(gh issue create --title "$title" --body "$body"); then
  echo "filed without a label: ${url}"; exit 0
fi
echo "adlc-tripwire-alert: could not file the alert issue" >&2
exit 1
