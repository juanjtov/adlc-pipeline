#!/usr/bin/env bash
# Sizing: will this CI battery fit in the Actions minutes the plan includes? One multiplication,
# done before the workflows are copied, because a private repo that runs out of minutes does not
# slow down: GitHub fails every run of every workflow at once, the tripwire's included, and the
# checks on a PR just read red (adlc-doctor.sh and Mission Control report that state). On one host
# a battery of 17 to 23 job-minutes ran 4.6 times per merged PR and used about 8,000 minutes in a
# month against 2,000.
#
# Usage:  adlc-ci-budget.sh <minutes_per_run> <runs_per_pr> <prs_per_month> [included_minutes]
#   minutes_per_run   job-minutes one CI run is billed: the sum over its jobs (decimals allowed)
#   runs_per_pr       CI runs one PR takes until it merges (decimals allowed; 4 to 5 where unknown:
#                     every push to the PR branch is a run, and a fix round is a push)
#   prs_per_month     PRs opened a month (a whole number)
#   included_minutes  what the plan includes a month (a whole number; default 2000)
# Prints the estimate (rounded up to a whole minute), the included minutes, and one verdict line:
#   FITS: <n>% of the included minutes        exit 0   (the estimate is at most the included minutes)
#   OVER: <n>% of the included minutes (<f>x) exit 1
# Exit 2 on bad arguments: a missing one, one that is not a number, or a zero.
# An estimate, not a meter: it counts the CI battery only (the agent lanes, diff-scope and the
# tripwire use minutes too), and it knows nothing of runner size or of what the account's other
# repos use. The account's billing page has the measured figure.
set -euo pipefail
usage() { echo "usage: adlc-ci-budget.sh <minutes_per_run> <runs_per_pr> <prs_per_month> [included_minutes=2000]" >&2; exit 2; }
[ $# -ge 3 ] && [ $# -le 4 ] || usage
min="$1"; runs="$2"; prs="$3"; inc="${4:-2000}"
# a decimal: digits, optionally a point and digits; a whole number: digits only; neither may be zero
dec()   { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && printf '%s' "$1" | grep -q '[1-9]'; }
whole() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$1" | grep -q '[1-9]'; }
dec "$min"   || { echo "adlc-ci-budget: minutes_per_run must be a number above zero, got '${min}'" >&2; exit 2; }
dec "$runs"  || { echo "adlc-ci-budget: runs_per_pr must be a number above zero, got '${runs}'" >&2; exit 2; }
whole "$prs" || { echo "adlc-ci-budget: prs_per_month must be a whole number above zero, got '${prs}'" >&2; exit 2; }
whole "$inc" || { echo "adlc-ci-budget: included_minutes must be a whole number above zero, got '${inc}'" >&2; exit 2; }
# awk does the arithmetic (bash 3.2 has no decimals); LC_ALL=C keeps the decimal point a point.
# The product is rounded to a thousandth before it is rounded up, so 23 × 4.6 × 20 is 2116, not
# 2117 from a binary tail.
LC_ALL=C awk -v m="$min" -v r="$runs" -v p="$prs" -v i="$inc" '
  function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
  BEGIN {
    est = int(m * r * p * 1000 + 0.5) / 1000
    printf "estimate: %d CI minutes/month (%s min/run x %s runs/PR x %s PRs/month)\n", ceil(est), m, r, p
    printf "included: %d minutes/month\n", i
    pct = ceil(int(est / i * 100000 + 0.5) / 1000)
    if (est <= i) { printf "FITS: %d%% of the included minutes\n", pct; exit 0 }
    printf "OVER: %d%% of the included minutes (%.1fx)\n", pct, est / i
    exit 1
  }'
