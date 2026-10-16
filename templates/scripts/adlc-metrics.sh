#!/usr/bin/env bash
# ADLC metrics — derive self-improvement signals from GitHub + the finding ledger.
# Deterministic (GitHub is the source of truth); the retro skill reads this output.
# Usage: adlc-metrics.sh [DAYS]   (default 30). Requires: gh authenticated, jq.
set -euo pipefail
DAYS="${1:-30}"
SINCE=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
LEDGER="${CLAUDE_PROJECT_DIR:-.}/.adlc/metrics/findings.jsonl"

echo "# ADLC metrics — last ${DAYS}d (since ${SINCE})"

# --- Delivery (from merged PRs) ---
prs=$(gh pr list --state merged --limit 200 --json number,mergedAt,changedFiles,comments,headRefName \
        --jq "[.[] | select(.mergedAt >= \"$SINCE\")]")
merged=$(echo "$prs" | jq 'length')
echo "merged_prs: $merged"

# First-pass acceptance: merged PRs that never drew an `ADLC-ADV: CHANGES` or `ADLC-ARCH: CHANGES`
# verdict comment. The review lane carries build → qa on those comment markers (see
# adlc-verdict.sh), not on GitHub's review decision — a bot cannot formally approve its own PR,
# so reviewDecision reads APPROVED on none of the pipeline's PRs. One `gh pr list` call brings
# every PR's comments; a PR with no verdict comment at all (fast lane, a human's PR) counts as
# first-pass, exactly as a PR whose reviewers never asked for changes. A comment's verdict is its
# LAST marker, as adlc-verdict.sh reads it, so a comment that merely quotes "ADLC-ADV: CHANGES"
# in its prose and ends in PASS is a PASS.
firstpass=$(echo "$prs" | jq '[.[] | select(any(.comments[].body;
  [match("ADLC-(ADV|ARCH):\\s*(PASS|CHANGES)"; "g").captures[1].string] | last == "CHANGES") | not)] | length')
echo "first_pass_approved: $firstpass / $merged"

# --- Iterations-to-green (CI runs per merged PR branch) ---
# One `gh run list` call (the PR list above already carries each head branch): the completed CI runs of
# the window, grouped by head branch. A merged PR's
# iterations = the ADLC CI runs its branch took; failed_first = those that did not go green on the
# first run. High values ⇒ flaky tests or vague specs (the cycle-retro's business, not a code finding).
runs=$(gh run list --limit 500 --json workflowName,headBranch,status,conclusion,createdAt \
        --jq "[.[] | select(.status == \"completed\" and .createdAt >= \"$SINCE\" and (.workflowName | test(\"CI\"; \"i\")))]")
branches=$(echo "$prs" | jq '[.[].headRefName]')
jq -rn --argjson runs "$runs" --argjson branches "$branches" '
  [$branches[] as $b | ($runs | map(select(.headBranch == $b))) | select(length > 0)
   | {n: length, red: ([.[] | select(.conclusion != "success")] | length)}] as $per
  | if ($per | length) == 0 then "iterations_to_green: no CI runs found for the merged PRs of the window"
    else "iterations_to_green: avg \(($per | map(.n) | add) / ($per | length) * 10 | round / 10) CI runs per merged PR; failed_first: \([$per[] | select(.red > 0)] | length) / \($per | length)"
    end'

# --- Change failure signal (bugs filed by Ops after a deploy) ---
bugs=$(gh issue list --state all --label bug --limit 200 --json createdAt \
        --jq "[.[] | select(.createdAt >= \"$SINCE\")] | length")
echo "bugs_filed: $bugs"

# --- Finding classes (the compounding signal) ---
if [ -f "$LEDGER" ]; then
  echo "finding_classes (class: count  [top severity]):"
  jq -rs --arg since "$SINCE" '
    [.[] | select(.ts >= $since)]
    | group_by(.class)
    | map({class: .[0].class, n: length,
           worst: (map(.severity) | (index("Critical")//index("High")//index("Medium")//0))})
    | sort_by(-.n)[]
    | "  \(.class): \(.n)"' "$LEDGER" 2>/dev/null || echo "  (ledger present but unreadable)"
else
  echo "finding_classes: no ledger yet (.adlc/metrics/findings.jsonl) — reviewers append to it"
fi

echo "# Feed this to the retro skill: rank class × frequency × severity, propose the cheapest durable fix."
