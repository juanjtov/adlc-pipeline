#!/usr/bin/env bash
# Prompt-cache hit-rate rollup. Reads one line per session (or per pipeline run) on STDIN:
#     <key> <input_tokens> <cache_read_tokens> <cache_creation_tokens>
# where the three token counts are Claude Code's `claude_code.token.usage` metric broken down
# by its `type` attribute (input / cacheRead / cacheCreation). `key` is whatever you group by —
# `service.name` for a whole pipeline run, or `session.id` for one agent.
#
# Feed it from the OTel capture (telemetry/data/telemetry.jsonl) — see telemetry/README.md for
# a recipe that shapes the JSONL into these four columns.
#
# Prints per-key token totals, cache-read %, and a TOTAL. read% = cache_read / (input +
# cache_read): the share of the request's input served from cache. A cache read bills ~0.1x an
# uncached input token, so read% is money (and latency) saved. A `!` flags any key that read 0
# from cache across the run — the signature of a broken or cold prefix (a silent invalidator,
# or genuinely cold traffic). Verify a caching change here, not by assuming it worked.
set -euo pipefail
awk '
  NF==0 { next }               # skip blank lines (a stray one would forge an empty-key row)
  { k=$1; inp=$2+0; rd=$3+0; cr=$4+0
    n[k]++; I[k]+=inp; R[k]+=rd; C[k]+=cr
    N++; II+=inp; RR+=rd; CC+=cr }
  function pct(rd, inp)  { return (rd+inp)>0 ? 100*rd/(rd+inp) : 0 }
  END {
    printf "%-28s %5s %10s %10s %10s %7s\n","key","runs","input","cache_rd","cache_wr","read%"
    for (k in n) {
      flag = (R[k]==0) ? " !" : ""
      printf "%-28s %5d %10.0f %10.0f %10.0f %6.1f%%%s\n", k, n[k], I[k], R[k], C[k], pct(R[k],I[k]), flag
    }
    printf "%-28s %5d %10.0f %10.0f %10.0f %6.1f%%\n","TOTAL",N,II,RR,CC,pct(RR,II)
  }'
