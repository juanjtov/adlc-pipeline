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
prs=$(gh pr list --state merged --limit 200 --json number,mergedAt,changedFiles,comments \
        --jq "[.[] | select(.mergedAt >= \"$SINCE\")]")
merged=$(echo "$prs" | jq 'length')
echo "merged_prs: $merged"

# First-pass acceptance: merged PRs that never drew an `ADLC-ADV: CHANGES` or `ADLC-ARCH: CHANGES`
# verdict comment. The review lane carries build → qa on those comment markers (see
# adlc-verdict.sh), not on GitHub's review decision — a bot cannot formally approve its own PR,
# so reviewDecision reads APPROVED on none of the pipeline's PRs. One `gh pr list` call brings
# every PR's comments; a PR with no verdict comment at all (fast lane, a human's PR) counts as
# first-pass, exactly as a PR whose reviewers never asked for changes. A comment's verdict is its
# LAST marker, so a comment that merely quotes "ADLC-ADV: CHANGES" in its prose and ends in PASS
# is a PASS. The marker is read as adlc-verdict.sh reads it: bold/backtick markup after the colon
# is fine, PASSED is not PASS. (That script takes the last marker LINE and reads an unclear one as
# empty; the two differ only when a comment's final marker line carries no clear verdict.)
firstpass=$(echo "$prs" | jq '[.[] | select(any(.comments[].body;
  [match("ADLC-(ADV|ARCH):[*`_\\s]*(PASS|CHANGES)(?![A-Za-z0-9_])"; "g").captures[1].string] | last == "CHANGES") | not)] | length')
echo "first_pass_approved: $firstpass / $merged"

# --- Iterations-to-green (CI runs per merged PR head) ---
echo "iterations_to_green: run 'gh run list --json ...' per PR head SHA; high values ⇒ flaky tests or vague specs"

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
