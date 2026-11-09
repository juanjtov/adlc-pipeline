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
# per red run (green runs need none) finds the first failed step across the run's failed jobs, in
# the API's order (a fail-fast matrix lists cancelled legs beside the one that failed; those have
# no failed step and are passed over); when that step's name matches ADLC_SETUP_STEPS (a regex,
# case-insensitive) the run is `infra_failed` and leaves the iterations count: it neither adds a
# run nor makes its PR failed_first. Both numbers are printed, so the retro sees the test reds and
# the cycle-retro the provisioning reds. A run whose jobs cannot be read, or none of whose failed
# jobs names a failed step (cancelled, timed out), stays a plain failure. Runs are matched to a PR
# by branch and date, so a red run on no merged PR's branch is never looked up.
# The default regex is a heuristic on step names, anchored at the start of the name where a word
# is common in test steps too: the runner's own "Set up job" and "Post Run actions/…", checkout,
# installs, setup actions, caches, registry logins, provisioning, and creating an ephemeral
# database or branch anywhere in the name. "Login flow tests" or "Test cache invalidation" are not
# matched; a host whose test step starts with one of those words ("Install and test") sets its own.
#
# A run GitHub failed before it started is not a test signal either (issue 34). The doctor's rule,
# per run: it concluded `failure`, at most 60 s after it was created, and no step of it ran; that
# is what an exhausted Actions budget looks like, and any other reason GitHub fails a run before
# its first step reads the same. Such a run is `blocked`: it leaves the iterations count like an
# infra failure and gets a `blocked:` line of its own, printed only when there is one. The same
# `gh run view` call answers both questions, so this costs no call; a run that cannot be read
# stays a plain failure.
#
# Where the checks did not run on GitHub, adlc-local-ci.sh leaves one PR comment per battery run
# whose marker is `ADLC-CI: PASS|FAIL head <sha>`. Each such comment on a merged PR (its LAST
# marker, markup around it allowed, as the verdict markers are read) counts as one CI run of that
# PR, a FAIL as a red one, so a host with no Actions runs is not blind here. The comments come
# with the PR list above: no call more. A `local_ci:` line says how many were counted, only when
# there is one. The marker is a record anyone who can comment can write, not a gate. A battery
# that ran both on Actions and locally for one push counts twice.
ADLC_SETUP_STEPS="${ADLC_SETUP_STEPS:-^(set up |post run |run actions/|checkout|install|setup|provision|(restore |save )?cache|docker log ?in|log ?in to |create .*(branch|database|db))|ephemeral}"
oldest=$(echo "$prs" | jq -r '[.[].createdAt] | min // empty')
runs=$(gh run list --limit 500 --json databaseId,workflowName,headBranch,status,conclusion,createdAt,updatedAt \
        --jq "[.[] | select(.status == \"completed\" and .createdAt >= \"${oldest:-$SINCE}\" and (.workflowName | test(\"CI\"; \"i\")))]")
# the red runs on a merged PR's branch, after that PR was opened: the only ones whose steps matter.
# One line each: the run's id, then 1 when it concluded `failure` within 60 s of its creation.
red_ids=$(jq -rn --slurpfile runs <(echo "$runs") --slurpfile prs <(echo "$prs") '
  $runs[0] as $runs | $prs[0] as $prs
  | [$prs[] as $p | $runs[] | select(.headBranch == $p.headRefName and .createdAt >= $p.createdAt and .conclusion != "success")
     | {id: .databaseId, fast: (if .conclusion == "failure" and (((.updatedAt | fromdate?) // null) as $u | $u != null and $u - (.createdAt | fromdate) <= 60) then 1 else 0 end)}]
  | unique_by(.id)[] | "\(.id) \(.fast)"')
infra='[]'; blocked='[]'
while read -r id fast; do
  [ -n "$id" ] || continue
  # "<steps that ran>, a tab, <name of the first failed step>" (the name is empty when there is none)
  look=$(gh run view "$id" --json jobs --jq '"\([.jobs[]?.steps[]? | select(.conclusion != null and .conclusion != "" and .conclusion != "skipped")] | length)\t\([.jobs[]? | select(.conclusion == "failure" or .conclusion == "timed_out")
           | .steps[]? | select(.conclusion == "failure")] | first | .name // "")"' </dev/null 2>/dev/null) || continue
  IFS=$'\t' read -r ran step <<<"$look"
  if [ "$fast" = 1 ] && [ "$ran" = 0 ]; then
    blocked=$(jq -cn --argjson a "$blocked" --argjson id "$id" '$a + [$id]')
  elif [ -n "$step" ] && printf '%s' "$step" | grep -qiE "$ADLC_SETUP_STEPS"; then
    infra=$(jq -cn --argjson a "$infra" --argjson id "$id" '$a + [$id]')
  fi
done <<<"$red_ids"
# Both lists go in through file descriptors: 200 PRs with their comments overflow an argument.
jq -rn --slurpfile runs <(echo "$runs") --slurpfile prs <(echo "$prs") --argjson infra "$infra" --argjson blocked "$blocked" '
  # the local CI comments of one PR: the last ADLC-CI marker of each comment, PASS or FAIL
  def local_ci: [(.comments // [])[] | (.body // "")
    | [match("(?<![A-Za-z0-9_-])ADLC-CI:[*`_\\s]*(PASS|FAIL)[*`_\\s]+head[*`_\\s]+[0-9a-f]{40}(?![0-9a-f])"; "g").captures[0].string]
    | last | select(. != null)];
  $runs[0] as $runs | $prs[0] as $prs | ($infra + $blocked) as $out
  | [$prs[] as $p | ($p | local_ci) as $lc
   | ($runs | map(select(.headBranch == $p.headRefName and .createdAt >= $p.createdAt))) | select(length > 0 or ($lc | length) > 0)
   | {all: length,
      infra: ([.[] | select(.databaseId as $i | $infra | index($i))] | length),
      blocked: ([.[] | select(.databaseId as $i | $blocked | index($i))] | length),
      lc: ($lc | length), lcfail: ([$lc[] | select(. == "FAIL")] | length),
      n: (([.[] | select(.databaseId as $i | $out | index($i) | not)] | length) + ($lc | length)),
      red: (([.[] | select(.conclusion != "success" and (.databaseId as $i | $out | index($i) | not))] | length) + ([$lc[] | select(. == "FAIL")] | length))}] as $per
  | ($per | map(.all) | add // 0) as $all | ($per | map(.infra) | add // 0) as $inf | ($per | map(.blocked) | add // 0) as $blk
  | ($per | map(.lc) | add // 0) as $lc
  | ([$per[] | select(.n > 0)]) as $counted
  | "blocked: \($blk) / \($all) CI runs were failed by GitHub within 60 s with no step run (what an exhausted Actions budget looks like)" as $bline
  | if ($per | length) == 0 then "iterations_to_green: no CI runs found for the merged PRs of the window"
    elif ($counted | length) == 0 and $blk == 0 then "iterations_to_green: every CI run of the window\u0027s merged PRs failed in a setup step (\($inf) runs); no test signal",
         "infra_failed: \($inf) / \($all) CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran"
    elif ($counted | length) == 0 then "iterations_to_green: every CI run of the window\u0027s merged PRs was blocked or failed in a setup step (\($blk + $inf) runs); no test signal",
         "infra_failed: \($inf) / \($all) CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran",
         $bline
    else "iterations_to_green: avg \(($counted | map(.n) | add) / ($counted | length) * 10 | round / 10) CI runs per merged PR; failed_first: \([$counted[] | select(.red > 0)] | length) / \($counted | length)",
         "infra_failed: \($inf) / \($all) CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran; not counted above",
         (if $blk > 0 then $bline + "; not counted above" else empty end),
         (if $lc > 0 then "local_ci: \($lc) ADLC-CI marker comments on \([$per[] | select(.lc > 0)] | length) merged PRs (\($per | map(.lcfail) | add // 0) FAIL), counted above as CI runs" else empty end)
    end'

# --- Change failure signal (defects Ops traced to a deploy) ---
# Issues labelled adlc:change-failure, which Ops puts beside `bug` on a defect it traced to a
# deploy. `bug` alone means any defect, however it was reported (intake adds it to every bug a
# person brings), so it is not what is counted. A repo whose labels predate this one (labels.sh
# not re-run) has no issue that could carry it: the line says so instead of a bare 0. One
# `gh label list` call more; if it fails the script stops there, as it does for the PR listing.
CF_LABEL="adlc:change-failure"
repo_labels=$(gh label list --limit 500 --json name --jq '.[].name')
if grep -qxF "$CF_LABEL" <<<"$repo_labels"; then
  cf=$(gh issue list --state all --label "$CF_LABEL" --limit 200 --json createdAt \
        --jq "[.[] | select(.createdAt >= \"$SINCE\")] | length")
  echo "change_failures: $cf"
else
  echo "change_failures: 0 (this repo has no $CF_LABEL label, so no issue carries it — run the plugin's templates/github/labels.sh)"
fi

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
