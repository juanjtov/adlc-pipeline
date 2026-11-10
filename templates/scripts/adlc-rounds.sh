#!/usr/bin/env bash
# Fix rounds of ONE pull request: how many times a review sent it back. The one count behind the
# fix-loop cap (adlc-fix-cap.sh --pr) and the cycle ledger's `rounds` (adlc-cycle.sh); Mission
# Control applies the same rule to what it polls.
#
# A round is read from the PR's own record on GitHub, never from its commits: a Builder makes
# several commits in one round, and a branch can carry another PR's fix commits (a stacked PR
# whose parent was squash-merged, a promotion PR). Two sources:
#   1. the PR's `adlc:changes-requested` label events: the Actions review lane puts the label on
#      for each review that is not clean, and the fix loop takes it off before the Builder runs;
#   2. the PR's review verdict comments that asked for changes (`ADLC-ADV: CHANGES` /
#      `ADLC-ARCH: CHANGES`, read as adlc-metrics.sh reads them: a comment's LAST marker is its
#      verdict), counted per marker. A repo that runs the pipeline by hand (subagents from a
#      Principal's session) never applies the label, so there the comments are all there is.
# The result is the largest of the label events and either marker's count: the lane applies the
# label on the same verdict, so adding them would count one round twice, and both reviewers
# asking in one round is one round. The figure is an estimate, and usually low: a round the
# reviewers close as PASS-with-findings leaves no marker on GitHub at all, two rounds in which a
# different reviewer asked each time read as one where no label was applied, and a verdict posted
# as a GitHub review body is not read (only PR comments are). It reads high when a reviewer
# re-posts its CHANGES comment within one round, or when a thread's last marker is a quoted
# CHANGES, which the lane and adlc-metrics.sh read the same way. A label put on by hand counts
# as a round: it starts the fix loop too.
# Trust: every comment on the PR counts, whoever wrote it. Anyone who can comment (on a public
# repo, anyone) can raise the count and so bring the cap's STOP forward. Nobody can take it below
# the label events; the part only comments carry (all of it in a repo run by hand) goes down
# when a verdict comment is edited or deleted.
#
# Usage:  adlc-rounds.sh <pr>       prints a whole number
# Exit 2 on a bad argument. Exit 1, with a line on stderr and nothing on stdout, when the
# timeline or the comments cannot be read: a failed read is never 0 rounds.
# Requires: gh authenticated (GH_TOKEN in CI), jq. Cost: one timeline call + one `gh pr view`.
set -euo pipefail
pr="${1:-}"
case "$pr" in ''|*[!0-9]*) echo "usage: adlc-rounds.sh <pr number>" >&2; exit 2 ;; esac
[ $# -eq 1 ] || { echo "usage: adlc-rounds.sh <pr number>" >&2; exit 2; }

labels="$(gh api "repos/{owner}/{repo}/issues/$pr/timeline?per_page=100" --paginate --jq '.[]' \
  | jq -s '[.[] | select(.event == "labeled" and .label.name == "adlc:changes-requested")] | length')" \
  || { echo "adlc-rounds: could not read the timeline of PR #$pr" >&2; exit 1; }
verdicts="$(gh pr view "$pr" --json comments | jq '[.comments[].body
    | [match("ADLC-(ADV|ARCH):[*`_\\s]*(PASS|CHANGES)(?![A-Za-z0-9_])"; "g") | {m: .captures[0].string, v: .captures[1].string}]
    | select(length > 0) | last | select(.v == "CHANGES") | .m]
    | group_by(.) | map(length) | max // 0')" \
  || { echo "adlc-rounds: could not read the comments of PR #$pr" >&2; exit 1; }
for n in "$labels" "$verdicts"; do
  case "$n" in ''|*[!0-9]*) echo "adlc-rounds: the count for PR #$pr is not a number" >&2; exit 1 ;; esac
done
if [ "$labels" -ge "$verdicts" ]; then echo "$labels"; else echo "$verdicts"; fi
