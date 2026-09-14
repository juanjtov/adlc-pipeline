---
name: security-gate
description: Portable secure-coding checklist and security gate — tenant/scope isolation, parameterized SQL, auth/session validation, secrets, middleware, uploads, severity rubric. Builder loads it generatively (write safe code); QA/Ops loads it adversarially (break the PR).
---

# Security — one skill, two modes

- **Builder (generative):** apply every checklist item while writing code.
- **QA/Ops (adversarial):** actively attempt each attack class against the PR; a
  Critical/High finding blocks the merge.

Project-specific identifiers (the auth dependency name, the scope column, the SQL driver's
placeholder syntax, the secrets module) are in the `project-conventions` skill. This skill
is the portable checklist; substitute the project's names as you apply it.

## 1. Tenant / scope isolation (usually the #1 risk)

If the project is multi-tenant (or otherwise row-scoped by owner/org/user), **every**
query touching scoped data must filter by the authenticated principal's scope — no
exceptions, including counts, EXISTS checks, joins, and aggregate dashboards.

- Generative: take the scope key (e.g. `company_id`/`org_id`/`user_id`) from the
  authenticated user object, **never** from request params/body.
- Adversarial: for each new/changed query ask "what if this row id belongs to another
  tenant?" — attempt IDOR: read/update/delete a resource id from tenant B while
  authenticated as tenant A. Missing filter = **Critical**.
- Authorization: new endpoints declare their permission/role check; UI gates the route.
  Low-privilege roles must never see data beyond their scope.

## 2. SQL / query layer

- Parameterized queries only (bound placeholders). Any string interpolation
  (`f-string`/`.format()`/`+`/template literal) composing a query with user input =
  **Critical**, even if "sanitized".
- Dynamic ORDER BY / filter columns: allowlist mapping, never pass-through.
- ORM raw-SQL escapes get the same scrutiny as hand-written SQL.

## 3. AuthN / AuthZ

- Reuse the project's session/token validation dependency (named in
  `project-conventions`). Hand-rolled token parsing or crypto = **High**.
- New endpoints are authenticated by default. An intentionally-public endpoint needs an
  explicit comment justifying it, or it's a finding.
- Adversarial: call new endpoints with no token, expired token, other-tenant token, and
  lower-role token — assert 401/403, and that the error body leaks nothing.

## 4. Secrets & data handling

- Secrets via env/secret-manager only. Any literal key/password/URL-with-credentials in
  the diff = **Critical**. Check test files and fixtures too.
- Never log passwords, tokens, session ids, or full bearer tokens; no secrets in exception
  messages returned to clients. A secret in a URL **path or query** leaks into access logs
  even if app code never logs it — keep it in the body/header.
- Magic links / password-reset flows: single-use, expiring, constant-time comparison.

## 5. Platform middleware (verify not weakened)

Security headers, rate limiting, CSRF, request tracking, route guards. A diff that
disables, bypasses, or widens any of these = **High** minimum, and must be called out
explicitly. Machine-to-machine endpoints guarded by a header secret often must be added to
the CSRF/public-path allowlist, or CSRF 403s them before their own guard runs.

## 6. File uploads (signed-URL pattern)

PUT (upload) and GET (download) signed URLs are separate; the DB stores object paths,
never signed URLs; retrieval regenerates fresh GET URLs. Object paths are scope-prefixed;
adversarial: try fetching another tenant's object path.

## Severity rubric (gate criteria)

| Severity | Definition | Gate effect |
|---|---|---|
| **Critical** | Tenant leak, authn bypass, SQL injection, secret in code | Block. Fix before re-review. |
| **High** | AuthZ gap on a role, middleware weakened, hand-rolled crypto/auth | Block. |
| **Medium** | Missing negative tests, verbose errors, rate-limit gap on new endpoint | Merge allowed with a follow-up issue filed at `stage:intake`. |
| **Low** | Hardening opportunities | Note in review. |

QA/Ops verdict format: finding → file:line → severity → **class** (`adlc:edd-spec` vocabulary,
e.g. `tenant-leak`, `injection`) → attack demonstrated (or "theoretical") → required fix.
Append one ledger line per finding to `.adlc/metrics/findings.jsonl` so the `retro` loop can
compound recurring classes. The Principal additionally runs Claude Code's
`/security-review` on the PR branch before Gate 2 (subscription-billed, no API key) — it
complements, never replaces, the adversarial pass.
