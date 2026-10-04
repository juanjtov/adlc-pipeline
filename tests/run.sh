#!/usr/bin/env bash
# Unit tests for the ADLC guardrail scripts. Plain bash, no dependencies.
# Run: bash tests/run.sh   (exit 0 = all pass). These verify the deterministic guardrails
# themselves — the same scripts CI and the local pre-commit hook call. The static checks at the
# end cover what can't be run here for real: the workflow templates (their triggers, and the
# intake and diff-scope steps against a stub gh), the pre-commit hook, and labels.sh.
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
# Run from a checkout-shaped directory: the scope file and the changed paths are both
# repo-relative, exactly as CI and the hook pass them.
T="$(mktemp -d)"; mkdir -p "$T/.adlc/scope"; SC=.adlc/scope/12.txt
scope() { printf '%b' "$1" > "$T/$SC"; }
ds()    { ( cd "$T" && bash "$S/adlc-diff-scope.sh" "$@" ) >/dev/null 2>&1; }   # file list on stdin
printf 'docs/adr/1.md\n'            | ds design; check 0 "design allows docs/" $?
printf 'docs/x.md\nsrc/y.py\n'      | ds design; check 1 "design denies src/" $?
printf 'backend/tests/t.py\n'       | ADLC_TEST_DIRS='tests|backend/tests' ds qa; check 0 "qa allows test dir" $?
printf 'backend/app.py\n'           | ADLC_TEST_DIRS='tests|backend/tests' ds qa; check 1 "qa denies non-test" $?
printf 'anything\n'                 | ds other;  check 0 "'other' skips" $?
printf 'anything\n'                 | ds '';     check 0 "no stage skips" $?
printf 'anything\n'                 | ds bogus;  check 2 "an unknown stage is an error, not a skip" $?
scope 'src/api/\nsrc/models/\n'
printf 'src/api/x.py\n'             | ds build "$SC"; check 0 "build allows in-scope" $?
printf 'src/db/y.py\n'              | ds build "$SC"; check 1 "build denies out-of-scope" $?
printf 'src/api/x.py\n'             | ds fast "$SC";  check 0 "fast allows in-scope" $?
printf 'src/db/y.py\n'              | ds fast "$SC";  check 1 "fast denies out-of-scope" $?
# a lane PR must declare its scope: no scope file is a failure, never a silent skip
printf 'src/api/x.py\n'             | ds build .adlc/scope/99.txt; check 1 "build with no scope file fails" $?
printf 'src/api/x.py\n'             | ds fast;                     check 1 "fast with no scope file fails" $?
printf 'tests/t.py\n'               | ds build+qa '';              check 1 "build+qa with no scope file fails" $?
# build+qa = a Builder PR that QA has committed tests onto: declared scope OR the test dirs
printf 'src/api/x.py\nbackend/tests/t.py\n' | ADLC_TEST_DIRS='tests|backend/tests' ds build+qa "$SC"; check 0 "build+qa allows scope + test dirs" $?
printf 'backend/tests/t.py\nsrc/db/y.py\n'  | ADLC_TEST_DIRS='tests|backend/tests' ds build+qa "$SC"; check 1 "build+qa denies outside scope + tests" $?
printf 'backend/tests/t.py\n'       | ADLC_TEST_DIRS='tests|backend/tests' ds build "$SC"; check 1 "build alone does not open the test dirs" $?
# the scope file is part of the PR that declares it — it must not fail its own check
printf 'src/api/x.py\n%s\n' "$SC"   | ds fast "$SC";   check 0 "the scope file itself is in scope" $?
printf '.adlc/scope/13.txt\n'       | ds fast "$SC";   check 1 "another issue's scope file is not" $?
printf '%s\n' "$SC"                 | ds design "$SC"; check 1 "nor is it exempt in design/qa" $?
# scope lines are literal path prefixes: real paths carry regex characters
scope 'src/routes/+page.svelte\napp/[id]/page.tsx\napp/routes/$id.tsx\nsrc/api/\n'
printf 'src/routes/+page.svelte\napp/[id]/page.tsx\napp/routes/$id.tsx\n' | ds build "$SC"; check 0 "paths with regex characters match themselves" $?
printf 'src/api_internal/x.py\n'    | ds build "$SC"; check 1 "'src/api/' does not admit src/api_internal/" $?
scope '.*\n'
printf 'src/api/x.py\n'             | ds build "$SC"; check 1 "a scope line is literal, not a pattern" $?
scope 'src/api/\n\n'
printf 'src/db/y.py\n'              | ds build "$SC"; check 1 "a blank line does not allow everything" $?
scope '  src/models/  \n'
printf 'src/models/m.py\n'          | ds build "$SC"; check 0 "scope entries are trimmed" $?
scope 'src/api/'   # no final newline — the usual shape of a file an agent writes
printf 'src/api/x.py\n'             | ds build "$SC"; check 0 "a last line with no newline still counts" $?
scope '# notes\n'
printf '# notes/x.md\n'             | ds build "$SC"; check 1 "a # line is a comment, not a prefix" $?
scope ''
printf 'src/api/x.py\n'             | ds build "$SC"; check 1 "an empty scope file allows nothing" $?

# The stage comes from the PR's LINKED ISSUE — the lanes never put stage:* on the PR itself.
# These are the label sets the lane workflows actually leave behind.
echo "pr-stage (which diff-scope stage a PR is in):"
st() { bash "$S/adlc-pr-stage.sh" "$1" "${2:-}"; }
eq build     "full lane: Builder PR, issue at stage:build"        "$(st '' 'stage:build')"
eq build     "full lane: fix loop (PR adlc:changes-requested)"    "$(st 'adlc:changes-requested' 'adlc:auto
stage:build')"
eq build+qa  "full lane: issue advanced to stage:qa"              "$(st '' 'stage:qa')"
eq build+qa  "full lane: at Gate 2 (stage:qa + gate:deploy)"      "$(st '' 'stage:qa
gate:deploy')"
eq build+qa  "Gate 2 with the stage label removed"                "$(st '' 'gate:deploy')"
eq fast      "fast lane at opened (lane:fast not on the PR yet)"  "$(st '' 'stage:fast')"
eq fast      "fast lane after PASS (issue at gate:deploy)"        "$(st 'lane:fast' 'gate:deploy')"
eq fast      "fast lane: fix loop"                                "$(st 'lane:fast
adlc:changes-requested' 'stage:fast')"
eq fast      "fast lane: PR label only (no linked issue)"         "$(st 'lane:fast')"
eq other     "issue at stage:design (a bounced fast PR) → skipped" "$(st '' 'stage:design')"
eq qa        "PR-label fallback: stage:qa (tests only)"           "$(st 'stage:qa')"
eq design    "PR-label fallback: stage:design"                    "$(st 'stage:design' 'stage:design')"
eq build     "PR-label fallback: stage:build"                     "$(st 'stage:build' 'gate:stories')"
eq build+qa  "linked issue wins over the PR's own label"          "$(st 'stage:build' 'stage:qa')"
eq other     "no labels → not a lane PR"                          "$(st '' '')"
eq other     "non-stage labels → other"                           "$(st 'bug
needs:human' 'adlc:auto
stage:intake')"
eq other     "whole-label match, not substring"                   "$(st 'old-stage:build-notes' 'xstage:qa')"
# Drift guards: every stage a lane PR can be open at must resolve to a stage, and every stage
# the resolver can print must be one adlc-diff-scope.sh enforces — a miss either way is a skip.
for l in $(grep -oE '"stage:[a-z]+"' "$ROOT/templates/github/labels.sh" | tr -d '"'); do
  case "$l" in stage:intake|stage:design) continue ;; esac   # no lane PR is open at these
  [ "$(st '' "$l")" != other ] && ok "labels.sh $l maps to a stage" || bad "labels.sh $l maps to a stage (got other)"
done
stages=$(grep -oE 'echo [a-z+]+' "$S/adlc-pr-stage.sh" | awk '$2 != "other" {print $2}' | sort -u)
[ -n "$stages" ] && ok "resolver stages read from the script" || bad "could not read the resolver's stages"
scope 'src/api/\n'
for s in $stages; do
  printf 'zz/outside.txt\n' | ADLC_TEST_DIRS=tests ds "$s" "$SC"; check 1 "diff-scope enforces resolver stage '$s'" $?
done
rm -rf "$T"

echo "branch-issue (which issue a lane branch names):"
bi() { bash "$S/adlc-branch-issue.sh" "$1"; }
eq 12 "feat/12-add-login → 12"                        "$(bi feat/12-add-login)"
eq 12 "feat/12 (no slug) → 12"                        "$(bi feat/12)"
eq "" "main names no issue"                           "$(bi main)"
eq "" "fix/diff-scope names no issue"                 "$(bi fix/diff-scope)"
eq "" "a number deeper in the name is not an issue"   "$(bi feat/v2-12-foo)"
eq "" "no branch (detached HEAD) names no issue"      "$(bi '')"

echo "triage (fast-lane cap):"
printf 'src/a.py\nsrc/b.py\nREADME.md\n'      | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "small safe change is fast-eligible" $?
printf 'src/a.py\ndb/migrations/003.sql\n'    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "migrations force full" $?
printf '.github/workflows/x.yml\n'            | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "CI config forces full" $?
printf '.adlc/scripts/adlc-triage.sh\n'       | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "the guard scripts themselves force full" $?
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
# the issue's scope file is the declaration every lane PR must carry — it is not the change
printf 'a\nb\nc\nd\ne\n.adlc/scope/12.txt\n'  | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "scope file does not count toward the file cap" $?
printf '38\t0\tsrc/a.py\n9\t0\t.adlc/scope/12.txt\n' | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "…nor toward the line cap" $?
printf '.adlc/scope/12/migrations/x.sql.txt\n' | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "only the scope file itself is exempt" $?
# git writes a rename as `old => new` with 0 lines: neither the path it moved to nor its size
# would be judged. The script refuses the notation, and the workflow never produces it.
printf '0\t0\tsrc/db/old.py => auth/new.py\n' | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "rename notation is never fast-eligible" $?
printf '0\t0\t{src/db => x/auth}/old.py\n'    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "…in its brace form either" $?
grep -q -- 'git diff --numstat --no-renames' "$ROOT/templates/github/adlc-fast.yml" && ok "adlc-fast.yml takes the cap's diff with --no-renames" || bad "adlc-fast.yml: the cap's diff must use --no-renames"

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

echo "lane triggers (static):"
# `labeled` fires on EVERY label change — including the label moves the lanes themselves make with
# the dispatch token. Every job of a workflow that reacts to label changes must name, in its own
# `if:`, the label that fired the event, or it re-runs on unrelated transitions (adlc-intake once
# re-ran the Analyst at every stage and could drag an in-flight issue back to gate:stories).
# No pipes into `grep -q` here: under this file's pipefail an early-exiting reader can turn a
# match into a failure.
for W in "$ROOT"/templates/github/adlc-*.yml; do
  # Reacts to label changes: `labeled` among its types, or an `issues` trigger with no `types:`
  # at all (which means every activity type, `labeled` included).
  reacts=$(awk '
    /^on:/ { on=1; rest=$0; sub(/^on:[ \t]*/, "", rest); if (rest ~ /issues/) bare=1; next }
    on && /^[^ \t#]/ { on=0 }
    !on || /^[ \t]*#/ { next }
    /^  [A-Za-z_]+:/ { if (cur == "issues" && !typ) bare=1; cur=$1; sub(/:.*/, "", cur); typ=0 }
    /types:/ { typ=1 }
    /labeled/ { lab=1 }
    END { if (cur == "issues" && !typ) bare=1; if (lab || bare) print "yes" }' "$W")
  [ "$reacts" = "yes" ] || continue
  # jobs whose own `if:` never mentions github.event.label.name
  unfiltered=$(awk '
    function flush() { if (name != "" && !hit) printf "%s ", name }
    /^jobs:/ { j=1; next }
    !j || /^[ \t]*#/ { next }
    /^  [A-Za-z0-9_-]+:[ \t]*(#.*)?$/ { flush(); name=$1; sub(/:.*/, "", name); inif=0; hit=0; n++; next }
    /^    if:/ { inif=1 }
    inif && /^    [A-Za-z0-9_-]+:/ && !/^    if:/ { inif=0 }
    inif && /github\.event\.label\.name/ { hit=1 }
    END { flush(); if (!n) printf "(no jobs parsed) " }' "$W")
  eq "" "$(basename "$W"): every job's if names the label that fired" "$unfiltered"
done
# adlc-intake.yml: the concurrency group must admit exactly the runs its job will start (the job's
# `if` minus the author allowlist), and give every other event a group of its own. If the two
# drift, a run that is going to be skipped can share the group and cancel an in-flight Analyst.
I="$ROOT/templates/github/adlc-intake.yml"
flat() { awk -v a="$1" -v b="$2" '$0 ~ a {f=1; next} $0 ~ b {f=0} f {gsub(/^[ \t]+|[ \t]+$/, ""); printf "%s ", $0}' "$I"; }
pre='}}-${{ '; suf=" && 'start' || github.run_id }} "; allow=' && contains(fromJSON('
grp=$(flat '^  group: >-' '^  cancel-in-progress:'); grp=${grp#*"$pre"}; grp=${grp%"$suf"}
jif=$(flat '^    if: >' '^    runs-on:');             jif=${jif%"$allow"*}
[ -n "$jif" ] && eq "$jif" "adlc-intake.yml: concurrency group admits exactly the runs the job starts" "$grp" \
  || bad "adlc-intake.yml: could not read the job's if"

echo "intake steps (the workflow's own run: scripts against a stub gh):"
# The two shell steps of adlc-intake.yml decide whether the Analyst runs and what happens at
# Gate 1. Pull them out of the template and execute them, so that logic is tested as shipped.
step_run() { # <workflow file> <regex matching the step's `- name:` line>  → its `run: |` script
  awk -v pat="$2" '
    /^      - / { instep = ($0 ~ pat); inrun=0 }
    instep && /^        run: \|[ \t]*$/ { inrun=1; next }
    inrun { if ($0 ~ /^          / || $0 ~ /^[ \t]*$/) { sub(/^          /, ""); print } else inrun=0 }' "$1"
}
IT="$(mktemp -d)"; ST="$IT/state"
step_run "$I" '- name: Read the live issue state' > "$IT/live.sh"
step_run "$I" '- name: Gate 1 handoff'            > "$IT/gate.sh"
cat > "$IT/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: issue state lives in $ST (labels, comments); every write call is logged to $ST/calls
[ -n "${GH_FAIL_EDIT:-}" ] && [ "$1 $2" = "issue edit" ] && exit 1
case "$1 $2" in
  "issue view") case "$*" in *"--json labels"*) cat "$ST/labels" ;; *"--json comments"*) cat "$ST/comments" ;; *) exit 2 ;; esac ;;
  "issue comment"|"issue edit") shift; echo "$*" >> "$ST/calls" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$IT/gh"
intake() { # <script> <labels, space-separated> <comments> [ENV=val …] — runs it as Actions does (bash -e)
  local script="$1" labels="$2" comments="$3"; shift 3
  rm -rf "$ST"; mkdir -p "$ST"; : > "$ST/calls"; : > "$ST/out"
  printf '%s\n' $labels > "$ST/labels"; printf '%s\n' "$comments" > "$ST/comments"
  env PATH="$IT:$PATH" ST="$ST" N=7 GITHUB_OUTPUT="$ST/out" "$@" bash -e "$IT/$script" >/dev/null 2>&1
}
outs()  { tr '\n' ' ' < "$ST/out"; }
calls() { cut -d' ' -f1-6 "$ST/calls" | tr '\n' '|'; }
[ -s "$IT/live.sh" ] && [ -s "$IT/gate.sh" ] && ok "both run: scripts extracted from the template" || bad "could not extract the run: scripts"
intake live.sh "adlc:auto stage:intake" "";                 eq "intake=true autopilot=false "  "live: at auto-start intake"                     "$(outs)"
intake live.sh "adlc:auto adlc:autopilot stage:intake" "";  eq "intake=true autopilot=true "   "live: autopilot opt-in read before the Analyst" "$(outs)"
intake live.sh "adlc:auto adlc:autopilot stage:build" "";   eq "intake=false autopilot=true "  "live: stale run on an in-flight issue does nothing" "$(outs)"
intake live.sh "stage:intake" "";                           eq "intake=false autopilot=false " "live: paused issue (adlc:auto taken off) does nothing" "$(outs)"
intake gate.sh "adlc:auto stage:intake" "1. Which roles?" AUTOPILOT=false
eq "edit 7 --remove-label adlc:auto|comment 7 --body ⏸️ The Analyst|" "gate: paused → adlc:auto off, then the resume note" "$(calls)"
intake gate.sh "adlc:auto adlc:autopilot stage:intake gate:stories" "ADLC-TRIAGE: FULL | old round" AUTOPILOT=true
case "$(calls)" in *stage:design*) bad "gate: leftover gate:stories must not auto-advance a paused re-run" ;; *) ok "gate: leftover gate:stories does not auto-advance a paused re-run" ;; esac
intake gate.sh "adlc:auto stage:intake" "q" AUTOPILOT=false GH_FAIL_EDIT=1; check 1 "gate: a failed label removal stops the step" $?
eq "" "gate: …before the note that says it was removed" "$(calls)"
intake gate.sh "adlc:auto gate:stories" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=false
eq "" "gate: stories posted, no autopilot → Gate 1 left to the Principal" "$(calls)"
intake gate.sh "adlc:auto adlc:autopilot gate:stories" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=true
eq "edit 7 --remove-label gate:stories --add-label stage:design|" "gate: autopilot + FULL → stage:design" "$(calls)"
intake gate.sh "adlc:auto adlc:autopilot gate:stories" "ADLC-TRIAGE: FAST | copy fix" AUTOPILOT=true
eq "comment 7 --body 🚦 Triaged **FAST**|" "gate: autopilot + FAST → lane-approval note, never stage:fast" "$(calls)"
intake gate.sh "adlc:auto adlc:autopilot gate:stories" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=false
eq "" "gate: adlc:autopilot added mid-run is not honoured" "$(calls)"
intake gate.sh "adlc:auto gate:stories" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=true
eq "" "gate: adlc:autopilot taken off mid-run opts out" "$(calls)"
intake gate.sh "adlc:auto stage:design" "ADLC-TRIAGE: FULL | x" AUTOPILOT=true
eq "" "gate: neither stage:intake nor gate:stories → labels left alone" "$(calls)"
rm -rf "$IT"

echo "diff-scope step (the workflow's own run: script against a stub gh):"
# This step decides which issue and stage a PR is checked under — the part that once resolved
# every lane PR to "no stage" and skipped. Run it as shipped, in a checkout-shaped directory.
DS="$(mktemp -d)"; mkdir -p "$DS/bin" "$DS/repo/.adlc/scripts"
cp "$S/adlc-pr-stage.sh" "$S/adlc-branch-issue.sh" "$S/adlc-diff-scope.sh" "$DS/repo/.adlc/scripts/"
step_run "$ROOT/templates/github/adlc-diff-scope.yml" '- name: Enforce declared diff scope' > "$DS/step.sh"
cat > "$DS/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: each call answers from a file in $FX. No file → 404; a `fail-<name>` file → 502.
case "$*" in
  "pr view"*closingIssuesReferences*) k=closing ;;
  "pr view"*labels*)                  k=pr-labels ;;
  "api "*"/pulls/"*"/files"*)         k=files ;;
  "api "*"/issues/"*)                 k="issue-$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p')" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 2 ;;
esac
[ -e "$FX/fail-$k" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
[ -e "$FX/$k" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$FX/$k"
SH
chmod +x "$DS/bin/gh"
# dsfx <PR labels> <closing reference> <issue> <its labels | - (no such issue)> <its scope file | -> <changed files>
dsfx() {
  rm -rf "$DS/fx" "$DS/repo/.adlc/scope"; mkdir -p "$DS/fx" "$DS/repo/.adlc/scope"
  printf '%b' "$1" > "$DS/fx/pr-labels"; printf '%b' "$2" > "$DS/fx/closing"; printf '%b' "$6" > "$DS/fx/files"
  [ "$4" = - ] || printf '%b' "$4" > "$DS/fx/issue-$3"
  [ "$5" = - ] || printf '%b' "$5" > "$DS/repo/.adlc/scope/$3.txt"
}
dsrun() { # [head branch] — runs the step as Actions does (bash -e)
  ( cd "$DS/repo" && env PATH="$DS/bin:$PATH" FX="$DS/fx" PR=7 HEAD_REF="${1:-claude/work}" ADLC_TEST_DIRS=tests bash -e "$DS/step.sh" ) >/dev/null 2>&1
}
[ -s "$DS/step.sh" ] && ok "run: script extracted from the template" || bad "could not extract the run: script"
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'
dsrun; check 0 "full lane: a PR inside its declared scope passes" $?
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\nsrc/billing/y.py\n.adlc/scope/12.txt\n'
dsrun; check 1 "full lane: a file outside the scope fails (was: 'no stage — skipped')" $?
dsfx '' '12\n' 12 'stage:build\n' - 'src/api/x.py\n'
dsrun; check 1 "full lane: a PR that declares no scope fails" $?
dsfx '' '12\n' 12 'stage:qa\ngate:deploy\n' 'src/api/\n' 'src/api/x.py\ntests/t.py\n.adlc/scope/12.txt\n'
dsrun; check 0 "issue at stage:qa: QA's tests on the Builder's PR pass" $?
dsfx 'adlc:changes-requested\n' '12\n' 12 'stage:qa\n' 'src/api/\n' 'tests/t.py\nsrc/billing/y.py\n'
dsrun; check 1 "issue at stage:qa: outside scope and tests fails" $?
dsfx '' '13\n' 13 'stage:fast\n' 'README.md\n' 'README.md\n.adlc/scope/13.txt\n'
dsrun; check 0 "fast lane at opened (lane:fast not on the PR yet) passes in scope" $?
dsfx 'lane:fast\n' '13\n' 13 'gate:deploy\n' 'README.md\n' 'README.md\nsrc/late.py\n'
dsrun; check 1 "fast lane after PASS: a late out-of-scope push fails" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n.adlc/scope/12.txt\n'
dsrun feat/12-add-login; check 1 "no closing reference: the branch names the issue" $?
dsfx '' '' 12 'stage:build\n' - 'src/api/x.py\n'
dsrun feat/12-add-login; check 1 "…and a lane branch that declares no scope fails" $?
dsfx '' '' 12 'stage:qa\ngate:deploy\n' 'src/api/\n' 'src/a.py\ndocs/x.md\n.adlc/scope/12.txt\n.adlc/scope/13.txt\n'
dsrun release/next; check 0 "a PR that merely carries scope files (a promotion, a cleanup) is tied to no issue" $?
dsfx '' '' 2026 - - 'CHANGELOG.md\n'
dsrun release/2026-10; check 0 "a branch number that is no issue here ties the PR to none" $?
dsfx '' '12\n' 12 'stage:design\n' 'README.md\n' 'src/api/x.py\ndocs/adr/7.md\n'
dsrun; check 0 "issue at stage:design (a bounced fast PR) is skipped" $?
dsfx 'dependencies\n' '' 0 - - 'package.json\n'
dsrun dependabot/npm_and_yarn/left-pad-1.3.0; check 0 "a PR tied to no issue is skipped" $?
dsfx 'stage:qa\n' '' 0 - - 'tests/t.py\nsrc/app.py\n'
dsrun; check 1 "PR-label fallback: stage:qa is tests-only" $?
dsfx 'lane:fast\n' '' 0 - - 'README.md\n'
dsrun; check 1 "lane:fast with no issue and no scope file fails" $?
for k in pr-labels files closing issue-12; do   # an API error must never read as "nothing to check"
  dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n'; : > "$DS/fx/fail-$k"
  dsrun; check 1 "a failed gh call ($k) fails the check" $?
done
# The stub does not run --jq. Where a real jq exists, run the two non-trivial filters as shipped.
if command -v jq >/dev/null 2>&1; then
  cf=$(sed -n "s/.*closingIssuesReferences --jq '\(.*\)')\$/\1/p" "$DS/step.sh")
  ff=$(sed -n "s/.*per_page=100\" --jq '\(.*\)')\$/\1/p" "$DS/step.sh")
  pr='{"url":"https://github.com/o/r/pull/7","closingIssuesReferences":[{"number":123,"url":"https://github.com/o/tracker/issues/123"},{"number":45,"url":"https://github.com/o/r/issues/45"}]}'
  eq 45 "closing reference: the first one in THIS repo"        "$(printf '%s' "$pr" | jq -r "$cf" 2>&1)"
  eq "" "closing reference: only another repo's → none"        "$(printf '%s' '{"url":"https://github.com/o/r/pull/7","closingIssuesReferences":[{"number":123,"url":"https://github.com/o/r-fork/issues/123"}]}' | jq -r "$cf" 2>&1)"
  eq "src/api/new.py src/db/old.py a.py " "file list: a rename counts under both paths" "$(printf '%s' '[{"filename":"src/api/new.py","previous_filename":"src/db/old.py"},{"filename":"a.py"}]' | jq -r "$ff" 2>&1 | tr '\n' ' ')"
else
  echo "  · skipped the --jq filter checks (no jq here)"
fi
rm -rf "$DS"

echo "pre-commit hook (run directly in a scratch repo):"
HK="$(mktemp -d)"; git init -q "$HK" >/dev/null 2>&1
hg()     { git -C "$HK" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
hook()   { ( cd "$HK/${1:-}" && bash "$ROOT/templates/hooks/pre-commit" ) >/dev/null 2>&1; }
branch() { hg symbolic-ref HEAD "refs/heads/$1"; }
mkdir -p "$HK/.adlc/scripts" "$HK/.adlc/scope" "$HK/src/api" "$HK/src/db" "$HK/tests"
cp "$S/adlc-diff-scope.sh" "$S/adlc-branch-issue.sh" "$HK/.adlc/scripts/"; chmod +x "$HK"/.adlc/scripts/*.sh
branch feat/12-add-login
: > "$HK/src/api/a.py"; hg add src
hook; check 0 "no scope file for the branch's issue → no-op" $?
printf 'src/api/\n' > "$HK/.adlc/scope/12.txt"; hg add .adlc/scope
hook; check 0 "the scope file staged with an in-scope file passes" $?
: > "$HK/src/db/b.py"; hg add src
hook; check 1 "a staged file outside the scope blocks the commit" $?
hook src/api; check 1 "…also when run from a subdirectory" $?
branch fix/unrelated
hook; check 0 "a branch that names no issue is held to no scope" $?
branch feat/12-add-login
: > "$HK/.git/MERGE_HEAD"
hook; check 0 "concluding a merge is not blocked (its staged files are other people's)" $?
rm -f "$HK/.git/MERGE_HEAD"; hg rm -q --cached src/db/b.py
: > "$HK/tests/t.py"; hg add tests
hook; check 0 "QA's test outside the Builder's prefixes passes" $?
: > "$HK/src/api/café.py"; hg add src/api
hook; check 0 "a non-ASCII path in scope passes (git does not quote it)" $?
printf 'one\ntwo\nthree\n' > "$HK/src/db/old.py"; hg add src/db/old.py; hg commit -q -m base >/dev/null 2>&1
hg mv src/db/old.py src/api/moved.py
hook; check 1 "moving a file out of an undeclared directory is caught" $?
rm -rf "$HK"

echo "labels.sh (against a stub gh):"
# GitHub rejects a label description over 100 characters (HTTP 422); under labels.sh's `set -e`
# that stops the script, so every label after the offending one is never created. Run the real
# script against a stub that enforces the limit (in bytes, which can only over-count).
LB="$(mktemp -d)"
cat > "$LB/gh" <<'SH'
#!/usr/bin/env bash
# stub: gh label create <name> --color <c> --description <d> --force
[ "$1 $2" = "label create" ] || exit 2
name="$3"; desc=""
while [ $# -gt 0 ]; do [ "$1" = "--description" ] && desc="$2"; shift; done
LC_ALL=C
[ "${#desc}" -le 100 ] || { echo "HTTP 422: description is too long (maximum is 100 characters)" >&2; exit 1; }
echo "$name" >> "$LB_OUT"
SH
chmod +x "$LB/gh"; : > "$LB/created"
LB_OUT="$LB/created" PATH="$LB:$PATH" bash "$ROOT/templates/github/labels.sh" >/dev/null 2>&1; check 0 "labels.sh runs to the end (no description over GitHub's 100-char limit)" $?
eq "$(grep -c '^create "' "$ROOT/templates/github/labels.sh")" "…and creates every label it lists" "$(grep -c . "$LB/created")"
rm -rf "$LB"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
