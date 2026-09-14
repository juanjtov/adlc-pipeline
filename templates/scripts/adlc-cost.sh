#!/usr/bin/env bash
# Cost/latency aggregation per lane and per pipeline. Reads one line per workflow run on STDIN:
#     <lane> <seconds> [tokens] [usd]
# (tokens/usd optional — supply them from OTel/the action's usage; latency needs neither).
# Prints a per-lane table (runs · total/avg seconds · tokens) and a TOTAL row.
#
# The retro produces the input from GitHub Actions runs, e.g.:
#   gh run list --limit 200 --json name,startedAt,updatedAt \
#     | jq -r '.[] | "\(.name) \(((.updatedAt|fromdate)-(.startedAt|fromdate)))"' \
#     | adlc-cost.sh
# For token/cost, enable OTel (settings.telemetry.json) — that captures per-agent tokens+cost
# directly; this script then just rolls them up alongside latency.
set -euo pipefail
awk '
  { lane=$1; sec=$2+0; tok=$3+0; usd=$4+0
    n[lane]++; S[lane]+=sec; T[lane]+=tok; U[lane]+=usd
    N++; SS+=sec; TT+=tok; UU+=usd }
  END {
    printf "%-26s %5s %9s %9s %10s %9s\n","lane","runs","tot_sec","avg_sec","tokens","usd"
    for (l in n) printf "%-26s %5d %9.0f %9.1f %10.0f %9.2f\n", l, n[l], S[l], S[l]/n[l], T[l], U[l]
    printf "%-26s %5d %9.0f %9s %10.0f %9.2f\n","TOTAL",N,SS,"-",TT,UU
  }'
