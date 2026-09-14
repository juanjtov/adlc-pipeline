---
name: edd-spec
description: Evaluation-Driven Development spec — story/AC templates, traceability rules, and the ADLC metric taxonomy. Load for the Product Analyst (writing stories) and QA/Ops (verifying coverage).
---

# EDD Spec — Stories, ACs, Traceability, Metrics

Used by: **product-analyst** (authoring), **qa-release-ops** (verifying).
Project-specific role names and domain terms come from the `project-conventions` skill.

## Story template

```
S<N>: As a <role>,
      I want <capability>,
      so that <measurable outcome>.
```

Rules: one capability per story · use only the real user roles listed in
`project-conventions` · outcome states the benefit, not the mechanism · use the project's
domain vocabulary (glossary in `project-conventions`).

## Acceptance criteria template

```
S<N>-AC<M>:
  Given <precondition incl. role + tenant/context>
  When  <action>
  Then  <observable, testable outcome>
```

**Testability rules (every AC must pass all four):**
1. Executable — an automated test (or a concrete manual step) can verify it.
2. Deterministic — no "should be fast/intuitive"; use thresholds ("p95 < 500ms").
3. Role-explicit — states which roles can and cannot.
4. Tenant/scope-explicit — when the project is multi-tenant, cross-tenant access is always
   an explicit negative AC wherever data access is involved.

Every story ships with **edge cases** (empty/error/permission-denied states) and an
**out-of-scope** list.

## Traceability

- Requirement issue → stories `S1…Sn` (comment on the same issue).
- Story/AC ID goes into the test docstring/name: `S2-AC1: crew cannot see payments.`
- QA verifies the mapping is total before Gate 2: every AC ↔ ≥1 test. Grep pattern:
  `grep -rnE "S[0-9]+-AC[0-9]+" <test-dir>` (the test dir is named in `project-conventions`).

## Metric taxonomy

| Stage | Metric | Definition |
|---|---|---|
| Analyst | Story rework rate | stories returned by Principal ÷ stories submitted |
| Analyst | AC testability % | ACs mapping 1:1 to an executable check ÷ total ACs |
| Analyst | Traceability | requirement→story→test links intact (yes/no per story) |
| Architect | Design-to-code drift | Builder deviations from ADR/task spec per story |
| Architect | Review catch rate | severity-weighted issues caught at review ÷ (review + QA + prod) |
| Architect | Breaking-change rate | PRs causing API/schema/auth breakage ÷ PRs reviewed |
| Builder | First-pass acceptance | PRs approved without rework ÷ PRs opened |
| Builder | Iterations-to-green | CI runs until green per PR |
| Builder | Diff scope adherence | files touched ⊆ declared scope (yes/no per PR) |
| QA/Ops | Defect escape rate | bugs found in prod ÷ (QA + prod) |
| QA/Ops | Change failure rate | deploys causing incidents ÷ deploys |
| QA/Ops | MTTR | incident open → resolved |
| QA/Ops | Alert precision | actionable escalations ÷ total escalations |
| All | Cost & wall-clock | tokens + minutes per stage per story |

Record per-story rows during the pilot (a `docs/adlc/BASELINE_METRICS.md` is a good home);
these baselines set the staged-autonomy thresholds later (charter §2.5).

## Capture & finding classes (feeds the `retro` self-improvement loop)

Every finding from the adversarial reviewer, QA, or the security gate carries a **class**, so
recurring failure types can be found and turned into durable guards (see the `retro` skill).

**The store is the PR comments.** A read-only reviewer can post a comment but can't write repo
files, and a CI push of a ledger to `main` would trip the tripwire — so reviewers emit one
machine-readable line per finding **inside their PR comment**:

```
ADLC-FINDING: <severity> | <class> | <file>
```

The `retro` (via `.adlc/scripts/adlc-log-findings.sh`) reads those lines from PR comments and
**materializes** the ledger `.adlc/metrics/findings.jsonl` on demand — one object per finding:

```
{"ts":"<ISO8601>","pr":<n>,"stage":"review|qa|security",
 "severity":"Critical|High|Medium|Low","class":"<class>","file":"<path>"}
```

**Finding classes:** `tenant-leak` · `authz-gap` · `injection` · `secret-in-code` ·
`hallucinated-api` · `missing-edge-case` · `logic-contradiction` · `contract-violation`
(ADR / diff-scope) · `flaky-test` · `perf-regression` · `other`.

Comments are durable, per-repo, and native (never an agent self-report file). The `retro` ranks
the materialized ledger to add durable guards; the `ablation` skill prunes context they no
longer justify.

**Cost & wall-clock capture.** Latency per lane and per pipeline run is deterministic from
GitHub Actions run durations — `adlc-cost.sh` rolls it up (no extra infra). **Token count and
cost per agent** come from opt-in **OpenTelemetry** (`settings.telemetry.json`): Claude Code
exports per-session tokens + cost + duration to your OTel collector, and `service.name` groups
a whole pipeline execution. Enable OTel when you have a collector; latency works without one.
