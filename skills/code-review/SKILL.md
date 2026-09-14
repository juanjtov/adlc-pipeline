---
name: code-review
description: How to run a scoped, adversarial code review on a PR — what counts as a finding, the three-pillar mandate (break assumptions, enforce contracts, prevent the echo chamber), and the structured-disagreement protocol. Load for the adversarial-reviewer agent and QA/Ops; also usable by a human, /code-review, or an external agent.
---

# Code review — adversarial, scoped, advisory

A fresh-context review that sees only the diff + criteria catches what author and verifier
miss *because they shared context*. This skill defines how to do it so it's sharp, not noisy.
Use it in the `adversarial-reviewer` agent, in the QA gate, or to guide a human / `/code-review`
/ an external agent (e.g. a second coding model) — the value is the same regardless of who runs it.

## The three pillars (apply all three)

1. **Break assumptions.** Unhandled edge cases (empty/null/boundary/concurrent), logic
   contradictions, ordering/off-by-one, vulnerability exploits (each `adlc:security-gate`
   attack class), and **hallucinated APIs** — symbols/params/imports/flags that don't exist
   in this repo or its dependencies. Confirm every unfamiliar symbol against the code.
2. **Enforce contracts.** Strict adherence to the ADR + task breakdown (declared diff scope,
   designed approach) and to the architectural + security constraints in
   `project-conventions` / `adlc:security-gate`. Unjustified deviation is a finding.
3. **Prevent the echo chamber.** **Structured disagreement**: don't rubber-stamp. State the
   strongest case the code is *wrong* and test it against the diff. Record at least one
   concrete risk you actively hunted, even if you dismiss it with evidence. This is why the
   reviewer is a **separate agent in fresh context** — a model reviewing its own output
   agrees with itself.

## What is / isn't a finding (the discipline that keeps it useful)

A finding names a **concrete failing input or scenario → wrong result**, tied to correctness,
a contract/spec violation, or security. No trigger ⇒ mark "theoretical" or drop it.

**Not findings:** style/taste nits, defensive code for impossible states, tests for cases the
ACs exclude, rewrites that don't fix a named defect. A reviewer told only to "find gaps"
produces defensive bloat — hunt *real* breakage instead.

## Severity & gate effect

Reuse the `adlc:security-gate` rubric. Correctness bugs map the same way: a demonstrable wrong
result on a realistic input is **High/Critical**. The review is **advisory** (like an outside
reviewer's pass) — it doesn't by itself move labels or merge — **but a confirmed Critical/High
correctness or security finding blocks the QA gate** until fixed or explicitly waived by the
Principal with rationale.

## Output format

Verdict (**PASS** / **CHANGES REQUESTED**), then per finding:
`severity · class · file:line · failing input→result · pillar · required fix`
(class from the `adlc:edd-spec` vocabulary), then a **structured-disagreement note**: the
strongest counter-case you tested and what the evidence showed. Post it as a single PR comment,
and append one ledger line per finding to `.adlc/metrics/findings.jsonl` (schema in
`adlc:edd-spec`) so the `retro` loop can compound recurring classes into durable guards.
