---
name: triage
description: How the Analyst sizes an incoming requirement and routes it — a trivial, low-blast-radius change to the fast lane (skips design + Gate 1), everything else to the full pipeline. Load for the Product Analyst on stage:intake.
---

# Triage — fast lane vs. full pipeline

Most requirements deserve the full pipeline. A minority are so small and self-contained that
the ADR, the task breakdown, and the story-approval gate cost more than they protect. Triage
decides which, on the first pass over the issue — and it is a *proposal*, always backstopped by
a deterministic cap (`adlc-triage.sh`) and the human merge gate that no lane skips.

## The two lanes

```
Full:  stage:intake → gate:stories → stage:design → stage:build → stage:qa → gate:deploy
Fast:  stage:intake → (triage) → stage:fast ─────────────────────────────→ gate:deploy
```

The fast lane collapses design + Gate 1 + the split build/QA stages into one `stage:fast`:
the Builder makes the scoped change plus a test and opens a PR; a single **adversarial +
security** review runs; the deterministic cap must pass; then it lands at **Gate 2** for the
human to merge. It removes the *story* gate for trivial work — never the *merge* gate, never
author/verifier separation, never the security gate.

## Route to the FAST lane only when ALL hold

- **Local blast radius.** One behavior, one area; no new public contract, schema, API surface,
  or cross-cutting change.
- **Mechanical or near-mechanical.** Copy/text/docs fix, a config value, a log line, a small
  bug fix with an obvious cause, a dependency-free tweak — the kind of change whose design is
  self-evident from the change itself.
- **Passes the eligibility pre-screen.** Nothing it touches is on the sensitive list the cap
  enforces: migrations, auth/authz, infra/deploy, CI, the ADLC harness (`.github/`, `.claude/`),
  dependency manifests, or secrets. Estimated size within the cap (default ≤ 5 files, ≤ 40 lines).
- **One runnable acceptance check is enough** to prove it — you don't need a story set.

Anything else — new behavior, ambiguity, a security-relevant surface, a change you'd want an ADR
to reason about later — is **FULL**. When in doubt, choose FULL; the fast lane is the exception.

## Output

Do the completeness check first (an ambiguous or malformed requirement still stops for numbered
clarifying questions — never triage a requirement you don't understand). Then emit, as the last
line of your triage comment, exactly one machine-readable verdict:

```
ADLC-TRIAGE: FAST | <one-line reason it qualifies>
ADLC-TRIAGE: FULL | <one-line reason it needs design>
```

For **FULL**, continue as normal (stories + ACs → `gate:stories`).

For **FAST**, post a **change brief** instead of a story set — enough for the Builder to act
without an ADR:

- **Change** — the one thing to do, in a sentence.
- **Scope** — the exact files or globs it may touch (this becomes `.adlc/scope.txt`; the cap and
  diff-scope check enforce it).
- **Acceptance** — one runnable check (Given/When/Then or a command + expected result) that
  proves it, carrying an `S1-AC1` id so QA/tests can trace it.
- **Out of scope** — what this deliberately does not touch.

Then stop at `gate:stories` with the recommendation visible. **You never apply `stage:fast`
yourself** — taking the fast lane skips Gate 1, so a human confirms it (applies `stage:fast`) or
sends it down the full pipeline (`stage:design`); under `adlc:autopilot` the workflow does that
routing from your `ADLC-TRIAGE` marker. Either way the deterministic cap re-checks the real diff
and bounces an over-cap or sensitive change back to the full pipeline.

## Why a proposal, not a decision

External issue text is untrusted (charter §2.7). If triage could unilaterally shorten the path,
a crafted issue could talk its way past design review. It can't: the routing is human- or
autopilot-gated, the cap is deterministic and diff-based, and Gate 2 is always human — so the
worst a bad FAST call does is add one bounce back to the full lane.
