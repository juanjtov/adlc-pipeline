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
prs=$(gh pr list --state merged --limit 200 --json number,mergedAt,createdAt,changedFiles,comments,headRefName \
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

# --- Iterations-to-green (CI runs per merged PR branch) ---
# One `gh run list` call (the PR list above already carries each head branch and creation date): the
# completed CI runs since the window's oldest PR was opened, grouped by head branch. A merged PR's
# iterations = the ADLC CI runs its branch took after the PR was opened; failed_first = those PRs
# that did not go green on the first run. High values ⇒ flaky tests or vague specs (the cycle-retro's
# business, not a code finding). Two merged PRs that reused one branch name share its runs.
#
# A run that failed before any test ran is not a test signal. One `gh run view --json jobs` call
# per red run (green runs need none) finds the first failed step of its first failed job; when that
# step's name matches ADLC_SETUP_STEPS (a regex, case-insensitive; the default covers the runner's
# own "Set up job", checkout, dependency installs, caches, logins and ephemeral-database or branch
# provisioning), the run is `infra_failed` and leaves the iterations count: it neither adds a run
# nor makes its PR failed_first. Both numbers are printed, so the retro sees the test reds and the
# cycle-retro the provisioning reds. A run whose jobs cannot be read, or whose failed job names no
# failed step (a cancelled or timed-out run), stays a plain failure. Runs are matched to a PR by
# branch and date, so a red run on no merged PR's branch is never looked up.
ADLC_SETUP_STEPS="${ADLC_SETUP_STEPS:-^set up |checkout|install|setup|provision|ephemeral|cache|login|create .*(branch|database|db)}"
oldest=$(echo "$prs" | jq -r '[.[].createdAt] | min // empty')
runs=$(gh run list --limit 500 --json databaseId,workflowName,headBranch,status,conclusion,createdAt \
        --jq "[.[] | select(.status == \"completed\" and .createdAt >= \"${oldest:-$SINCE}\" and (.workflowName | test(\"CI\"; \"i\")))]")
# the red runs on a merged PR's branch, after that PR was opened: the only ones whose steps matter
red_ids=$(jq -rn --slurpfile runs <(echo "$runs") --slurpfile prs <(echo "$prs") '
  $runs[0] as $runs | $prs[0] as $prs
  | [$prs[] as $p | $runs[] | select(.headBranch == $p.headRefName and .createdAt >= $p.createdAt and .conclusion != "success") | .databaseId] | unique[]')
infra='[]'
for id in $red_ids; do
  step=$(gh run view "$id" --json jobs --jq '[.jobs[] | select(.conclusion != "success" and .conclusion != "skipped")] | first
           | [.steps[]? | select(.conclusion == "failure")] | first | .name // empty' 2>/dev/null) || step=""
  if [ -n "$step" ] && printf '%s' "$step" | grep -qiE "$ADLC_SETUP_STEPS"; then
    infra=$(jq -cn --argjson a "$infra" --argjson id "$id" '$a + [$id]')
  fi
done
# Both lists go in through file descriptors: 200 PRs with their comments overflow an argument.
jq -rn --slurpfile runs <(echo "$runs") --slurpfile prs <(echo "$prs") --argjson infra "$infra" '
  $runs[0] as $runs | $prs[0] as $prs
  | [$prs[] as $p | ($runs | map(select(.headBranch == $p.headRefName and .createdAt >= $p.createdAt))) | select(length > 0)
   | {all: length,
      infra: ([.[] | select(.databaseId as $i | $infra | index($i))] | length),
      n: ([.[] | select(.databaseId as $i | $infra | index($i) | not)] | length),
      red: ([.[] | select(.conclusion != "success" and (.databaseId as $i | $infra | index($i) | not))] | length)}] as $per
  | ($per | map(.all) | add // 0) as $all | ($per | map(.infra) | add // 0) as $inf
  | ([$per[] | select(.n > 0)]) as $counted
  | if ($per | length) == 0 then "iterations_to_green: no CI runs found for the merged PRs of the window"
    elif ($counted | length) == 0 then "iterations_to_green: every CI run of the window\u0027s merged PRs failed in a setup step (\($inf) runs); no test signal",
         "infra_failed: \($inf) / \($all) CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran"
    else "iterations_to_green: avg \(($counted | map(.n) | add) / ($counted | length) * 10 | round / 10) CI runs per merged PR; failed_first: \([$counted[] | select(.red > 0)] | length) / \($counted | length)",
         "infra_failed: \($inf) / \($all) CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran; not counted above"
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
