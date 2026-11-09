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
  per stage, and change failure signals from PRs / CI / labels (`change_failures` counts the
  issues labelled `adlc:change-failure`, the defects Ops traced to a deploy; `bug` alone is any
  reported defect and is not counted).
- **Finding ledger** — **materialize it first** from the PR comments (the durable store):
  ```
  : > .adlc/metrics/findings.jsonl
  for pr in $(gh pr list --state all --limit 500 --json number --jq '.[].number'); do
    gh pr view "$pr" --json comments,reviews \
      --jq '(.comments[] | {ts: .createdAt, body}), (.reviews[] | {ts: (.submittedAt // ""), body})
            | select((.body // "") | test("ADLC-FINDING:")) | @json' \
    | while IFS= read -r c; do
        jq -r .body <<<"$c" | .adlc/scripts/adlc-log-findings.sh "$pr" review "$(jq -r .ts <<<"$c")"
      done >> .adlc/metrics/findings.jsonl
  done
  wc -l < .adlc/metrics/findings.jsonl    # findings in the ledger
  ```
  This reads every `ADLC-FINDING: <severity> | <class> | <file>` line the reviewers left, in
  plain comments **and in review bodies** (a reviewer that submits a GitHub review leaves its
  findings there, and `--json comments` alone never returns them). Each row carries its own
  comment's time, so the `since` window applies to the ledger (`adlc-metrics.sh` keeps the rows
  whose `ts` falls in its window). `--limit 500`: a repo past 50 PRs otherwise loses its older
  ones without a word. A review still pending (unsubmitted, so without a time) falls back to the
  rebuild time rather than losing its findings. The script reports on stderr every finding-shaped
  line it could not read (`ADLC-FINDING:` followed by three `|`-separated fields, not placed at
  the start of the line); look at those before ranking, since a marker shape it does not know is
  a finding the retro never sees. It also writes each class as its canonical name from the
  closed list in `adlc:edd-spec` (`logic-bug` → `logic-contradiction`, `test-coverage` →
  `test-gap`, …) and reports once per run, on stderr, any class name outside the list.
- **`CONTEXT-LOG.md`** — what's already been added and why.

## Step 1 — Rank

Aggregate findings by **class × frequency × severity** over the window, on the canonical class
the ledger holds:
```
jq -r .class .adlc/metrics/findings.jsonl | sort | uniq -c | sort -rn
# names outside the closed list, ranked apart (a recurring one is a candidate for the list, in the plugin)
comm -23 <(jq -r .class .adlc/metrics/findings.jsonl | sort -u) <(.adlc/scripts/adlc-log-findings.sh classes | sort)
```
A class that recurs across **separate PRs/sessions** is a candidate for a durable fix. A one-off
is not — leave it to the model (adding context for a single miss is how bloat starts). Rank the
names outside the list separately and do not merge them into a canonical class by eye: if one
recurs, propose it as a synonym or a class in the plugin (Step 5), so every host counts it the
same way next time.

## Step 2 — Compound (cheapest durable layer first)

For each recurring class, propose the **cheapest fix that makes the failure hard to repeat**,
in this order — a lower layer always beats a higher one:

| Recurring class | Preferred durable fix |
|---|---|
| missing-edge-case, logic-contradiction | a **regression test** pinning the case (best — executable, permanent) |
| tenant-leak, authz-gap, injection, secret-in-code | a **`adlc:security-gate` case** + a regression test |
| hallucinated-api | a **CI check** (symbol/import lint) + a `project-conventions` "seams" note |
| contract-violation / diff-scope breach | tighten the ADR template's declared-scope section |
| test-gap | write the missing test, or make the vacuous one able to fail (an executable fix, like the first row) |
| doc-drift | correct the doc, and where a check can compare the doc to the code (a table of names, a list of scripts), add that check |
| flaky-test | fix/quarantine the test — **not** a context line |
| recurring, un-checkable gotcha | last resort: one line in `project-conventions` or CLAUDE.md |

**A bug becomes a test before it becomes a sentence.** Prose is the last resort, never the first.

## Step 3 — Prune (same loop, opposite direction)

Run the `ablation` keep/cut test on existing context, driven by data: any CLAUDE.md line or
gotcha with a **zero hit-rate** over the window (never tied to a prevented failure) is a
removal candidate. The loop must delete as readily as it adds, or it rots into append-only.

## Follow-up chains — a decision for the Principal, not more follow-ups

```
.adlc/scripts/adlc-chains.sh report    # chains 3+ issues deep: an issue, its follow-up, that one's follow-up, …
```
Each `depth=` line is one area where fix after fix drew another follow-up, a pipeline run per
issue. Put every such line in the PR body (with no PR, in your summary) as a **decision**, not
as further follow-up work: **accept the risk** — the Principal labels the chain's root issue
`adlc:accepted-risk`, and QA is then told to file no more follow-ups in that chain — or
**redesign** — one issue that replaces the approach. A line that starts `decided` already
carries the label: leave it out. `follow_ups_filed` in the metrics is the follow-ups' share of
the issues opened.

## Step 4 — Propose

Open one PR that: adds the tests/checks/conventions from Step 2, removes the Step 3
candidates, and appends a row to `CONTEXT-LOG.md` for every change (date · layer · the failure
class + evidence that earned it, or the zero-hit reason for a removal). Summarize the top
failure classes and the metric trend in the PR body. The Principal reviews it like any PR —
this proposal is itself subject to the QA gate and the adversarial reviewer. Never merge it.
If nothing recurs and nothing is prunable, open no PR and say so.

## Step 5 — Promote plugin-general lessons (cross-project learning)

Decide a **scope** for each recurring lesson:
- **`scope: project`** — specific to this repo (its stack, its data model). Fix it locally (above).
- **`scope: plugin`** — general enough to belong in the shared plugin: a new `security-gate`
  attack class, a better default in a template, a wizard/guardrail gap, a missing finding class.

For a **plugin-scope** lesson, don't edit the plugin from here — file an evidence-backed issue
into the shared plugin repo so its own pipeline can curate it:

```
gh issue create --repo "${ADLC_PLUGIN_REPO:-juanjtov/adlc-pipeline}" \
  --label adlc:plugin-suggestion \
  --title "<class>: <one-line general improvement>" \
  --body "Seen in $(gh repo view --json nameWithOwner --jq .nameWithOwner): <class>, <count> occurrences.
Example: <finding>. Proposed general change: <skill/template/script>."
```

This aggregates suggestions from **all your own projects** into one backlog; accepted ones
land in the plugin and reach every project on the next `/adlc:init` refresh or
`claude plugin update`. **Privacy:** only file from repos you own / are entitled to share — never
copy another team's findings into the shared plugin.

## Sibling: the cycle

This skill fixes what keeps going wrong in the code. Where a run's **time and money** go — which
stage dominates spend, how many fix rounds, how long at a gate — is the `cycle-retro` skill's
question, with its own ledgers (`adlc-run-log.sh`, `adlc-cycle.sh`) and its own PR. A slow or
flaky CI lane belongs there; a recurring code defect belongs here.

## Cadence

- Manual: `/adlc:retro` anytime (optionally `since <date|N merges>`).
- Scheduled: `adlc-retro.yml` runs it every N days and opens the proposal PR automatically.
