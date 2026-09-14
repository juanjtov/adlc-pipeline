---
name: verify
description: How to prove a change is actually done in this pipeline — the single pass/fail check per role, and a rubric for the roles that have no test suite. Reach for this to answer "what proves this is finished?" before trusting an agent's "looks done." Used by every role.
---

# Verify — what proves a stage is done

The highest-leverage artifact in an agent setup is not an instruction — it's a check the
agent can run itself. Without one, "looks done" is the only stop signal, and the human
becomes the verification loop. Every role below has an **exit criterion**: do not report a
stage complete until it holds, and quote the real check output, never a memory of it.

The actual commands live in the `project-conventions` skill (its **Commands** table). This
skill says *which* check each role must pass.

## The keystone question

**What command returns pass/fail for a change in this repo?** That command (test +
type-check + build, from `project-conventions`) is the Builder's and QA's stop signal.
If the project has no such command yet, establishing one is the first bootstrap task —
an agent cannot run long without it.

## Exit criteria by role

- **Product Analyst** — no test suite exists yet, so the check is a **rubric**: every AC is
  executable, deterministic (thresholds not adjectives), role-explicit, and tenant/scope-
  explicit (EDD rules in `adlc:edd-spec`); every story has edge cases + out-of-scope; zero
  open questions. *Done when* the rubric passes for every story.
- **Architect (design)** — also rubric-checked: the ADR states decision + alternatives +
  consequences + blast-radius verdict, and the task breakdown gives each task a **declared
  diff scope** and the ACs it satisfies. *Done when* a Builder could implement without
  re-deriving the design.
- **Architect (review)** — *Done when* the PR diff ⊆ declared scope and conforms to the ADR
  (or the deviation is justified in the review), verdict submitted via `gh pr review`.
- **Builder** — *Done when* the project's pass/fail command is green locally (paste the real
  summary line), the diff ⊆ declared scope, and every AC has a test carrying its `SN-ACN`
  id. UI change: also browser-verified (not just built).
- **QA / Release-Ops** — *Done when* the full battery is green (pasted), every AC ↔ ≥1 test,
  the adversarial security pass (`adlc:security-gate`) finds no Critical/High, and any UI
  change is browser-verified. Only then the Gate 2 Action Card.

## Escalating strength (pick the lowest that works)

1. Ask for the check in the prompt ("run the tests after implementing").
2. A re-evaluated goal condition.
3. A `Stop` hook that blocks the turn until the check passes.
4. An adversarial reviewer subagent that sees only the diff + criteria.

## Caution on the adversarial reviewer

A reviewer told to "find gaps" finds some even when the work is sound — producing defensive
code and tests for impossible cases. Scope it: **flag only what affects correctness or a
stated acceptance criterion; everything else is optional.** This is exactly the Architect
review and the QA security gate in this pipeline — keep them adversarial but scoped.
