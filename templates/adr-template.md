# ADR-NNNN: <title>

**Status:** Proposed | Accepted | Superseded  ·  **Date:** YYYY-MM-DD  ·  **Author:** Architect  ·  **Issue:** #N

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

## Scope

The path prefixes this decision may touch, one per line in the block below (end a directory
with `/`): the same lines the Builder's `.adlc/scope/<issue>.txt` carries, apart from the
`docs/` files the design lane lists there. An empty block means it touches no file.

```
src/<area>/
tests/<area>/
```

## Guarantees

Each behaviour the Decision promises, and the test that pins it: `path::node` (the test
file, then the test's name in it — the Builder writes the test under that name), or
`unenforced — <reason>` when nothing checks the claim. `.adlc/scripts/adlc-adr-check.sh`
resolves every row and compares Scope with the scope file.

| Claim | Pinned by |
|---|---|
| <what must stay true> | `tests/<file>::<test name>` |
| <a claim no test holds> | unenforced — <why not> |

## Alternatives considered

Option B, Option C — why rejected.

## Consequences

What gets better, what gets harder, what to watch. Migration impact (additive vs
destructive — destructive is a Gate 2 hard stop). Breaking-change risk (API/schema/auth).
Rollback story.
