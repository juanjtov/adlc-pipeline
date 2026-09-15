#!/usr/bin/env bash
# Unit tests for the ADLC guardrail scripts. Plain bash, no dependencies.
# Run: bash tests/run.sh   (exit 0 = all pass). These verify the deterministic guardrails
# themselves — the same scripts CI and the local pre-commit hook call.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/templates/scripts"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
# expect_exit <expected-code> <name> -- <cmd...>  (cmd reads stdin already piped)
check() { local want="$1" name="$2" got="$3"; [ "$got" = "$want" ] && ok "$name" || bad "$name (want exit $want, got $got)"; }
eq()    { local want="$1" name="$2" got="$3"; [ "$got" = "$want" ] && ok "$name" || bad "$name (want '$want', got '$got')"; }

echo "diff-scope:"
printf 'docs/adr/1.md\n'            | bash "$S/adlc-diff-scope.sh" design >/dev/null 2>&1; check 0 "design allows docs/" $?
printf 'docs/x.md\nsrc/y.py\n'      | bash "$S/adlc-diff-scope.sh" design >/dev/null 2>&1; check 1 "design denies src/" $?
printf 'backend/tests/t.py\n'       | ADLC_TEST_DIRS='tests|backend/tests' bash "$S/adlc-diff-scope.sh" qa >/dev/null 2>&1; check 0 "qa allows test dir" $?
printf 'backend/app.py\n'           | ADLC_TEST_DIRS='tests|backend/tests' bash "$S/adlc-diff-scope.sh" qa >/dev/null 2>&1; check 1 "qa denies non-test" $?
printf 'anything\n'                 | bash "$S/adlc-diff-scope.sh" other >/dev/null 2>&1; check 0 "unknown stage skips" $?
SF="$(mktemp)"; printf 'src/api/\nsrc/models/\n' > "$SF"
printf 'src/api/x.py\n'             | bash "$S/adlc-diff-scope.sh" build "$SF" >/dev/null 2>&1; check 0 "build allows in-scope (scope file)" $?
printf 'src/db/y.py\n'              | bash "$S/adlc-diff-scope.sh" build "$SF" >/dev/null 2>&1; check 1 "build denies out-of-scope (scope file)" $?
printf 'x\n'                        | bash "$S/adlc-diff-scope.sh" build "/no/such/file" >/dev/null 2>&1; check 0 "build advisory when no scope file" $?
printf 'src/api/x.py\n'             | bash "$S/adlc-diff-scope.sh" fast "$SF" >/dev/null 2>&1; check 0 "fast reuses build scope (in-scope)" $?
printf 'src/db/y.py\n'              | bash "$S/adlc-diff-scope.sh" fast "$SF" >/dev/null 2>&1; check 1 "fast reuses build scope (out-of-scope)" $?
rm -f "$SF"

echo "triage (fast-lane cap):"
printf 'src/a.py\nsrc/b.py\nREADME.md\n'      | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "small safe change is fast-eligible" $?
printf 'src/a.py\ndb/migrations/003.sql\n'    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "migrations force full" $?
printf '.github/workflows/x.yml\n'            | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "CI config forces full" $?
printf 'package.json\n'                       | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "dependency manifest forces full" $?
printf 'src/author/model.py\n'                | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "author/ dir not mistaken for auth/" $?
printf 'a\nb\nc\nd\ne\nf\n'                    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "over file cap forces full" $?
printf '30\t20\tsrc/a.py\n'                   | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "over line cap (numstat) forces full" $?
printf '10\t5\tsrc/a.py\n5\t2\tsrc/b.py\n'    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "small numstat is fast-eligible" $?
printf -- '-\t-\tlogo.png\n'                  | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "binary change forces full" $?
# numstat paths are UNquoted with literal spaces — must split on tab, not whitespace, or the
# denylist is bypassed (path truncated at the first space).
printf '3\t0\tmy app/migrations/001.sql\n'    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "space in path: migrations still caught" $?
printf '1\t0\tapp dir/.env\n'                 | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "space in path: .env still caught" $?
printf '2\t1\tmy src/util.py\n'               | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "space in path: innocent file still fast" $?
eq FAST "prints FAST token" "$(printf 'src/a.py\n' | bash "$S/adlc-triage.sh" 2>/dev/null)"
eq FULL "prints FULL token" "$(printf 'infra/main.tf\n' | bash "$S/adlc-triage.sh" 2>/dev/null)"
ADLC_FAST_MAX_FILES=1 bash -c 'printf "a\nb\n" | bash "'"$S"'/adlc-triage.sh"' >/dev/null 2>&1; check 1 "env override tightens file cap" $?

echo "verdict:"
eq PASS    "last marker wins"        "$(printf 'ADLC-ADV: CHANGES\nblah\nADLC-ADV: PASS\n' | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq CHANGES "reads CHANGES"           "$(printf 'ADLC-ARCH: CHANGES\n'                       | bash "$S/adlc-verdict.sh" ADLC-ARCH)"
eq ""      "empty when no marker"    "$(printf 'nothing here\n'                            | bash "$S/adlc-verdict.sh" ADLC-ADV)"

echo "fix-cap:"
eq GO   "GO below cap"   "$(printf 'adlc-fix: a\nadlc-fix: b\n'              | bash "$S/adlc-fix-cap.sh" 3)"
eq STOP "STOP at cap"    "$(printf 'adlc-fix: a\nadlc-fix: b\nadlc-fix: c\n' | bash "$S/adlc-fix-cap.sh" 3)"
eq GO   "GO when none"   "$(printf 'feat: x\nfix: y\n'                       | bash "$S/adlc-fix-cap.sh" 3)"

echo "tripwire-check:"
printf 'sha1 1\nsha2 2\n' | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 0 "OK when all have PRs" $?
printf 'sha1 1\nsha2 0\n' | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 1 "fails on a direct push" $?

echo "doctor (placeholder scan):"
FIX="$(mktemp -d)"
mkdir -p "$FIX/.claude/skills/project-conventions" "$FIX/.claude/skills/release-ops" "$FIX/.github/workflows"
printf '{"permissions":{"deny":["Bash(gh pr merge:*)"]}}' > "$FIX/.claude/settings.json"
echo x > "$FIX/.claude/skills/project-conventions/SKILL.md"
echo x > "$FIX/.claude/skills/release-ops/SKILL.md"
printf 'if: "{{PRINCIPAL}}"\n' > "$FIX/.github/workflows/adlc-x.yml"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "flags unfilled placeholder" $?
printf 'if: "someuser"\n' > "$FIX/.github/workflows/adlc-x.yml"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 0 "passes when filled + skills + deny present" $?
# prompt-cache hygiene: a live CI run-id expansion in a frozen context file must fail
printf '# proj\nBuild ref: ${GITHUB_RUN_ID}\n' > "$FIX/CLAUDE.md"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "flags live CI run-id in CLAUDE.md" $?
# an unfilled placeholder in a context file must also fail
printf 'x {{PROJECT_NAME}} y\n' > "$FIX/.claude/skills/project-conventions/SKILL.md"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "flags unfilled placeholder in a skill" $?
echo x > "$FIX/.claude/skills/project-conventions/SKILL.md"   # restore
# false-positive regression: doc examples + bare date + prose CI-var name must NOT flag
printf '# proj\ncreated_at looks like 2024-01-01T00:00:00Z; CI sets GITHUB_SHA.\n<!-- Last ablation: 2026-09-15 -->\n' > "$FIX/CLAUDE.md"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 0 "allows doc timestamp / prose CI var / bare date" $?
rm -rf "$FIX"

echo "cache (hit-rate rollup):"
CA=$(printf 'adlc-builder 1000 8000 500\nadlc-qa 2000 0 1000\nadlc-builder 500 4000 200\n' | bash "$S/adlc-cache.sh")
# read% asserts anchored with %$ so an unexpected trailing ` !` flag would fail them
printf '%s\n' "$CA" | grep -qE 'adlc-builder +2 +1500 +12000 +700 +88\.9%$' && ok "per-key read% (12000/13500)" || bad "per-key read%"
printf '%s\n' "$CA" | grep -qE 'adlc-qa +1 +2000 +0 +1000 +0\.0% !$' && ok "flags zero cache-read with !" || bad "flags zero cache-read"
printf '%s\n' "$CA" | grep -qE 'TOTAL +3 +3500 +12000 +1700 +77\.4%$' && ok "pipeline total read% (12000/15500)" || bad "pipeline total read%"
# a stray blank input line must not forge a row or inflate the TOTAL run count
CB=$(printf 'k 100 900 5\n\nj 10 90 1\n' | bash "$S/adlc-cache.sh")
printf '%s\n' "$CB" | grep -qE 'TOTAL +2 +110 +990 +6' && ok "blank input line ignored (TOTAL runs=2)" || bad "blank input line ignored"

echo "log-findings:"
LF=$(printf 'prose\nADLC-FINDING: High | hallucinated-api | src/x.py\nADLC-FINDING: Critical | tenant-leak | src/y.py\n' | bash "$S/adlc-log-findings.sh" 42 review)
eq 2 "logs 2 findings"          "$(printf '%s\n' "$LF" | grep -c '"class"')"
printf '%s' "$LF" | grep -q '"class":"hallucinated-api"' && ok "parses class" || bad "parses class"
printf '%s' "$LF" | grep -q '"severity":"Critical"' && ok "parses severity" || bad "parses severity"
printf '%s' "$LF" | grep -q '"pr":42' && ok "tags pr number" || bad "tags pr number"
eq "" "empty when no findings" "$(printf 'nothing here\n' | bash "$S/adlc-log-findings.sh" 1 review)"

echo "cost/latency:"
CO=$(printf 'adlc-builder 120 5000 0.10\nadlc-qa 80 3000 0.06\nadlc-builder 60 2000 0.04\n' | bash "$S/adlc-cost.sh")
printf '%s\n' "$CO" | grep -qE 'adlc-builder +2 +180 +90\.0 +7000' && ok "per-lane rollup (runs/total/avg/tokens)" || bad "per-lane rollup"
printf '%s\n' "$CO" | grep -qE 'TOTAL +3 +260' && ok "pipeline total latency" || bad "pipeline total latency"
LO=$(printf 'adlc-review 30\nadlc-review 10\n' | bash "$S/adlc-cost.sh")
printf '%s\n' "$LO" | grep -qE 'adlc-review +2 +40 +20\.0' && ok "latency-only (no tokens)" || bad "latency-only"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
