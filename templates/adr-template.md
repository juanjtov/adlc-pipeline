# ADR-NNNN: <title>

**Status:** Proposed | Accepted | Superseded  ·  **Date:** YYYY-MM-DD  ·  **Author:** Architect

## Context

What problem are we solving? What stories/ACs (issue #N: S1, S2…) drive this? What
constraints apply (stack, auth, data, deploy)?

**Blast radius:** which files/domains this touches. Check open `stage:build`/`stage:qa`
issues for overlap — "parallel-safe" if disjoint; name the conflicting issue and recommend
serialization if not.

## Decision

The design. Be specific enough that the Builder can implement without re-deriving it:
components, data model changes, API contracts, and the **task breakdown with declared diff
scope** (the exact files/dirs the Builder may touch per task) — this lives in the issue
comment and is referenced here.

## Alternatives considered

Option B, Option C — why rejected.

## Consequences

What gets better, what gets harder, what to watch. Migration impact (additive vs
destructive — destructive is a Gate 2 hard stop). Breaking-change risk (API/schema/auth).
Rollback story.
