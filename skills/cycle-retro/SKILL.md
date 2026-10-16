---
name: cycle-retro
description: The efficiency half of the self-improvement loop — read the deterministic run ledger (tokens, cost, latency per agent run) and the label-timeline cycle times, find where a pipeline run's time and money go (which stage, how many fix rounds, how long at a human gate), and PROPOSE pipeline-shape fixes (fast-lane routing, reviewer scope, round caps, cache, model tier). Sibling of `retro`, which fixes recurring code failures; this fixes the cycle. Opens a proposal PR; never auto-applies. Run manually (/adlc:cycle-retro) or on the retro schedule.
argument-hint: "[DAYS] (window; default 30)"
---

# Cycle retro — make each run cheaper and shorter

`retro` asks *what keeps going wrong in the code* and answers with tests and checks. This skill asks
*where do the time and the money of a run go* and answers with the shape of the pipeline. Same
rules: inputs are deterministic (never an agent's own report of what it spent), you **propose** in
one PR through the normal gates, you never merge, and you say so if nothing is worth changing.

Inputs — materialize them first (both ledgers are rebuilt on demand, never committed from CI):

```
mkdir -p .adlc/metrics
: > .adlc/metrics/runs.jsonl
.adlc/scripts/adlc-run-log.sh mc  "${DAYS:-30}"  >> .adlc/metrics/runs.jsonl   # local agent runs, from Mission Control's store
.adlc/scripts/adlc-run-log.sh otel telemetry/data/telemetry.jsonl >> .adlc/metrics/runs.jsonl   # or the OTel collector, if that repo uses it
.adlc/scripts/adlc-run-log.sh actions "${DAYS:-30}" >> .adlc/metrics/runs.jsonl   # the Actions lanes (latency only)
.adlc/scripts/adlc-cycle.sh issues "${DAYS:-30}"  > .adlc/metrics/cycle.jsonl     # stage dwell + rounds per issue, from the label timeline
.adlc/scripts/adlc-cycle.sh report "${DAYS:-30}"                                   # the ranked tables
.adlc/scripts/adlc-metrics.sh "${DAYS:-30}"                                        # first-pass rate, iterations-to-green
```

- **`runs.jsonl`** — one row per agent run: stage, agent, seconds, input/output/cache tokens,
  cache-read share, USD, model. Tokens and cost exist only where Claude Code exported telemetry
  (Mission Control or the collector); a run with `tokens: 0` ran with telemetry off — count it for
  latency, not for spend. In GitHub Actions only the `actions` source is available: lane latency
  and failure rate, no tokens.
- **`cycle.jsonl`** — one row per issue: seconds in each `stage:*` / `gate:*` label,
  `stage_seconds` (queue time plus agent time — an issue can wait at `stage:intake` for days before
  anything runs) vs `gate_seconds` (waiting on the Principal), `intake_to_pr_seconds`, fix `rounds`
  (the `adlc:changes-requested` labels the PR drew), lane (`full` / `fast`). The agents' own
  minutes are in `runs.jsonl`; the gap between the two is queue time.
- **`adlc-metrics.sh`** — first-pass acceptance and iterations-to-green from the same window.

## Step 1 — Rank

From the report, name the top three of:

1. **Stage that dominates spend** (usd share) and the stage that dominates **agent time** (sec share).
   They differ often: a cheap stage with a long wall clock is waiting on tools, not thinking.
2. **Fix rounds**: issues with `rounds > 0`, and what one round costs (the builder + reviewer rows
   of that issue after its first review). First-pass rate from `adlc-metrics.sh` is the same signal.
3. **Where the calendar goes**: compare the agents' minutes (`runs.jsonl`) with the stage dwell and
   the gate dwell (`cycle.jsonl`). If gate time or queue time dwarfs agent time, the cycle is the
   human or the trigger, not the pipeline — say so and stop proposing agent changes for latency.
4. **Cached share of the prompt per stage**: a stage well under the others, or at 0 %, is paying
   full input price — a cold or broken prefix (see `efficient-runs`).
5. **Lane health**: a guard lane with a high failure rate or iterations-to-green well above 1 is
   churn the Builder pays for twice.

A pattern must hold across **several issues** in the window. One expensive run is a story, not a
trend — leave it.

## Step 2 — Propose (cheapest structural lever first)

| Signal | Preferred lever |
|---|---|
| Small issues going through the full lane | sharpen the `triage` fast-lane criteria so they route to `stage:fast` |
| Reviewer cost ≥ builder cost | narrow what the reviewer reads (the diff + the criteria, not the repo); check `code-review` and the agent's tool grants |
| Rounds > 0 on most issues | the spec, not the Builder: tighter ACs in `edd-spec`, or a design-handoff check the Architect must pass |
| One stage at 0 % cache read | find the per-run invalidator (`adlc-doctor.sh`, `efficient-runs`); never "add more context" |
| Analyst/Architect spend high for their output | a cheaper model tier for that agent (the agent file's `model:`), with the first-pass rate watched next window |
| CI lane slow or flaky | fix the lane (cache deps, split jobs, quarantine the flake) — a code finding goes to `retro` |
| Gate wait dominates | a notification or batching habit for the Principal — not an agent change |

Each proposal names the evidence (which rows, which issues) and the metric that must move next window.

## Step 3 — Propose the PR

One PR: the config/skill/template changes from Step 2, the report pasted in the body with the
window, and a `CONTEXT-LOG.md` row for any context line it adds or removes (an efficiency fix that
adds prose is suspect — prefer a setting, a check, or a routing rule). The Principal reviews it like
any PR; the adversarial reviewer and QA gate apply. Never merge it. If no pattern holds across
issues, open no PR and say what the report showed.

## Step 4 — Plugin-scope lessons

A lever that is general — a lane default, a reviewer grant, a wizard setting — is a plugin
suggestion, filed exactly as `retro` does (`adlc:plugin-suggestion` on `ADLC_PLUGIN_REPO`), with
the numbers that earned it. Only from repos you own or may share.

## Cadence

- Manual: `/adlc:cycle-retro [DAYS]` from a session in the repo (Mission Control's store is local,
  so token and cost figures exist only here).
- Scheduled: `adlc-retro.yml` runs it after `retro`; in Actions it sees latency, rounds and gate
  times, not tokens.
