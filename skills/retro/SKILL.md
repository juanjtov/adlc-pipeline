---
name: retro
description: The self-improvement loop — read the pipeline's metrics + finding ledger, find recurring failure classes, and PROPOSE durable fixes (a regression test, a CI check, a convention, last a gotcha) plus prune stale context. Opens a proposal PR; never auto-applies. Run manually (/adlc:retro) or on a schedule. Reach for this to make the pipeline compound knowledge across runs.
argument-hint: "[since <date|N merges>] (optional window; default: since last retro)"
---

# Retro — compound knowledge every run

Turn what the pipeline learned into durable, versioned guards so the next run starts from a
higher floor — **without** bloating context. You **propose**; you never auto-apply. Output is
a single PR through the normal gates (author/verifier separation holds even here).

Inputs (all deterministic — never agent self-report):
- **GitHub-derived metrics** — run `${CLAUDE_PROJECT_DIR}/.adlc/scripts/adlc-metrics.sh` (or the
  copy under the plugin templates) for first-pass acceptance, iterations-to-green, cycle time
  per stage, and change failure signals from PRs / CI / labels.
- **Finding ledger** — `.adlc/metrics/findings.jsonl` (every reviewer/QA/security finding,
  tagged with a **class** from `adlc:edd-spec`).
- **`CONTEXT-LOG.md`** — what's already been added and why.

## Step 1 — Rank

Aggregate findings by **class × frequency × severity** over the window. A class that recurs
across **separate PRs/sessions** is a candidate for a durable fix. A one-off is not — leave it
to the model (adding context for a single miss is how bloat starts).

## Step 2 — Compound (cheapest durable layer first)

For each recurring class, propose the **cheapest fix that makes the failure hard to repeat**,
in this order — a lower layer always beats a higher one:

| Recurring class | Preferred durable fix |
|---|---|
| missing-edge-case, logic-contradiction | a **regression test** pinning the case (best — executable, permanent) |
| tenant-leak, authz-gap, injection, secret-in-code | a **`adlc:security-gate` case** + a regression test |
| hallucinated-api | a **CI check** (symbol/import lint) + a `project-conventions` "seams" note |
| contract-violation / diff-scope breach | tighten the ADR template or the `.adlc/scope.txt` allowlist |
| flaky-test | fix/quarantine the test — **not** a context line |
| recurring, un-checkable gotcha | last resort: one line in `project-conventions` or CLAUDE.md |

**A bug becomes a test before it becomes a sentence.** Prose is the last resort, never the first.

## Step 3 — Prune (same loop, opposite direction)

Run the `ablation` keep/cut test on existing context, driven by data: any CLAUDE.md line or
gotcha with a **zero hit-rate** over the window (never tied to a prevented failure) is a
removal candidate. The loop must delete as readily as it adds, or it rots into append-only.

## Step 4 — Propose

Open one PR that: adds the tests/checks/conventions from Step 2, removes the Step 3
candidates, and appends a row to `CONTEXT-LOG.md` for every change (date · layer · the failure
class + evidence that earned it, or the zero-hit reason for a removal). Summarize the top
failure classes and the metric trend in the PR body. The Principal reviews it like any PR —
this proposal is itself subject to the QA gate and the adversarial reviewer.

## Cadence

- Manual: `/adlc:retro` anytime (optionally `since <date|N merges>`).
- Scheduled: `adlc-retro.yml` runs it every N days and opens the proposal PR automatically.
