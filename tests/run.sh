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
rm -f "$SF"

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
rm -rf "$FIX"

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
