#!/usr/bin/env bash
# Unit tests for the ADLC guardrail scripts. Plain bash; the guard hook also needs python3 + git.
# Run: bash tests/run.sh   (exit 0 = all pass). These verify the deterministic guardrails
# themselves — the same scripts CI and the local pre-commit hook call — plus the plugin's guard
# hook. The static checks cover what can't be run here for real: the workflow templates (their
# triggers, their agent wiring, the intake, diff-scope and design-handoff steps against a stub
# gh, and the fast lane's and the fix loop's cap steps on a real git history), the pre-commit
# hook, labels.sh, adlc-metrics.sh (against a stub gh), and the agents: thin wrappers over the
# role skills, the vendored copies the wizard fills, the RUNBOOK that invokes them, /adlc-model.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/templates/scripts"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
# expect_exit <expected-code> <name> -- <cmd...>  (cmd reads stdin already piped)
check() { local want="$1" name="$2" got="$3"; [ "$got" = "$want" ] && ok "$name" || bad "$name (want exit $want, got $got)"; }
eq()    { local want="$1" name="$2" got="$3"; [ "$got" = "$want" ] && ok "$name" || bad "$name (want '$want', got '$got')"; }
# Run from a git hook, a `!` alias or `git rebase -x`, this script inherits GIT_DIR and its kin,
# and every `git -C <scratch repo>` below would then act on the caller's repository instead of
# the scratch one. Drop them: the fixtures may only ever touch what they create.
unset $(git rev-parse --local-env-vars 2>/dev/null)

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
printf 'src/api/x.py\n'             | ds build "./$SC"; check 0 "build reads a scope file named with a ./ prefix" $?
printf 'tests/t.py\n'                | ds qa; check 0 "qa default: tests/ is a test dir" $?
printf 'testsuite/t.py\n'            | ds qa; check 1 "qa default: testsuite/ is not (the default ends in /)" $?
printf 'tests_x.py\n'                | ds qa; check 1 "qa default: tests_x.py is not a test dir" $?
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
# …and no prefix can bring it in: merged, it would be the scope a later PR is held to, out of that PR's diff
scope 'src/api/\n.adlc/scope/\n'
printf 'src/api/x.py\n%s\n.adlc/scope/13.txt\n' "$SC" | ds build "$SC"; check 1 "another issue's scope file is refused even under a declared prefix" $?
case "$( cd "$T" && printf '.adlc/scope/13.txt\n' | bash "$S/adlc-diff-scope.sh" fast "$SC" 2>&1 )" in *"another issue's scope file"*) ok "…and the refusal says why" ;; *) bad "the refusal of another issue's scope file must say why" ;; esac
printf '.adlc/scope/README.md\n%s\n' "$SC" | ds build "$SC"; check 0 "…while any other file under that prefix is an ordinary file" $?
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
{ printf 'src/api/\n'; i=0; while [ $i -lt 600 ]; do echo "p$i/"; i=$((i+1)); done; } > "$T/$SC"
printf 'src/api/x.py\n'             | ds build "$SC"; check 1 "a scope file with hundreds of prefixes is refused" $?

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
eq build+qa  "labels joined by spaces resolve the same"          "$(st 'lane:x adlc:auto' 'stage:qa gate:deploy')"
eq fast      "…and by tabs or CRLF"                                "$(st $'lane:fast\tadlc:changes-requested' $'stage:fast\r\n')"
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
eq 12 "feat/012-x → 12 (leading zeros dropped, so the scope file is 12.txt)" "$(bi feat/012-x)"
eq 7  "fix/0007 → 7"                                                      "$(bi fix/0007)"
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
printf '.adlc/local-ci.txt\n'                 | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "the local CI battery file forces full (a fast-lane PR may not choose what adlc-local-ci.sh runs on it)" $?
printf '1\t3\t.adlc/local-ci.txt\n'           | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "…in numstat form too" $?
printf 'docs/local-ci.txt\n'                  | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "a file merely named like it elsewhere is not" $?
printf 'package.json\n'                       | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "dependency manifest forces full" $?
printf '.gitmodules\n'                        | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 ".gitmodules is a dependency manifest: forces full (it names where submodules come from)" $?
printf '2\t1\t.gitmodules\n'                  | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "…in numstat form too (a url or branch change leaves the pointer alone)" $?
printf 'docs/gitmodules.md\n'                 | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "a file merely named like it is not" $?
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
# git C-quotes a path with a non-ASCII byte or a quote; the quote must not hide it from the denylist
printf '3\t0\t"auth/\\303\\251.py"\n'              | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a quoted path under auth/ is still sensitive" $?
printf '1\t0\t"src/d\\303\\251/package.json"\n'    | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a quoted dependency manifest is still sensitive" $?
printf '"auth/a\\"b.py"\n'                            | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "…also as a bare path" $?
printf '2\t0\t"src/caf\\303\\251.py"\n'            | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "a quoted innocent path is still fast" $?
# A submodule is a gitlink (mode 160000): numstat shows it as a one-line file however much code
# the commit it points to brings in. The workflows take `git diff --numstat --raw` in one call, so
# the script also gets each entry's mode line, and a gitlink on either side is never fast-eligible.
raw() { printf ':%s %s 0960115 5c62b5a %s\t%s\n' "$@"; }   # a raw line: <old mode> <new mode> <status> <path>
{ raw 160000 160000 M vendor/lib; printf '1\t1\tvendor/lib\n'; } | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a submodule bump forces full (numstat alone: a one-line change)" $?
case "$({ raw 160000 160000 M vendor/lib; printf '1\t1\tvendor/lib\n'; } | bash "$S/adlc-triage.sh" 2>&1 >/dev/null)" in *"submodule change: vendor/lib"*) ok "…and the reason names the submodule" ;; *) bad "the reason must name the submodule" ;; esac
{ raw 000000 160000 A vendor/lib; printf '1\t0\tvendor/lib\n'; } | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a new submodule forces full" $?
{ raw 160000 000000 D vendor/lib; printf '0\t1\tvendor/lib\n'; } | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a removed submodule forces full" $?
{ raw 100644 160000 T src/a.py; printf '1\t1\tsrc/a.py\n'; }     | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a file turned into a submodule forces full" $?
{ raw 160000 160000 M '"vendor/caf\303\251"'; printf '1\t1\t"vendor/caf\\303\\251"\n'; } | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "…a quoted submodule path too" $?
{ raw 000000 160000 A .adlc/scope/12.txt; printf '1\t0\t.adlc/scope/12.txt\n'; } | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "a submodule at the scope file's path is not exempt" $?
{ raw 100644 100644 M src/a.py; raw 000000 100755 A bin/run; printf '2\t1\tsrc/a.py\n3\t0\tbin/run\n'; } | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 0 "ordinary files with their mode lines stay fast" $?
six=$(for f in a b c d e f; do raw 100644 100644 M "src/$f.py"; done; for f in a b c d e f; do printf '1\t0\tsrc/%s.py\n' "$f"; done)
case "$(printf '%s\n' "$six" | bash "$S/adlc-triage.sh" 2>&1 >/dev/null)" in *"too many files: 6 > 5"*) ok "a mode line is not a second file (6 files with their modes count as 6)" ;; *) bad "a mode line must not count as a file" ;; esac
raw 100644 100644 M src/a.py | bash "$S/adlc-triage.sh" >/dev/null 2>&1; check 1 "mode lines alone measure nothing: not fast" $?
grep -q -- 'diff --numstat --no-renames' "$ROOT/templates/github/adlc-fast.yml" && ok "adlc-fast.yml takes the cap's diff with --no-renames" || bad "adlc-fast.yml: the cap's diff must use --no-renames"
# Both workflows take that diff with the modes (--raw) and with every submodule entry in it
# (--ignore-submodules=none: a `.gitmodules` saying `ignore = all` in the checkout — the PR's in
# adlc-fast.yml, the default branch's in adlc-diff-scope.yml — would otherwise leave it out).
grep -qF -- 'diff --numstat --no-renames --raw --ignore-submodules=none "$base"' "$ROOT/templates/github/adlc-fast.yml" && ok "…with the modes, and every submodule entry" || bad "adlc-fast.yml: the cap's diff must take --raw --ignore-submodules=none"
grep -qF -- 'diff --numstat --no-renames --raw --ignore-submodules=none "$base" refs/remotes/pr/head' "$ROOT/templates/github/adlc-diff-scope.yml" && ok "adlc-diff-scope.yml: its copy of the cap's diff takes the same flags" || bad "adlc-diff-scope.yml: the cap's diff must take --no-renames --raw --ignore-submodules=none"

echo "verdict:"
eq PASS    "last marker wins"        "$(printf 'ADLC-ADV: CHANGES\nblah\nADLC-ADV: PASS\n' | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq CHANGES "reads CHANGES"           "$(printf 'ADLC-ARCH: CHANGES\n'                       | bash "$S/adlc-verdict.sh" ADLC-ARCH)"
eq ""      "empty when no marker"    "$(printf 'nothing here\n'                            | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq ""      "an unclear last marker line is not PASS, whatever came before" "$(printf 'format: ADLC-ADV: PASS\n\nADLC-ADV: Changes needed, see above\n' | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq ""      "PASSED is not PASS"       "$(printf 'ADLC-ADV: PASSED\n'                        | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq ""      "lowercase is not a verdict" "$(printf 'ADLC-ADV: pass\n'                        | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq PASS    "bold markup around the marker is fine" "$(printf '**ADLC-ADV:** PASS\n'         | bash "$S/adlc-verdict.sh" ADLC-ADV)"
eq CHANGES "a verdict in a list item"  "$(printf -- '- ADLC-ARCH: CHANGES (two findings)\n' | bash "$S/adlc-verdict.sh" ADLC-ARCH)"
eq CHANGES "ADLC-ADV does not read ADLC-ADV-X" "$(printf 'ADLC-ADV-X: PASS\nADLC-ADV: CHANGES\n' | bash "$S/adlc-verdict.sh" ADLC-ADV)"

echo "fix-cap:"
eq GO   "GO below cap"   "$(printf 'adlc-fix: a\nadlc-fix: b\n'              | bash "$S/adlc-fix-cap.sh" 3)"
eq STOP "STOP at cap"    "$(printf 'adlc-fix: a\nadlc-fix: b\nadlc-fix: c\n' | bash "$S/adlc-fix-cap.sh" 3)"
eq GO   "GO when none"   "$(printf 'feat: x\nfix: y\n'                       | bash "$S/adlc-fix-cap.sh" 3)"
eq STOP "a scoped subject adlc-fix(<scope>): counts" "$(printf 'adlc-fix(api): a\nadlc-fix: b\nadlc-fix(db): c\n' | bash "$S/adlc-fix-cap.sh" 3)"
eq GO   "adlc-fixed: is not a fix round"            "$(printf 'adlc-fixed: a\nadlc-fix-up: b\nadlc-fix: c\n' | bash "$S/adlc-fix-cap.sh" 2)"
printf 'adlc-fix: a\n' | bash "$S/adlc-fix-cap.sh" abc >/dev/null 2>&1; check 2 "a max that is not a number is an error, not a GO" $?
eq "" "…and prints no verdict" "$(printf 'adlc-fix: a\n' | bash "$S/adlc-fix-cap.sh" 3x 2>/dev/null)"
eq GO "an empty max is the default 3, not an error" "$(printf 'adlc-fix: a\nadlc-fix: b\n' | bash "$S/adlc-fix-cap.sh" '')"

echo "tripwire-check:"
printf 'sha1 1\nsha2 2\n' | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 0 "OK when all have PRs" $?
printf 'sha1 1\nsha2 0\n' | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 1 "fails on a direct push" $?
printf 'sha1 1\nsha2\n'   | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 1 "a missing count (failed lookup) is a direct push, not a pass" $?
printf 'sha1 1\nsha2 null\n' | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 1 "a non-numeric count (null, an error body) is a direct push" $?
printf 'sha1 1\r\nsha2 2\r\n' | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 0 "CRLF input still reads the counts" $?
printf 'sha1 1\nsha2 0'    | bash "$S/adlc-tripwire-check.sh" >/dev/null 2>&1; check 1 "a last line with no newline is still read" $?
eq "DIRECT: sha2" "…and names the commit" "$(printf 'sha1 1\nsha2 0' | bash "$S/adlc-tripwire-check.sh" 2>/dev/null)"
grep -q '^  pull-requests: read' "$ROOT/templates/github/adlc-main-tripwire.yml" && ok "adlc-main-tripwire.yml grants pull-requests: read (the commit→PR lookup is a 403 without it on a private repo)" || bad "adlc-main-tripwire.yml: needs pull-requests: read"
grep -qE '^\s+commits=\$\(git rev-list --no-merges \$range\)$' "$ROOT/templates/github/adlc-main-tripwire.yml" && ok "…and a failed rev-list fails the step instead of reading as no commits" || bad "adlc-main-tripwire.yml: rev-list must be its own statement with no 2>/dev/null"

echo "doctor (placeholder scan):"
FIX="$(mktemp -d)"
mkdir -p "$FIX/.claude/skills/project-conventions" "$FIX/.claude/skills/release-ops" "$FIX/.claude/agents" "$FIX/.github/workflows"
printf '{"permissions":{"deny":["Bash(gh pr merge:*)"]}}' > "$FIX/.claude/settings.json"
echo x > "$FIX/.claude/skills/project-conventions/SKILL.md"
echo x > "$FIX/.claude/skills/release-ops/SKILL.md"
agent_copy() { printf -- '---\nname: adlc-%s\ndescription: x\ntools: Read, Skill\nskills:\n  - adlc:role-%s\nmodel: %s\n---\n\nx\n' "$1" "$1" "$2" > "$FIX/.claude/agents/adlc-$1.md"; }
for a in product-analyst architect builder adversarial-reviewer qa-release-ops; do agent_copy "$a" opus; done
printf 'if: "{{PRINCIPAL}}"\n' > "$FIX/.github/workflows/adlc-x.yml"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "flags unfilled placeholder" $?
printf 'if: "someuser"\n' > "$FIX/.github/workflows/adlc-x.yml"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 0 "passes when filled + skills + deny present" $?
printf '{"permissions":{"allow":["Bash(gh pr merge:*)"],"deny":[]}}' > "$FIX/.claude/settings.json"
ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "flags 'gh pr merge' that is only in the allow list" $?
printf '{"permissions":{"deny":["Bash(gh pr merge:*)"]}}' > "$FIX/.claude/settings.json"   # restore

echo "doctor (tooling version stamp):"
PL="$(mktemp -d)"; mkdir -p "$PL/.claude-plugin"; printf '{"name":"adlc","version":"9.9.9"}' > "$PL/.claude-plugin/plugin.json"
vdoc() { ADLC_PLUGIN_ROOT="$PL" CLAUDE_CONFIG_DIR="$PL/none" ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1; }
mkdir -p "$FIX/.adlc"; echo 9.9.9 > "$FIX/.adlc/VERSION"
eq 1 "a matching .adlc/VERSION is confirmed" "$(vdoc | grep -c 'tooling version 9.9.9 matches')"
echo 0.1.0 > "$FIX/.adlc/VERSION"
eq 1 "a different .adlc/VERSION says to run /adlc-init" "$(vdoc | grep -c 'from plugin 0.1.0, the plugin is 9.9.9 — run /adlc-init')"
vdoc >/dev/null; check 0 "…and a stale stamp is a note, not a failure" $?
rm "$FIX/.adlc/VERSION"
eq 1 "a missing .adlc/VERSION says the tooling predates stamping" "$(vdoc | grep -c 'no .adlc/VERSION')"
eq 1 "no plugin found: the check is skipped, not failed" "$(CLAUDE_PLUGIN_ROOT= ADLC_PLUGIN_ROOT= CLAUDE_CONFIG_DIR="$PL/none" ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'skipped tooling-version check')"
mkdir -p "$PL/cfg/plugins"; printf '{"plugins":{"adlc@adlc-pipeline":[{"installPath":"%s"}]}}' "$PL" > "$PL/cfg/plugins/installed_plugins.json"
eq 1 "falls back to the install path in installed_plugins.json" "$(CLAUDE_PLUGIN_ROOT= ADLC_PLUGIN_ROOT= CLAUDE_CONFIG_DIR="$PL/cfg" ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'plugin is 9.9.9')"
grep -q "write the plugin's version to" "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap writes .adlc/VERSION" || bad "bootstrap: must write .adlc/VERSION"
rm -rf "$FIX/.adlc"
echo "marketplace (release pin):"
eq "github" "the adlc entry is a github source" "$(jq -r '.plugins[]|select(.name=="adlc").source.source' "$ROOT/.claude-plugin/marketplace.json")"
eq "juanjtov/adlc-pipeline" "…of this repo" "$(jq -r '.plugins[]|select(.name=="adlc").source.repo' "$ROOT/.claude-plugin/marketplace.json")"
case "$(jq -r '.plugins[]|select(.name=="adlc").source.ref' "$ROOT/.claude-plugin/marketplace.json")" in v[0-9]*.[0-9]*.[0-9]*) ok "…pinned to a release tag (vX.Y.Z)";; *) bad "marketplace: ref must be a vX.Y.Z tag";; esac
grep -q "^## \[\?$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" "$ROOT/CHANGELOG.md" && ok "CHANGELOG.md has an entry for the plugin.json version" || bad "CHANGELOG.md: no entry for the plugin.json version"
# A note, not a failure: the release recipe (CHANGELOG.md) tags before it moves the ref, so the
# release PR's own CI runs one tag behind by design. Without it a forgotten ref move prints nothing.
mref="$(jq -r '.plugins[]|select(.name=="adlc").source.ref' "$ROOT/.claude-plugin/marketplace.json")"
pver="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
[ "$mref" = "v$pver" ] || echo "  · note: marketplace ref $mref is not v$pver, the plugin.json version (release recipe step 4 pending, or a rollback)"
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
# a lane that calls the action with no plugin and no tools starts, and its agent can do nothing
doctor() { ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; }
lane()   { printf "$@" > "$FIX/.github/workflows/adlc-x.yml"; }
echo "doctor (project agents — the RUNBOOK invokes these copies):"
eq 1 "reports each copy with its model" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'agent: adlc-builder (model: opus)')"
rm "$FIX/.claude/agents/adlc-builder.md";     doctor; check 1 "flags a missing agent copy" $?
agent_copy builder '{{BUILDER_MODEL}}';       doctor; check 1 "flags an unfilled model placeholder" $?
agent_copy builder '';                        doctor; check 1 "flags an empty model line" $?
printf -- '---\nname: adlc-builder\ntools: Read\n---\n\nmodel: fable is only mentioned in the body\n' > "$FIX/.claude/agents/adlc-builder.md"
doctor; check 1 "a model: line outside the frontmatter does not count" $?
printf -- '---\nname: adlc-builder\nmodel: "sonnet"   # until the next retro\n---\n\nx\n' > "$FIX/.claude/agents/adlc-builder.md"
eq 1 "a quoted model line with a comment is read as its value" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'agent: adlc-builder (model: sonnet)')"
printf -- '---\r\nname: adlc-builder\r\nmodel: haiku\r\n---\r\n\r\nx\r\n' > "$FIX/.claude/agents/adlc-builder.md"
eq 1 "a CRLF file is read the same" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'agent: adlc-builder (model: haiku)')"
agent_copy builder fable;                     doctor; check 0 "passes with all five copies and their models" $?
eq 1 "…reporting the model set" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'agent: adlc-builder (model: fable)')"
J='jobs:\n  a:\n    steps:\n'
USES='      - uses: anthropics/claude-code-action@v1\n        with:\n'
MKT='          plugin_marketplaces: "https://github.com/o/adlc-pipeline.git"\n'
PLUG='          plugins: "adlc@adlc-pipeline"\n'
ARGS='          claude_args: |\n            --agent adlc:builder\n            --allowedTools "Read"\n'
WIRED="${USES}${MKT}${PLUG}${ARGS}"'          prompt: |\n            - a bullet in the prompt is not a new step\n'
BARE='      - name: old\n        uses: "anthropics/claude-code-action@v1"\n        with:\n          prompt: go\n'
lane "${J}${USES}"'          prompt: go\n';                    doctor; check 1 "flags a lane with no plugin / no tools" $?
lane "${J}${WIRED}";                                         doctor; check 0 "passes a lane that installs the plugin + grants tools" $?
lane "${J}${USES}${PLUG}${ARGS}";                            doctor; check 1 "flags a step with no plugin_marketplaces" $?
lane "${J}${USES}${MKT}"'          plugins: "other@somewhere"\n'"${ARGS}"; doctor; check 1 "flags a step that installs some other plugin" $?
lane "${J}${USES}${MKT}"'          plugins: |\n            other@somewhere\n            adlc@my-fork\n'"${ARGS}"; doctor; check 0 "plugins as a block list, adlc among them" $?
lane "${J}${USES}${MKT}${PLUG}"'          claude_args: --agent adlc:builder --allowedTools "Read"\n'; doctor; check 0 "flags written on the claude_args line itself" $?
lane "${J}${USES}${MKT}${PLUG}"'          claude_args: |\n            --agent adlc:builder --permission-mode dontAsk --allowedTools "Read"\n'; doctor; check 0 "flags sharing one line of the block" $?
lane "${J}${USES}"'          # plugin_marketplaces: "https://x.git"\n          # plugins: "adlc@adlc-pipeline"\n          # claude_args: --allowedTools "Read"\n          prompt: go\n'
doctor; check 1 "commented-out wiring does not count" $?
lane "${J}"'      # - uses: anthropics/claude-code-action@v1\n      - run: echo hi\n'
eq 0 "a commented-out agent step is not an agent step" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'agent step')"
lane "${J}"'      - uses: actions/checkout@v4\n'"${WIRED}${BARE}"; doctor; check 1 "one wired step does not vouch for an unwired one (quoted uses: too)" $?
lane "${J}"'      - uses: actions/checkout@v4\n'"${WIRED}"'  b:\n    steps:\n'"${WIRED}"; doctor; check 0 "passes two wired steps across two jobs" $?
eq 1 "says how many agent steps it checked" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'all 2 agent steps')"
lane 'jobs:\n  a:\n    steps:  # the lane\n      - uses: actions/checkout@v4\n'"${WIRED}${BARE}"; doctor; check 1 "a comment after steps: does not hide an unwired step" $?
printf "${J}"'      - uses: actions/checkout@v4\n'"${WIRED}${BARE}" | awk '{ printf "%s\r\n", $0 }' > "$FIX/.github/workflows/adlc-x.yml"
doctor; check 1 "CRLF line endings do not hide an unwired step" $?
lane "${J}${USES}${MKT}${PLUG}"'          prompt: |\n            Remember to pass --allowedTools "Read" some day.\n'; doctor; check 1 "a prompt that only mentions --allowedTools is not a grant" $?
# the prompt comes BEFORE the wiring here: if its `steps:` line opened a new list, the wiring
# below it would belong to no agent step and the lane would be flagged
lane "${J}${USES}"'          prompt: |\n            Follow these\n            steps:\n            - one\n'"${MKT}${PLUG}${ARGS}"; doctor; check 0 "a prompt line reading steps: does not split a wired step" $?
lane "${J}${WIRED}"'      -\n        uses: anthropics/claude-code-action@v1\n        with:\n          prompt: go\n'; doctor; check 1 "a step whose dash sits on its own line is still its own step" $?
# steps listed at the indent of their `steps:` key (valid YAML): job a wired, job b not
flush_left() { printf "$1" | sed 's/^  //'; }
{ printf 'jobs:\n  a:\n    steps:\n'; flush_left "${WIRED}"; printf '  b:\n    steps:\n'; flush_left "${BARE}"; } > "$FIX/.github/workflows/adlc-x.yml"
doctor; check 1 "steps at the indent of their steps: key — an unwired second job is caught" $?
{ printf 'jobs:\n  a:\n    steps:\n'; flush_left "${WIRED}"; printf '  b:\n    steps:\n'"${BARE}"; } > "$FIX/.github/workflows/adlc-x.yml"
doctor; check 1 "…also when the second job indents its steps" $?
eq 2 "fixture really has two jobs with one agent step each" "$(grep -c 'claude-code-action' "$FIX/.github/workflows/adlc-x.yml")"
lane 'jobs:\n  t:\n    steps:\n      - run: echo hi\n'
eq 0 "claims nothing when no workflow runs an agent" "$(ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" 2>&1 | grep -c 'agent steps')"
# a lane that calls a guard script the host never installed
lane 'jobs:\n  t:\n    steps:\n      - run: |\n          chmod +x .adlc/scripts/adlc-verdict.sh\n          .adlc/scripts/adlc-verdict.sh < c.txt\n'
doctor; check 1 "flags a lane whose script is not installed" $?
mkdir -p "$FIX/.adlc/scripts"; : > "$FIX/.adlc/scripts/adlc-verdict.sh"
doctor; check 0 "…and passes once it is" $?
lane 'jobs:\n  t:\n    steps:\n      # .adlc/scripts/adlc-gone.sh used to run here\n      - run: echo hi\n'
doctor; check 0 "a script named only in a comment is not required" $?
# the merge gate — asked of a stub gh that answers each lookup from a file (no file = that call fails);
# the double-label check — `issue list` / `pr list` serve $DFX/issues and $DFX/prs (no file = an
# empty list, a `fail-<name>` file = that call fails) through the call's own --jq, as the real gh does
mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$DFX/calls"
# The real gh picks the repository from the current directory. Mimic that: the labels exist
# only when asked from inside the fixture root (DFX_ROOT), so a doctor that runs gh from the
# caller's cwd sees none of them. An unset DFX_ROOT would make `here` always true, so refuse it.
: "${DFX_ROOT:?fake gh needs DFX_ROOT}"
here() { [ "$(pwd -P)" = "$(cd "$DFX_ROOT" && pwd -P)" ]; }
case "$*" in
  "auth status"*) [ -e "$DFX/noauth" ] && exit 1; exit 0 ;;
  "label list"*)  here && printf '%s\n' stage:intake gate:stories stage:design stage:build stage:qa gate:deploy; exit 0 ;;
  "repo view"*|"api "*|"issue list"*|"pr list"*|"run "*) here || { echo "fake gh: asked from $PWD, not the fixture root" >&2; exit 1; } ;;
esac
case "$1 $2" in
  "issue list"|"pr list"|"run list"|"run view")
    # issues / prs / runs: a JSON list in $DFX/<k> (none = an empty list); run view: $DFX/jobs (none = the call fails)
    case "$1 $2" in "run view") k=jobs ;; *) k="${1}s" ;; esac
    [ -e "$DFX/fail-$k" ] && { echo '{"message":"Server Error"}' >&2; exit 1; }
    f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done
    if [ -e "$DFX/$k" ]; then jq -r "$f" "$DFX/$k"; elif [ "$k" = jobs ]; then echo 'run not found' >&2; exit 1; else echo '[]' | jq -r "$f"; fi; exit $? ;;
esac
case "$*" in
  "repo view"*)                 k=default ;;
  "api "*"/protection"*)        k=classic ;;
  "api "*"/rules/branches/"*)   k=ruleset ;;
  "api "*"/branches/"*)         k=protected ;;
  *) exit 2 ;;
esac
[ -e "$DFX/$k" ] || { echo '{"message":"Not Found"}'; exit 1; }
cat "$DFX/$k"
SH
chmod +x "$FIX/bin/gh"
gate() { # <protected flag | -> <approvals in classic protection | -> <approvals in a ruleset, or none | -> [tripwire]
  rm -rf "$FIX/fx"; mkdir -p "$FIX/fx"; echo main > "$FIX/fx/default"
  [ "$1" = - ] || echo "$1" > "$FIX/fx/protected"
  [ "$2" = - ] || echo "$2" > "$FIX/fx/classic"
  [ "$3" = - ] || echo "$3" > "$FIX/fx/ruleset"
  rm -f "$FIX/.github/workflows/adlc-main-tripwire.yml"
  if [ "${4:-}" = tripwire ]; then echo 'name: tripwire' > "$FIX/.github/workflows/adlc-main-tripwire.yml"; fi
  GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1)
}
says_gate() { case "$GATE" in *"$1"*) echo yes ;; *) echo no ;; esac; }
lane "${J}${WIRED}"   # a lane runs an agent here: the gate matters
gate true 1 none;            check 0 "gate: protected + 1 required approval passes" $?
eq yes "…and says so" "$(says_gate "needs 1 approving review")"
gate true 0 none;            check 1 "gate: protected but no approval required is flagged (a lane's token could merge its own PR)" $?
eq yes "…with the reason" "$(says_gate "needs no approving review")"
gate true - none;            check 0 "gate: protected, approvals unreadable (not an admin) passes with a reminder" $?
eq yes "…the reminder" "$(says_gate "could not read whether a pull request needs")"
gate false - 2;              check 0 "gate: a ruleset that requires approvals counts as protection" $?
eq yes "…with its count" "$(says_gate "needs 2 approving review")"
gate false - none tripwire;  check 0 "gate: not protected, tripwire installed passes" $?
eq yes "…and says what the tripwire cannot do" "$(says_gate "cannot stop a merge")"
gate false - none;           check 1 "gate: not protected and no tripwire is flagged" $?
eq yes "…as no merge gate" "$(says_gate "no merge gate")"
gate - - -;                  check 1 "gate: a failed lookup is flagged, not passed" $?
# the double-label check (issue 38): one state per issue — `issue list` and `pr list` through the stub
dl() { # <issues json | -> <prs json | -> : seeds a sound gate fixture, then the lists
  gate true 1 none
  [ "$1" = - ] || printf '%s' "$1" > "$FIX/fx/issues"
  [ "$2" = - ] || printf '%s' "$2" > "$FIX/fx/prs"
  : > "$FIX/fx/calls"
  GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1)
}
L() { jq -cn --argjson n "$1" '{number: $n, labels: ($ARGS.positional | map({name: .}))}' --args "${@:2}"; }
dl "[$(L 13 bug stage:qa lane:fast)]" "[$(L 30 adlc:changes-requested stage:build)]"
check 0 "labels: one stage:/gate: label each (other labels do not count) passes" $?
eq yes "…and says so" "$(says_gate "no open issue or PR carries more than one stage:/gate: label")"
eq 2 "…from one issue list and one pr list call" "$(grep -cE '^(issue|pr) list ' "$FIX/fx/calls")"
eq 2 "…each asking for open ones only (a closed issue is out of the state machine)" "$(grep -cE '^(issue|pr) list --state open ' "$FIX/fx/calls")"
dl "[$(L 12 stage:qa gate:deploy),$(L 13 bug stage:qa lane:fast),$(L 129 stage:build gate:deploy stage:fast)]" "[$(L 30 stage:build stage:qa)]"
check 1 "labels: an open issue or PR with two stage:/gate: labels is flagged" $?
eq yes "…naming the issue with its state labels" "$(says_gate "issue #12: stage:qa gate:deploy")"
eq yes "…all three of a triple" "$(says_gate "issue #129: stage:build gate:deploy stage:fast")"
eq yes "…and the PR" "$(says_gate "pr #30: stage:build stage:qa")"
eq no  "…not the clean one" "$(says_gate "#13")"
eq yes "…with the fix: keep the latest, remove the rest, with the relabel script" "$(says_gate "keep the label it reached last and remove the rest — .adlc/scripts/adlc-relabel.sh <n> <that label>")"
dl - -;                      check 0 "labels: no open issue or PR (empty lists) passes" $?
dl "[$(L 12 stage:qa gate:deploy)]" -; touch "$FIX/fx/fail-issues"
GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1); check 1 "labels: a failed issue listing is flagged, not read as clean" $?
eq yes "…as incomplete" "$(says_gate "could not list open issues from gh")"
eq no  "…and claims no pass" "$(says_gate "no open issue or PR carries")"
dl "[$(L 12 stage:qa gate:deploy)]" -; touch "$FIX/fx/noauth"; : > "$FIX/fx/calls"
GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1); check 0 "labels: gh not authenticated — the check is skipped, not failed" $?
eq yes "…and says so" "$(says_gate "skipped label check (gh not available/authenticated)")"
eq 0 "…no listing is made" "$(grep -cE '^(issue|pr) list ' "$FIX/fx/calls")"
rm -f "$FIX/fx/noauth" "$FIX/fx/fail-issues" "$FIX/fx/issues" "$FIX/fx/prs"
# is Actions alive? (issue 34): an exhausted budget fails every run within seconds with no step run
R() { jq -cn --argjson id "$1" --arg c "$2" --argjson s "$3" '{databaseId: $id, status: "completed", conclusion: $c, createdAt: "2026-10-13T02:37:00Z", updatedAt: ("2026-10-13T02:37:00Z" | fromdate + $s | todate)}'; }
J() { jq -cn --arg c "$1" '{jobs: [{name: "test", conclusion: "failure", steps: (if $c == "" then [] else [{name: "Set up job", conclusion: $c}] end)}]}'; }
ac() { # <runs json | -> <jobs json | -> : a sound gate fixture, then the runs
  gate true 1 none
  [ "$1" = - ] || printf '%s' "$1" > "$FIX/fx/runs"
  [ "$2" = - ] || printf '%s' "$2" > "$FIX/fx/jobs"
  : > "$FIX/fx/calls"
  GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1)
}
ten() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do R "$((100 + i))" failure 3; done | jq -s .; }   # ten runs, each dead in 3 s
ac "$(ten)" "$(J "")";                    check 1 "actions: ten fast failures and no step run → flagged as blocked" $?
eq yes "…naming the cause and the tripwire" "$(says_gate "GitHub Actions looks blocked")"
eq yes "…and what it means for main" "$(says_gate "the tripwire included")"
eq yes "…with the run it read" "$(says_gate "(run 101)")"
eq yes "…and the local CI recipe to use meanwhile" "$(says_gate ".adlc/scripts/adlc-local-ci.sh <pr>")"
eq 1 "…from one run list of the last 10" "$(grep -c '^run list --limit 10 ' "$FIX/fx/calls")"
eq 1 "…and one run view, of the latest" "$(grep -c '^run view 101 ' "$FIX/fx/calls")"
ac "$(ten)" "$(J failure)";               check 0 "actions: ten fast failures whose steps ran are a failing workflow, not a block" $?
eq yes "…and says so" "$(says_gate "their steps ran")"
ac "$(ten)" "$(J skipped)";               check 1 "actions: a step that was skipped did not run" $?
ac "$({ R 1 failure 3; R 2 failure 3; } | jq -s .)" "$(J "")"; check 0 "actions: two fast failures are too few to call" $?
eq 0 "…no run view is made" "$(grep -c '^run view ' "$FIX/fx/calls")"
ac "$({ ten | jq '.[]'; R 200 failure 300; } | jq -s .)" "$(J "")"; check 0 "actions: one run that took five minutes breaks the pattern" $?
ac "$({ ten | jq '.[]'; R 200 success 3; } | jq -s .)" "$(J "")"; check 0 "actions: one green run breaks the pattern" $?
eq yes "…and says Actions runs" "$(says_gate "Actions runs workflows")"
# a lane whose job-level if: did not match concludes skipped before a runner is asked for; it says nothing either way
ac "$({ R 200 skipped 2; ten | jq '.[]'; R 201 cancelled 2; } | jq -s .)" "$(J "")"; check 1 "actions: skipped and cancelled runs among the fast failures do not hide the block" $?
eq yes "…counting only the runs that ran" "$(says_gate "the last 10 completed runs (skipped")"
eq 1 "…and reading the latest run that ran, not the skipped one" "$(grep -c '^run view 101 ' "$FIX/fx/calls")"
ac "$({ R 1 skipped 2; R 2 skipped 2; R 3 skipped 2; } | jq -s .)" "$(J "")"; check 0 "actions: only skipped runs say nothing (no completed run that ran)" $?
eq yes "…read as no completed run yet" "$(says_gate "no completed run yet")"
ac "$(ten)" '{"jobs":[{"name":"test","conclusion":"failure","steps":[{"name":"Set up job","conclusion":""}]}]}'; check 1 "actions: a step whose conclusion gh renders as the empty string did not run" $?
ac '[]' -;                                check 0 "actions: no completed run yet passes" $?
ac "$(ten)" -;                            check 1 "actions: fast failures whose latest run cannot be read are flagged as possibly blocked" $?
eq yes "…as unknown" "$(says_gate "may be blocked")"
ac - -; touch "$FIX/fx/fail-runs"
GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1); check 1 "actions: a failed run listing is flagged, not read as alive" $?
eq yes "…as unchecked" "$(says_gate "whether Actions is blocked is unchecked")"
rm -f "$FIX/fx/fail-runs" "$FIX/fx/runs" "$FIX/fx/jobs"
mv "$FIX/.github/workflows" "$FIX/wf.bak"; mkdir -p "$FIX/.github/workflows"
ac "$(ten)" "$(J "")";                    check 0 "actions: no adlc workflows (local-recipe mode) → nothing to check" $?
eq 0 "…and no run list is made" "$(grep -c '^run list ' "$FIX/fx/calls")"
rm -rf "$FIX/.github/workflows"; mv "$FIX/wf.bak" "$FIX/.github/workflows"; rm -f "$FIX/fx/runs" "$FIX/fx/jobs"
gate true 1 none; rm "$FIX/fx/default"
DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "gate: an unreadable default branch is flagged" $?
lane 'jobs:\n  t:\n    steps:\n      - run: echo hi\n'   # no lane runs an agent: nothing to gate
gate false - none;           check 0 "gate: not checked when no lane runs an agent" $?
eq 0 "…no lookup is made" "$(grep -c '^api ' "$FIX/fx/calls" 2>/dev/null || true)"
lane "${J}${WIRED}"; rm -rf "$FIX/fx"; mkdir -p "$FIX/fx"
DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1
eq "" "ADLC_DOCTOR_SKIP_LABELS=1 keeps the doctor off gh entirely" "$(cat "$FIX/fx/calls" 2>/dev/null)"
# Where the doctor is run from must not matter. Every gate case above already runs it from the
# test runner's cwd with the fixture as $1; these name the modes the header promises, and the CDPATH trap.
gate true 1 none   # seeds a sound fixture (fx/ was emptied just above)
ELSEWHERE="$(mktemp -d)"
( cd "$ELSEWHERE" && DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" ) >/dev/null 2>&1
check 0 "gh checks run against the host repo when the doctor is run from another cwd with the root as \$1" $?
( cd "$FIX" && DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" ) >/dev/null 2>&1
check 0 "…and from the repo root with the default root ." $?
# A relative root with CDPATH exported: `cd name` would search CDPATH before the cwd and land in
# the decoy, so the gh calls must drop CDPATH first.
mkdir -p "$ELSEWHERE/${FIX##*/}"
( cd "${FIX%/*}" && DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" CDPATH="$ELSEWHERE" bash "$S/adlc-doctor.sh" "${FIX##*/}" ) >/dev/null 2>&1
check 0 "…and with a relative root, an exported CDPATH does not redirect the gh calls to a same-named decoy" $?
rm -rf "$ELSEWHERE" "$FIX"

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
eq "" "the quoted format line is not a finding" "$(printf 'Use: ADLC-FINDING: <severity> | <class> | <file>\n' | bash "$S/adlc-log-findings.sh" 1 review)"
eq "" "a mid-sentence mention is not a finding"  "$(printf 'see ADLC-FINDING: High | x | y above\n' | bash "$S/adlc-log-findings.sh" 1 review 2>/dev/null)"
eq "" "two fields are not a finding"             "$(printf 'ADLC-FINDING: High | x\n' | bash "$S/adlc-log-findings.sh" 1 review)"
eq 2 "a numbered item and a heading are findings" "$(printf '1. ADLC-FINDING: High | a | x.py\n### ADLC-FINDING: Low | b | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review | grep -c '"class"')"
printf 'ADLC-FINDING: High | injection | src/db/*.py\n' | bash "$S/adlc-log-findings.sh" 1 review | jq -e '.file == "src/db/*.py"' >/dev/null 2>&1 && ok "a glob in the file field keeps its *" || bad "a glob in the file field keeps its *"
LB=$(printf -- '- **ADLC-FINDING:** High | `tenant-leak` | src/y.py\n' | bash "$S/adlc-log-findings.sh" 7 qa)
eq '{"ts":"'"$(printf '%s' "$LB" | jq -r .ts)"'","pr":7,"stage":"qa","severity":"High","class":"tenant-leak","file":"src/y.py"}' "a bullet with bold + backticks parses clean" "$LB"
printf 'ADLC-FINDING: Low | odd | src/a"b.py\n' | bash "$S/adlc-log-findings.sh" 1 review | jq -e '.file == "src/a\"b.py"' >/dev/null 2>&1 && ok "a quote in a field is valid JSON" || bad "a quote in a field breaks the JSON"
printf 'ADLC-FINDING: High | x | y\n' | bash "$S/adlc-log-findings.sh" abc review >/dev/null 2>&1; check 2 "a PR number that is not a number is an error" $?
# issue 27: a marker wrapped in code markup is a finding (one host lost 19 of a PR's 20 this way)
LC=$(printf -- '`ADLC-FINDING: Medium | tenant-leak | backend/app/tenancy.py`\n' | bash "$S/adlc-log-findings.sh" 9 review 2>/dev/null)
printf '%s' "$LC" | jq -e '.class == "tenant-leak" and .file == "backend/app/tenancy.py" and .severity == "Medium"' >/dev/null 2>&1 && ok "a code-wrapped marker is a finding, with the closing backtick off the file" || bad "a code-wrapped marker is a finding (got '$LC')"
eq 1 "a bullet with a code-wrapped marker is a finding" "$(printf -- '- `ADLC-FINDING: High | authz-gap | src/auth.py`\n' | bash "$S/adlc-log-findings.sh" 9 review 2>/dev/null | grep -c '"class":"authz-gap"')"
# the comment's own time, so the ledger can be windowed
eq '2026-10-08T14:03:00Z' "a third argument is the row's ts" "$(printf 'ADLC-FINDING: High | x | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review 2026-10-08T14:03:00Z | jq -r .ts)"
printf 'ADLC-FINDING: High | x | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review 2>/dev/null | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null 2>&1 && ok "no third argument: ts is now, ISO 8601" || bad "no third argument: ts is now, ISO 8601"
printf 'ADLC-FINDING: High | x | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review yesterday >/dev/null 2>&1; check 2 "a ts that is not ISO 8601 is an error, not a row" $?
printf 'ADLC-FINDING: High | x | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review 2026-10-08T14:03:00+02:00 >/dev/null 2>&1; check 2 "a ts with an offset instead of Z is an error (GitHub prints Z; the window compares text)" $?
case "$(printf 'ADLC-FINDING: High | x | y.py\n' | bash "$S/adlc-log-findings.sh" 31 review null 2>&1 >/dev/null)" in *"PR 31"*) ok "the ts error names the PR" ;; *) bad "the ts error must name the PR" ;; esac
eq 1 "…but an empty ts means now (a pending review has none), not an error" "$(printf 'ADLC-FINDING: High | x | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review "" 2>/dev/null | grep -c '"class"')"
printf -- '- `ADLC-FINDING: High | injection | src/db.py` fixed in abc123\n' | bash "$S/adlc-log-findings.sh" 1 review 2>/dev/null | jq -e '.file == "src/db.py"' >/dev/null 2>&1 && ok "prose after a code-wrapped marker's closing backtick is not part of the file" || bad "prose after a code-wrapped marker's closing backtick is not part of the file"
SK2=$(printf 'see ADLC-FINDING: High | injection | templates/<name>.html above\n' | bash "$S/adlc-log-findings.sh" 32 review 2>&1 >/dev/null)
case "$SK2" in *"PR 32"*skipped*) ok "a < in the file field does not hide a skipped line (only a <placeholder> severity is the format line)" ;; *) bad "a < in the file field must not hide a skipped line" ;; esac
# a finding-shaped line the script cannot read is reported, never silently dropped
SK=$(printf 'see ADLC-FINDING: High | x | y above\n' | bash "$S/adlc-log-findings.sh" 31 review 2>&1 >/dev/null)
case "$SK" in *"PR 31"*"skipped"*"see ADLC-FINDING: High | x | y above"*) ok "a mid-line marker with three fields is reported on stderr, with the PR and the line" ;; *) bad "a mid-line marker with three fields must be reported on stderr (got '$SK')" ;; esac
eq "" "the quoted format line is not reported"      "$(printf 'Use: ADLC-FINDING: <severity> | <class> | <file>\n' | bash "$S/adlc-log-findings.sh" 1 review 2>&1 >/dev/null)"
eq "" "a prose mention with no fields is not reported" "$(printf 'each ADLC-FINDING: line counts\n' | bash "$S/adlc-log-findings.sh" 1 review 2>&1 >/dev/null)"
eq "" "a plain finding writes nothing to stderr"      "$(printf 'ADLC-FINDING: High | injection | y.py\n' | bash "$S/adlc-log-findings.sh" 1 review 2>&1 >/dev/null)"
eq 1 "a last line with no newline is still a finding" "$(printf 'ADLC-FINDING: High | x | y.py' | bash "$S/adlc-log-findings.sh" 1 review 2>/dev/null | grep -c '"class"')"
# the retro's recipe must read both comment kinds, stamp each row with its comment's time, and not stop at 50 PRs
RR="$ROOT/skills/retro/SKILL.md"
grep -q -- '--json comments,reviews' "$RR" && grep -q 'ts: (.submittedAt // "")' "$RR" && grep -q 'ts: .createdAt' "$RR" && ok "retro recipe: reads comments and review bodies, with each one's time; a pending review's missing time falls back to now" || bad "retro recipe: must read comments and review bodies, with each one's time, and a null submittedAt must become empty"
grep -q -- 'adlc-log-findings.sh "$pr" review "$(jq -r .ts <<<"$c")"' "$RR" && ok "retro recipe: passes the comment's time to the logger" || bad "retro recipe: must pass the comment's time to the logger"
grep -q -- 'gh pr list --state all --limit 500' "$RR" && ok "retro recipe: lists 500 PRs, not 50" || bad "retro recipe: must list 500 PRs, not 50"
# issue 28: the class is a closed vocabulary — synonyms map onto it, a name outside it is logged as written and reported once
eq "logic-contradiction test-gap contract-violation doc-drift tenant-leak tenant-leak" "classes: known synonyms are written as their canonical name (idor is the tenant probe)" \
   "$(printf 'ADLC-FINDING: High | logic-bug | a.py\nADLC-FINDING: Low | test-coverage | b.py\nADLC-FINDING: Low | spec-drift | c.py\nADLC-FINDING: Low | docs | d.py\nADLC-FINDING: High | Tenant_Leak | e.py\nADLC-FINDING: Critical | idor | f.py\n' | bash "$S/adlc-log-findings.sh" 3 review 2>/dev/null | jq -r .class | tr '\n' ' ' | sed 's/ $//')"
eq "adr-drift drift" "classes: a name that could be contract-violation or doc-drift (adr-drift, drift) is not guessed: kept as written and reported" \
   "$(printf 'ADLC-FINDING: Low | adr-drift | a.md\nADLC-FINDING: Low | drift | b.md\n' | bash "$S/adlc-log-findings.sh" 3 review 2>/dev/null | jq -r .class | tr '\n' ' ' | sed 's/ $//')"
for c in test-gap doc-drift; do grep -q "^| $c |" "$ROOT/skills/retro/SKILL.md" && ok "retro Step 2 has a durable-fix row for $c" || bad "retro Step 2 needs a durable-fix row for $c"; done
eq "missing-edge-case" "classes: case, spaces and underscores do not make a new class" "$(printf 'ADLC-FINDING: Low | Missing Edge_Case | a.py\n' | bash "$S/adlc-log-findings.sh" 3 review 2>/dev/null | jq -r .class)"
UKD="$(mktemp -d)"; UK=$(printf 'ADLC-FINDING: Low | weird-thing | a.py\nADLC-FINDING: Low | Weird Thing | b.py\n' | bash "$S/adlc-log-findings.sh" 33 review 2>"$UKD/uk.err")
eq "weird-thing weird-thing" "classes: a name outside the list is logged as written (normalized), not dropped and not forced to other" "$(printf '%s\n' "$UK" | jq -r .class | tr '\n' ' ' | sed 's/ $//')"
eq 1 "classes: …and reported on stderr once per run, with the PR" "$(grep -c "PR 33: class 'weird-thing' is not in the list" "$UKD/uk.err")"; rm -rf "$UKD"
eq "" "classes: a canonical name writes nothing to stderr" "$(printf 'ADLC-FINDING: Low | doc-drift | a.py\n' | bash "$S/adlc-log-findings.sh" 3 review 2>&1 >/dev/null)"
eq 13 "classes: the subcommand prints the list, other last" "$(bash "$S/adlc-log-findings.sh" classes | wc -l | tr -d ' ')"
eq other "…other last" "$(bash "$S/adlc-log-findings.sh" classes | tail -1)"
# the list in the script and the table in the edd-spec skill are the same list (the reviewers read the skill, the ledger the script)
ES="$ROOT/skills/edd-spec/SKILL.md"
eq "$(bash "$S/adlc-log-findings.sh" classes | sort | tr '\n' ' ')" "classes: the edd-spec table names exactly the script's classes" \
   "$(sed -n '/^| Class | Meaning |/,/^$/p' "$ES" | sed -nE 's/^\| `([a-z-]+)` \|.*/\1/p' | sort | tr '\n' ' ')"
for c in $(bash "$S/adlc-log-findings.sh" classes); do
  eq "$c" "classes: '$c' is canonical (maps to itself)" "$(printf 'ADLC-FINDING: Low | %s | a.py\n' "$c" | bash "$S/adlc-log-findings.sh" 3 review 2>/dev/null | jq -r .class)"
done
for f in "$ROOT/skills/code-review/SKILL.md" "$ROOT/skills/role-adversarial-reviewer/SKILL.md"; do
  miss=""; for c in $(bash "$S/adlc-log-findings.sh" classes); do grep -q "\`$c\`" "$f" || miss="$miss $c"; done
  eq "" "classes: $(basename "$(dirname "$f")") names every class of the list" "$miss"
done

echo "relabel (one state per issue):"
RL="$(mktemp -d)"; mkdir -p "$RL/bin"
cat > "$RL/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: `issue view N --json labels --jq …` answers from $RL_LABELS (one name per line); every call is logged
echo "$*" >> "$RL_CALLS"
case "$1 $2" in
  "issue view") [ -z "${RL_FAIL_VIEW:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                jq -R . "$RL_LABELS" | jq -s '{labels: map({name: .})}' | jq -r "${@: -1}" ;;
  "issue edit") [ -z "${RL_FAIL_EDIT:-}" ] || { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; } ;;
  *) exit 2 ;;
esac
SH
chmod +x "$RL/bin/gh"
relabel() { # <labels, space-separated> <issue> <new label> [ENV=val …]
  local labels="$1"; shift
  printf '%s\n' $labels > "$RL/labels"; : > "$RL/calls"
  RL_OUT=$(env PATH="$RL/bin:$PATH" RL_LABELS="$RL/labels" RL_CALLS="$RL/calls" "${@:3}" bash "$S/adlc-relabel.sh" "$1" "$2" 2>"$RL/err"); RL_RC=$?
}
rcalls() { tr '\n' '|' < "$RL/calls"; }
relabel "bug stage:qa lane:fast" 12 gate:deploy; check 0 "stage:qa → gate:deploy exits 0" $RL_RC
eq "issue view 12 --json labels --jq .labels[].name|issue edit 12 --remove-label stage:qa --add-label gate:deploy|" "…one read, then ONE edit that removes the old state and adds the new; other labels untouched" "$(rcalls)"
eq "#12: stage:qa → gate:deploy" "…and says what moved" "$RL_OUT"
relabel "stage:build gate:deploy stage:fast" 129 stage:qa; check 0 "a triple-labelled issue exits 0" $RL_RC
eq "issue view 129 --json labels --jq .labels[].name|issue edit 129 --remove-label stage:build --remove-label gate:deploy --remove-label stage:fast --add-label stage:qa|" "…every other state label comes off in the same call" "$(rcalls)"
relabel "adlc:auto gate:deploy" 5 gate:deploy; check 0 "already there, alone: exits 0" $RL_RC
eq "issue view 5 --json labels --jq .labels[].name|" "…and makes no edit" "$(rcalls)"
eq "#5 is at gate:deploy already" "…saying so" "$RL_OUT"
relabel "stage:qa gate:deploy" 7 gate:deploy; check 0 "already there, with a leftover: exits 0" $RL_RC
eq "issue view 7 --json labels --jq .labels[].name|issue edit 7 --remove-label stage:qa|" "…and only removes the leftover" "$(rcalls)"
relabel "bug" 8 stage:intake; check 0 "no state label yet: exits 0" $RL_RC
eq "issue view 8 --json labels --jq .labels[].name|issue edit 8 --add-label stage:intake|" "…and only adds" "$(rcalls)"
relabel "stage:qa" x gate:deploy;        check 2 "an issue that is not a number is an error (nothing read, nothing written)" $RL_RC
eq "" "…no gh call" "$(rcalls)"
relabel "stage:qa" 12 bug;               check 2 "a label outside stage:/gate: is an error" $RL_RC
relabel "stage:qa" 12 "stage:";          check 2 "a bare prefix is an error" $RL_RC
relabel "stage:qa" 12 gate:deploy RL_FAIL_VIEW=1; check 1 "a failed read exits 1" $RL_RC
eq "issue view 12 --json labels --jq .labels[].name|" "…and writes nothing" "$(rcalls)"
relabel "stage:qa" 12 gate:deploy RL_FAIL_EDIT=1; check 1 "a failed edit exits 1" $RL_RC
grep -q 'gh issue edit failed for #12' "$RL/err" && ok "…and says so" || bad "…must say the edit failed"
rm -rf "$RL"

echo "cost/latency:"
CO=$(printf 'adlc-builder 120 5000 0.10\nadlc-qa 80 3000 0.06\nadlc-builder 60 2000 0.04\n' | bash "$S/adlc-cost.sh")
printf '%s\n' "$CO" | grep -qE 'adlc-builder +2 +180 +90\.0 +7000' && ok "per-lane rollup (runs/total/avg/tokens)" || bad "per-lane rollup"
printf '%s\n' "$CO" | grep -qE 'TOTAL +3 +260' && ok "pipeline total latency" || bad "pipeline total latency"
LO=$(printf 'adlc-review 30\nadlc-review 10\n' | bash "$S/adlc-cost.sh")
printf '%s\n' "$LO" | grep -qE 'adlc-review +2 +40 +20\.0' && ok "latency-only (no tokens)" || bad "latency-only"
CE=$(printf 'adlc-review 30\n\nadlc-review 10\n' | bash "$S/adlc-cost.sh")
printf '%s\n' "$CE" | grep -qE 'TOTAL +2 +40' && ok "a blank input line is not a run" || bad "a blank input line is not a run"

echo "lane triggers (static):"
# `labeled` fires on EVERY label change — including the label moves the lanes themselves make with
# the dispatch token. Every job of a workflow that reacts to label changes must name, in its own
# `if:`, the label that fired the event, or it re-runs on unrelated transitions (adlc-intake once
# re-ran the Analyst at every stage and could drag an in-flight issue back to gate:stories).
# No pipes into `grep -q` here: under this file's pipefail an early-exiting reader can turn a
# match into a failure.
for W in "$ROOT"/templates/github/adlc-*.yml; do
  # adlc-diff-scope.yml is a check, not a lane: re-running it on any label costs seconds, and a
  # job condition there would turn its last failed verdict into a pass (a skipped job passes).
  [ "$(basename "$W")" = adlc-diff-scope.yml ] && continue
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
mkdir -p "$IT/repo/.adlc/scripts"; cp "$S/adlc-relabel.sh" "$IT/repo/.adlc/scripts/"   # the Gate 1 handoff relabels through the script (issue 38)
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
  ( cd "$IT/repo" && env PATH="$IT:$PATH" ST="$ST" N=7 GITHUB_OUTPUT="$ST/out" "$@" bash -e "$IT/$script" ) >/dev/null 2>&1
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
eq "edit 7 --remove-label gate:stories --add-label stage:design|" "gate: autopilot + FULL → stage:design, in one edit through the relabel script" "$(calls)"
intake gate.sh "adlc:auto adlc:autopilot gate:stories stage:fast" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=true
eq "edit 7 --remove-label gate:stories --remove-label stage:fast --add-label stage:design|" "gate: …which also takes a leftover second state label off" "$(cut -d' ' -f1-8 "$ST/calls" | tr '\n' '|')"
intake gate.sh "adlc:auto adlc:autopilot gate:stories" "ADLC-TRIAGE: FAST | copy fix" AUTOPILOT=true
eq "comment 7 --body 🚦 Triaged **FAST**|" "gate: autopilot + FAST → lane-approval note, never stage:fast" "$(calls)"
intake gate.sh "adlc:auto adlc:autopilot gate:stories" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=false
eq "" "gate: adlc:autopilot added mid-run is not honoured" "$(calls)"
intake gate.sh "adlc:auto gate:stories" "ADLC-TRIAGE: FULL | needs design" AUTOPILOT=true
eq "" "gate: adlc:autopilot taken off mid-run opts out" "$(calls)"
intake gate.sh "adlc:auto stage:design" "ADLC-TRIAGE: FULL | x" AUTOPILOT=true
eq "" "gate: neither stage:intake nor gate:stories → labels left alone" "$(calls)"
rm -rf "$IT"

echo "isolation (launched by git itself, the suite still works only in its scratch repos):"
# The `unset` at the top of this file is what keeps every scratch-repo test below off the
# caller's repository. Take that line as the file has it, and run it in a child that inherits
# another repository's GIT_DIR, as a hook or `git rebase -x` would hand it over.
if command -v git >/dev/null 2>&1; then
  IS="$(mktemp -d)"; git init -q "$IS/real" >/dev/null 2>&1; git init -q "$IS/scratch" >/dev/null 2>&1
  reset=$(grep -E '^unset \$\(git rev-parse --local-env-vars' "$0" || true)
  eq "$(cd "$IS/scratch/.git" 2>/dev/null && pwd -P)" "an inherited GIT_DIR does not steer \`git -C <scratch repo>\` to the real one" \
     "$(GIT_DIR="$IS/real/.git" bash -c "$reset"$'\n''git -C "$1" rev-parse --absolute-git-dir' _ "$IS/scratch" 2>/dev/null)"
  rm -rf "$IS"
else
  bad "isolation test needs git"
fi

echo "fast-lane cap step (the workflow's own run: script, on a real git history):"
# The cap is what makes skipping design safe, so its step must never report a small change for
# a diff it did not read. It once piped `git diff` into the script in a shell with no pipefail:
# when git failed (a base ref the checkout does not have) the script was given nothing, said
# FAST, and a change under auth/ went on to review as eligible. Run the step as shipped: a
# scratch repository holding the PRs, and a checkout shaped like the runner's. Nothing here has
# a remote, and nothing is pushed.
if command -v git >/dev/null 2>&1; then
  FL="$(mktemp -d)"; FLW="$ROOT/templates/github/adlc-fast.yml"
  # The step keeps the script's verdict and reasons, and its own stop reason, in /tmp/cap.*,
  # where the later steps read them. Here those files go to the scratch dir — the one edit made
  # to the scripts — so a run writes nothing outside it and two runs at once cannot cross.
  step_run "$FLW" '- name: Fast-lane cap' | sed "s|/tmp/cap\.|$FL/cap.|g" > "$FL/cap.sh"
  step_run "$FLW" '- name: Say that the cap could not run' | sed "s|/tmp/cap\.|$FL/cap.|g" > "$FL/tell.sh"
  mkdir -p "$FL/bin"
  cat > "$FL/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: the one call the step after a failed cap makes, logged to $GH_LOG
[ "$1 $2" = "pr comment" ] || exit 2
shift; printf '%s\n' "$*" >> "$GH_LOG"
SH
  chmod +x "$FL/bin/gh"
  lgit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
  # flpr <n> <base branch> <commands that make the change> — PR <n>: branch feat/<n> cut from
  # the base, the change committed, and refs/pull/<n>/merge as GitHub keeps it (the base's tip
  # merged with the PR's head) — the commit a pull_request run checks out.
  flpr() {
    lgit -C "$FL/seed" checkout -q -b "feat/$1" "$2"
    ( cd "$FL/seed" && eval "$3" && lgit add -A && lgit commit -q --allow-empty -m "feat: change $1" )
    lgit -C "$FL/seed" checkout -q --detach "$2"
    lgit -C "$FL/seed" merge -q --no-ff -m "Merge feat/$1 into $2" "feat/$1"
    lgit -C "$FL/seed" update-ref "refs/pull/$1/merge" HEAD
  }
  odd='rel/$(touch${IFS}INJECTED)'   # a legal branch name
  {
    lgit init -q "$FL/seed"; lgit -C "$FL/seed" symbolic-ref HEAD refs/heads/main
    mkdir -p "$FL/seed/.adlc/scripts" "$FL/seed/src"; cp "$S/adlc-triage.sh" "$FL/seed/.adlc/scripts/"; echo 'x = 1' > "$FL/seed/src/a.py"
    lgit -C "$FL/seed" add -A; lgit -C "$FL/seed" commit -q -m init
    lgit -C "$FL/seed" branch "$odd" main
    flpr 1 main 'echo "y = 2" >> src/a.py; mkdir -p tests .adlc/scope; echo "def test_y(): assert True" > tests/test_a.py; printf "src/\ntests/\n" > .adlc/scope/1.txt'
    flpr 2 main 'i=0; while [ $i -lt 41 ]; do echo "v$i = $i"; i=$((i+1)); done > src/big.py'
    flpr 3 main 'mkdir -p auth; echo "k = 1" > auth/login.py'
    flpr 4 main 'mkdir -p auth; echo "k = 1" > auth/login.py; lgit add -A; lgit commit -q -m "feat: first"; echo "y = 2" >> src/a.py'
    flpr 5 main ':'                                 # a PR that changes nothing
    flpr 6 "$odd" 'echo "y = 2" >> src/a.py'
    flpr 8 main 'mkdir -p auth; echo "k = 1" > auth/café.py'
    # a new submodule under vendor/ — no denylisted path, so only the entry's mode can refuse it —
    # and a .gitmodules that tells git never to show it as changed (the empty directory is what
    # keeps the gitlink through `git add -A`)
    flpr 7 main 'mkdir -p vendor/net; lgit update-index --add --cacheinfo "160000,$(lgit rev-parse HEAD),vendor/net"; printf "[submodule \"net\"]\n\tpath = vendor/net\n\turl = ./net\n\tignore = all\n" > .gitmodules'
    lgit -C "$FL/seed" checkout -q main             # …and main moves on after the PRs were cut
    for f in m1 m2 m3 m4 m5 m6; do echo x > "$FL/seed/src/$f.py"; done
    lgit -C "$FL/seed" add -A; lgit -C "$FL/seed" commit -q -m 'main moves on'
  } >/dev/null 2>&1
  # flrun <PR number> <base ref> — the step, run as Actions does (bash -e), in a checkout as
  # actions/checkout leaves it on a pull_request event with fetch-depth: 0: every branch a
  # remote-tracking ref, every tag, and a detached HEAD on the PR's merge commit. There is no
  # local branch at all. The cap's thresholds are the script's defaults: an ADLC_FAST_* variable
  # in the developer's shell must not change a verdict here.
  flrun() {
    rm -rf "$FL/run" "$FL/cap.out" "$FL/cap.err"; : > "$FL/out"; : > "$FL/said"
    printf 'a reason left by an earlier job\n' > "$FL/cap.fail"   # must never be posted as this PR's
    { lgit init -q "$FL/run" \
        && lgit -C "$FL/run" fetch -q "$FL/seed" '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' "+refs/pull/$1/merge:refs/remotes/pull/$1/merge" \
        && lgit -C "$FL/run" checkout -q --detach "refs/remotes/pull/$1/merge"; } >/dev/null 2>&1 || return 99
    ( cd "$FL/run" && env -u ADLC_FAST_MAX_FILES -u ADLC_FAST_MAX_LINES -u ADLC_FAST_DENY BASE_REF="$2" GITHUB_OUTPUT="$FL/out" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -e "$FL/cap.sh" ) > "$FL/said" 2>/dev/null
  }
  fltell() { # the step after a failed cap, run as Actions does (bash -e), against the stub gh
    : > "$FL/gh.log"
    ( cd "$FL/run" && env PATH="$FL/bin:$PATH" GH_LOG="$FL/gh.log" PR=7 GITHUB_SERVER_URL=https://example.test GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 bash -e "$FL/tell.sh" ) >/dev/null 2>&1
  }
  flout()  { tr '\n' ' ' < "$FL/out"; }                 # the output the cap step set
  flwhy()  { cat "$FL/cap.err" 2>/dev/null || true; }   # the reasons it kept for the bounce step
  flsaid() { tr '\n' ' ' < "$FL/gh.log"; }              # what the step after a failed cap posted
  [ -s "$FL/cap.sh" ] && ok "run: script extracted from the template" || bad "could not extract the run: script"
  [ -s "$FL/tell.sh" ] && ok "…and the step that tells the PR about a failed cap" || bad "could not extract the step that tells the PR about a failed cap"
  # its if: must name a status function (with none, `success()` is implied and it never runs) and
  # the cap step's own outcome (an earlier step's failure must not fire it)
  eq 1 "…whose if: is a status function plus the cap step's own outcome" \
     "$(awk '/^      - / { s = ($0 ~ /- name: Say that the cap could not run/) } s' "$FLW" | grep -cE "^ +if: (failure|always)\(\) && steps\.cap\.outcome == 'failure'[[:space:]]*$" || true)"
  # the first case means little unless main really has moved past the PRs' merge base
  eq 6 "fixture: after the PRs were cut, main moved on by 6 files (more than the file cap)" \
     "$(lgit -C "$FL/seed" diff --name-only 'refs/pull/1/merge^1' refs/heads/main 2>/dev/null | grep -c . || true)"
  flrun 1 main; eq "eligible=true "  "a small change is eligible — measured from the merge base, not from main's tip" "$(flout)"
  [ ! -e "$FL/cap.fail" ] && ok "…and a stop reason an earlier job left is cleared first (a self-hosted runner keeps /tmp)" || bad "a stop reason an earlier job left must be cleared: the comment step would post it"
  flrun 2 main; eq "eligible=false " "over the line cap → not eligible (the diff reaches the script with its line counts)" "$(flout)"
  case "$(flwhy)" in *"too many lines: 41 > 40"*) ok "…and the reason is kept for the bounce step" ;; *) bad "the reason is kept for the bounce step (got '$(flwhy)')" ;; esac
  flrun 3 main; eq "eligible=false " "a sensitive path → not eligible" "$(flout)"
  # git quotes a path with a non-ASCII byte ("auth/caf\303\251.py") unless told not to, and the
  # quotes would hide it from the denylist's anchors
  flrun 8 main; eq "eligible=false " "a sensitive path with a non-ASCII name → not eligible (the diff is taken unquoted)" "$(flout)"
  # A submodule change is part of the diff even when the PR's own .gitmodules says `ignore = all`,
  # which makes a plain `git diff` leave it out. PR 7 adds one under vendor/: numstat alone would
  # show a one-line file at an innocent path. Its .gitmodules is a denied manifest, so the verdict
  # alone would not prove the mode rule; the reason the cap gives does.
  flrun 7 main; eq "eligible=false " "a submodule change the PR tells git to ignore still reaches the cap, and its mode refuses it" "$(flout)"
  case "$(flwhy)" in *"submodule change: vendor/net"*) ok "…for that reason" ;; *) bad "the cap must name the submodule (got '$(flwhy)')" ;; esac
  # A tag named like the base branch must not stand in for it. PR 4's first commit adds
  # auth/login.py and its second an innocent line: measured from a tag `origin/main` put on
  # the first commit, only the second would be seen.
  lgit -C "$FL/seed" tag origin/main 'refs/heads/feat/4~1' >/dev/null 2>&1
  flrun 4 main
  [ "$(lgit -C "$FL/run" rev-parse origin/main 2>/dev/null)" != "$(lgit -C "$FL/run" rev-parse refs/remotes/origin/main 2>/dev/null)" ] \
    && ok "fixture: in that checkout the short name origin/main is the tag, not the branch" || bad "fixture: the tag origin/main does not shadow the branch"
  eq "eligible=false " "a tag named origin/main does not shorten the diff (the base is read by its full ref name)" "$(flout)"
  lgit -C "$FL/seed" tag -d origin/main >/dev/null 2>&1
  # A branch name may hold shell syntax, and a PR's base is whichever branch its author targets.
  flrun 6 "$odd"; eq "eligible=true " "a base branch named $odd is read as a name" "$(flout)"
  [ ! -e "$FL/run/INJECTED" ] && ok "…and nothing in it runs" || bad "the base branch's name ran as a command"
  # the base branch reaches the script through env:, never written into it by ${{ }}
  case "$(cat "$FL/cap.sh")" in *'${{'*) bad "the script has no \${{ }} expression written into it" ;; *) ok "the script has no \${{ }} expression written into it" ;; esac
  eq 1 "the step's env: hands it the PR's base branch as BASE_REF" \
     "$(awk '/^      - / { s = ($0 ~ /- name: Fast-lane cap/) } s' "$FLW" | tr -d "\"'" | grep -cE '^ +BASE_REF: \$\{\{ github\.(event\.pull_request\.base\.ref|base_ref) \}\}[[:space:]]*$' || true)"
  # A diff that cannot be taken must stop the step: given nothing, the script said FAST. PR 3 is
  # the sensitive one, so an output here is the old bug.
  flrun 3 gone; rc=$?   # (99 = the fixture checkout itself failed)
  case "$rc" in 0|99) bad "a base branch the checkout does not have fails the step (exit $rc)" ;; *) ok "a base branch the checkout does not have fails the step" ;; esac
  eq "" "…and sets no output (was: eligible=true)" "$(flout)"
  fltell; case "$(flsaid)" in "comment 7 --body ⚠️ The fast-lane cap could not measure this PR: could not find where this PR branches from gone."*"https://example.test/o/r/actions/runs/42 ") ok "…and the next step tells the PR why, with a link to the run" ;; *) bad "…and the next step tells the PR why, with a link to the run (got '$(flsaid)')" ;; esac
  # Nor is an empty diff a small change: the PR changes nothing (PR 5, here), or the step is not
  # looking at the PR at all. Either way there is nothing for the cap to vouch for.
  flrun 5 main; rc=$?
  case "$rc" in 0|99) bad "an empty diff fails the step (exit $rc)" ;; *) ok "an empty diff fails the step: nothing measured is not FAST" ;; esac
  eq "" "…and sets no output" "$(flout)"
  case "$(cat "$FL/said")" in '::error::Fast-lane cap:'*) ok "…and says so" ;; *) bad "an empty diff is reported as that" ;; esac
  fltell; case "$(flsaid)" in *"could not measure this PR: the diff against main is empty"*) ok "…on the PR too" ;; *) bad "…on the PR too (got '$(flsaid)')" ;; esac
  eq 1 "adlc-fast.yml: the review job checks out the full history (the cap needs the base branch)" \
     "$(awk '/^  review_gate:/ { j=1 } j' "$FLW" | grep -cE '^ +fetch-depth: 0([[:space:]]|$)' || true)"
  rm -rf "$FL"
else
  bad "fast-lane cap step tests need git"
fi

echo "diff-scope step (the workflow's own run: script against a stub gh):"
# This step decides which issue and stage a PR is checked under — the part that once resolved
# every lane PR to "no stage" and skipped. Run it as shipped, in what the job really works in: a
# checkout of the BASE branch, with the PR reachable only as data (the API and refs/pull/N/head).
WF="$ROOT/templates/github/adlc-diff-scope.yml"
grep -q '^  pull_request_target:' "$WF" && ok "runs on pull_request_target (workflow and scripts from the base branch)" || bad "adlc-diff-scope.yml must run on pull_request_target"
grep -qE '^[[:space:]]+ref:' "$WF" && bad "adlc-diff-scope.yml must never check out the PR head" || ok "…and never checks out the PR head"
# every event that can change the verdict: a push, the Builder's lane:fast label, a body edit or retarget
grep -q '^    timeout-minutes:' "$WF" && ok "…with a time limit (the scope file and the diff are the PR's to size)" || bad "adlc-diff-scope.yml: the job needs timeout-minutes"
grep -q 'types: \[opened, synchronize, reopened, labeled, unlabeled, edited\]' "$WF" && ok "…on every event that can change the verdict" || bad "adlc-diff-scope.yml: types must be opened, synchronize, reopened, labeled, unlabeled, edited"
grep -qE '^    if:' "$WF" && bad "adlc-diff-scope.yml: the job must have no if: — a skipped job would replace a failed verdict with a pass" || ok "…with no job condition (a skipped job would replace a failed verdict with a pass)"
grep -q '/contents/' "$WF" && bad "adlc-diff-scope.yml: the scope file must not be read through the contents API (it follows a link)" || ok "…and reads the scope file as a git blob, not through the contents API (which follows a link)"
# For the Builder's PRs the step copies the lanes' link rule. If a lane changes how it links a PR, the copy must change too.
# Pinned as the pair of lines, in order: the same two expressions the other way round would link a different issue.
lanes_pair=$(cat <<'EOF'
issue=$(gh pr view "$PR" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty')
[ -z "$issue" ] && issue=$(gh pr view "$PR" --json body --jq '.body' | grep -oiE '#[0-9]+' | head -1 | tr -d '#')
EOF
)
lanes_rule=same
for wf in adlc-review.yml:2 adlc-fast.yml:1; do   # <workflow>:<how many times it links a PR>
  got=$(grep -A1 'closingIssuesReferences' "$ROOT/templates/github/${wf%:*}" | grep -v '^--$' | sed -e 's/^[[:space:]]*//' -e 's/ || true)$/)/')
  want=$(i=0; while [ "$i" -lt "${wf#*:}" ]; do printf '%s\n' "$lanes_pair"; i=$((i+1)); done)
  [ "$got" = "$want" ] || lanes_rule=changed
done
[ "$(grep -l 'closingIssuesReferences' "$ROOT"/templates/github/*.yml | wc -l | tr -d ' ')" = 3 ] || lanes_rule=changed
[ "$lanes_rule" = same ] && ok "the lanes still link a PR by the rule this step copies (first closing reference, else first #N in the body)" || bad "a lane's link rule changed — adlc-diff-scope.yml copies it for the Builder's PRs and must change with it"
DS="$(mktemp -d)"; mkdir -p "$DS/bin"
dg() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
git init -q --bare -b main "$DS/remote.git" >/dev/null 2>&1; git init -q -b main "$DS/repo" >/dev/null 2>&1
mkdir -p "$DS/repo/.adlc/scripts" "$DS/repo/src"; cp "$S"/*.sh "$DS/repo/.adlc/scripts/"; echo 'x = 1' > "$DS/repo/src/a.py"
( cd "$DS/repo" && dg add -A && dg commit -q -m base && dg remote add origin "$DS/remote.git" && dg push -q origin main && dg fetch -q origin ) >/dev/null 2>&1
step_run "$WF" '- name: Enforce declared diff scope' > "$DS/step.sh"
cat > "$DS/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: each call answers from a file in $FX. No file → 404; a `fail-<name>` file → 502.
case "$*" in
  "pr view"*"closingIssuesReferences,body"*)   # the lanes' rule: `#<first closing reference of ANY repo>`, then the body
    [ -e "$FX/fail-body" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
    any="$FX/closing"; [ -e "$FX/closing-any" ] && any="$FX/closing-any"
    [ -s "$any" ] && sed 's/^/#/' "$any"
    cat "$FX/body" 2>/dev/null; exit 0 ;;
  "pr view"*closingIssuesReferences*) k=closing ;;
  "pr view"*labels*)                  k=pr-labels ;;
  "pr view"*changedFiles*)            k=nfiles ;;
  "api "*"/pulls/"*"/files"*)         k=files ;;
  "api "*"/issues/"*)                 k="issue-$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p')" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 2 ;;
esac
[ -e "$FX/fail-$k" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
[ -e "$FX/$k" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$FX/$k"
SH
chmod +x "$DS/bin/gh"
# dsfx <PR labels> <closing reference> <issue> <its labels | - (no such issue)> <the PR's scope file | -> <changed files>
#   The scope file goes into the PR head itself (refs/pull/7/head), on top of what prhead built there (else
#   the base): its text, `-` for none, `@exec:<text>` for an executable file, `@link:<target>` for a link,
#   `@dir` for a directory at that path; `@parentlink:<text>` makes .adlc/scope a link to a directory holding it.
#   alsoscope <issue> <text> adds another issue's scope file to the same head (a decoy for the issue-picking tests).
dsfx() {
  rm -rf "$DS/fx" "$DS/repo/.adlc/scope"; mkdir -p "$DS/fx"
  printf '%b' "$1" > "$DS/fx/pr-labels"; printf '%b' "$2" > "$DS/fx/closing"; printf '%b' "$6" > "$DS/fx/files"; echo 3 > "$DS/fx/nfiles"
  [ "$4" = - ] || printf '%b' "$4" > "$DS/fx/issue-$3"
  [ -d "$DS/pr" ] || git clone -q "$DS/remote.git" "$DS/pr" >/dev/null 2>&1
  ( cd "$DS/pr" && rm -rf .adlc/scope && mkdir -p .adlc/scope && case "$5" in
      -)        rmdir .adlc/scope ;;
      @exec:*)  printf '%b' "${5#@exec:}" > ".adlc/scope/$3.txt"; chmod +x ".adlc/scope/$3.txt" ;;
      @link:*)  ln -s "${5#@link:}" ".adlc/scope/$3.txt" ;;
      @dir)     mkdir ".adlc/scope/$3.txt"; : > ".adlc/scope/$3.txt/x" ;;
      @parentlink:*) rmdir .adlc/scope; rm -rf elsewhere; mkdir elsewhere; printf '%b' "${5#@parentlink:}" > "elsewhere/$3.txt"; ln -s ../elsewhere .adlc/scope ;;
      *)        printf '%b' "$5" > ".adlc/scope/$3.txt" ;;
    esac && dg add -A && { dg commit -q -m scope || true; } && dg push -q -f origin HEAD:refs/pull/7/head ) >/dev/null 2>&1
}
alsoscope() { ( cd "$DS/pr" && mkdir -p .adlc/scope && printf '%b' "$2" > ".adlc/scope/$1.txt" && dg add -A && dg commit -q -m scope2 && dg push -q -f origin HEAD:refs/pull/7/head ) >/dev/null 2>&1; }
nohead()    { git -C "$DS/remote.git" update-ref -d refs/pull/7/head; }
dsrun() { # [head branch] [PR author] [base branch] — runs the step as Actions does (bash -e), in the default-branch checkout
  ( cd "$DS/repo" && env PATH="$DS/bin:$PATH" FX="$DS/fx" PR=7 HEAD_REF="${1:-claude/work}" BASE_REF="${3:-main}" AUTHOR="${2:-someone}" BUILDER_BOT=adlc-bot ADLC_TEST_DIRS=tests bash ${DSOPTS:--e} "$DS/step.sh" ) >/dev/null 2>&1
}
dsout() { ( cd "$DS/repo" && env PATH="$DS/bin:$PATH" FX="$DS/fx" PR=7 HEAD_REF=w BASE_REF=main AUTHOR=someone BUILDER_BOT=adlc-bot bash -e "$DS/step.sh" ) 2>&1; }
[ -s "$DS/step.sh" ] && ok "run: script extracted from the template" || bad "could not extract the run: script"
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'
dsrun; check 0 "full lane: a PR inside its declared scope passes" $?
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\nsrc/billing/y.py\n.adlc/scope/12.txt\n'
dsrun; check 1 "full lane: a file outside the scope fails (was: 'no stage — skipped')" $?
dsfx '' '12\n' 12 'stage:build\n' - 'src/api/x.py\n'
dsrun; check 1 "full lane: a PR that declares no scope fails" $?
dsfx '' '12\n' 12 'stage:build\n' - 'src/api/x.py\n'; mkdir -p "$DS/repo/.adlc/scope"; printf 'src/\n' > "$DS/repo/.adlc/scope/12.txt"
dsrun; check 1 "…even when the default branch has a scope file for that issue: the PR's branch must contain it" $?
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n.adlc/scripts/adlc-diff-scope.sh\n.github/workflows/adlc-diff-scope.yml\n'
dsrun; check 1 "a PR that edits the guards is judged by the default branch's copy, and the edit is out of scope" $?
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n.adlc/scope/\n' 'src/api/x.py\n.adlc/scope/12.txt\n.adlc/scope/40.txt\n'
dsrun; check 1 "a lane PR cannot add a scope file for another issue" $?
dsfx '' '12\n' 12 'stage:qa\ngate:deploy\n' 'src/api/\n' 'src/api/x.py\ntests/t.py\n.adlc/scope/12.txt\n'
dsrun; check 0 "issue at stage:qa: QA's tests on the Builder's PR pass" $?
dsfx 'adlc:changes-requested\n' '12\n' 12 'stage:qa\n' 'src/api/\n' 'tests/t.py\nsrc/billing/y.py\n'
dsrun; check 1 "issue at stage:qa: outside scope and tests fails" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n.adlc/scope/12.txt\n'
dsrun feat/12-add-login; check 1 "no closing reference: the branch names the issue" $?
dsfx '' '' 12 'stage:build\n' - 'src/api/x.py\n'
dsrun feat/12-add-login; check 1 "…and a lane branch that declares no scope fails" $?
dsfx '' '' 12 'stage:qa\ngate:deploy\n' 'src/api/\n' 'src/a.py\ndocs/x.md\n.adlc/scope/12.txt\n.adlc/scope/13.txt\n'
dsrun release/next; check 0 "a PR that merely carries scope files (a promotion, a cleanup) is tied to no issue" $?
dsfx '' '' 2026 - - 'CHANGELOG.md\n'
dsrun release/2026-10; check 0 "a branch number that is no issue here ties the PR to none" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n'; printf 'Implements #12, see also #3\n' > "$DS/fx/body"
dsrun claude/work adlc-bot; check 1 "the Builder's own PR is tied by the first #N in its body, as the lanes tie it" $?
dsrun claude/work dependabot; check 0 "anyone else's PR is not tied by a bare #N" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n'; printf 'Implements #12\n' > "$DS/fx/body"
dsrun x/999-decoy adlc-bot; check 1 "a branch that names a number that is no issue does not hide the body's issue" $?
printf 'bug\n' > "$DS/fx/issue-999"
dsrun x/999-decoy adlc-bot; check 1 "…nor does a branch that names an issue in no lane" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n'; printf 'Implements #12\n' > "$DS/fx/body"
printf 'stage:build\n' > "$DS/fx/issue-13"; alsoscope 13 'src/billing/\n'   # the decoy's scope would allow the file
dsrun feat/13-other adlc-bot; check 1 "the body's issue outranks the branch's, as in the lanes (the PR is held to #12's scope, not #13's)" $?
dsfx '' '5\n' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n'; printf 'bug\n' > "$DS/fx/issue-5"
dsrun feat/12-add-login; check 1 "a closing reference to an issue in no lane does not hide the branch's lane issue" $?
dsfx '' '5\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n'; : > "$DS/fx/issue-5"   # a closed issue: the lookup gives no labels
dsrun feat/12-add-login; check 0 "…and the lane issue, not the one named first, names the scope file" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n'; printf '&#12; tidy up\n' > "$DS/fx/body"
dsrun claude/work adlc-bot; check 1 "the lanes read an HTML entity as an issue number, so for the Builder's PR this check does too" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/billing/y.py\n'; printf 'See #5\n' > "$DS/fx/body"; printf 'bug\n' > "$DS/fx/issue-5"; printf '12\n' > "$DS/fx/closing-any"
dsrun claude/work adlc-bot; check 1 "…and a closing reference to another repo's #12, which the lanes read as this repo's" $?
dsrun claude/work someone; check 0 "…but only for the Builder: anyone else's cross-repo reference ties the PR to nothing here" $?
dsfx '' '20\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\ntests/t.py\n'; printf 'Closes o/other#12, closes #20\n' > "$DS/fx/body"; printf '12\n' > "$DS/fx/closing-any"
printf 'stage:qa\n' > "$DS/fx/issue-20"; alsoscope 20 'src/api/\n'          # under #20 (qa) the test file would pass
dsrun claude/work adlc-bot; check 1 "two lane issues named: the Builder's PR is judged under the one the lanes advance (#12 at build, not #20 at qa)" $?
dsfx '' '' 0 - - 'README.md\n'; printf 'A tidy-up, tied to nothing.\n' > "$DS/fx/body"
# `shell: bash` in a workflow means `bash -eo pipefail`: a body with no #N must still read as "no link", not as a failure
DSOPTS='-eo pipefail' dsrun claude/work adlc-bot; check 0 "the Builder's PR with no reference at all is tied to nothing, under pipefail too" $?
dsfx '' '' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'; printf 'Implements #12\n' > "$DS/fx/body"; : > "$DS/fx/fail-body"
dsrun claude/work adlc-bot; check 1 "a failed gh call (the Builder's link) fails the check" $?
dsfx '' '12\n' 12 'stage:design\n' 'README.md\n' 'src/api/x.py\ndocs/adr/7.md\n'
dsrun; check 0 "issue at stage:design (a bounced fast PR) is skipped" $?
dsfx 'dependencies\n' '' 0 - - 'package.json\n'
dsrun dependabot/npm_and_yarn/left-pad-1.3.0; check 0 "a PR tied to no issue is skipped" $?
dsfx 'stage:qa\n' '' 0 - - 'tests/t.py\nsrc/app.py\n'
dsrun; check 1 "PR-label fallback: stage:qa is tests-only" $?
dsfx 'stage:build\n' '12\n' 12 'bug\n' 'src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'
dsrun; check 0 "PR-label fallback: stage:build is held to the linked issue's scope file, though that issue carries no stage" $?
for k in pr-labels files closing issue-12 nfiles; do   # an API error must never read as "nothing to check"
  dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n'; : > "$DS/fx/fail-$k"
  dsrun; check 1 "a failed gh call ($k) fails the check" $?
done
# GitHub lists at most 3000 changed files; past that the list is cut short without a word
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'; echo 3001 > "$DS/fx/nfiles"
dsrun; check 1 "a lane PR with more files than GitHub lists fails rather than pass on the ones listed" $?
echo 3000 > "$DS/fx/nfiles"; dsrun; check 0 "…exactly 3000 is still judged" $?
echo null > "$DS/fx/nfiles"; dsrun; check 1 "…and a file count that cannot be read fails the check" $?
dsfx 'dependencies\n' '' 0 - - 'package.json\n'; echo 8161 > "$DS/fx/nfiles"
dsrun dependabot/npm_and_yarn/left-pad-1.3.0; check 0 "…while a PR in no lane is skipped however large it is" $?
dsfx '' '12\n' 12 'stage:build\n' - 'src/api/x.py\n'
case "$(dsout)" in *"no scope file"*) ok "a PR whose branch has no scope file is told so" ;; *) bad "a missing scope file must be reported as that" ;; esac
# The scope file is read as the blob at that path on the PR head. GitHub's contents API follows a
# link, so a PR could point its scope file at any file on its branch and be held to text its diff
# never shows (seen live: a link to a file listing the stray file's directory passed).
dsfx '' '12\n' 12 'stage:build\n' '@link:src/' 'src/billing/y.py\n.adlc/scope/12.txt\n'
dsrun; check 1 "a scope file that is a link is refused, even one whose target would allow the files" $?
case "$(dsout)" in *"not a plain file"*) ok "…and the refusal says why" ;; *) bad "a link at the scope path must be refused as 'not a plain file'" ;; esac
dsfx '' '12\n' 12 'stage:build\n' '@dir' 'src/billing/y.py\n'
dsrun; check 1 "a directory at the scope path is refused" $?
case "$(dsout)" in *"not a plain file (git mode 040000)"*) ok "…and named as a directory" ;; *) bad "a directory at the scope path must be refused as 'not a plain file'" ;; esac
dsfx '' '12\n' 12 'stage:build\n' '@parentlink:src/\n' 'src/billing/y.py\n'
dsrun; check 1 "a link at the scope folder is refused, even one whose target holds a file that would allow the change" $?
case "$(dsout)" in *".adlc/scope on this PR is not a plain file (git mode 120000)"*) ok "…and the refusal names the folder, not a missing file" ;; *) bad "a link at .adlc/scope must be refused as 'not a plain file', naming .adlc/scope" ;; esac
dsfx '' '12\n' 12 'stage:build\n' '@exec:src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'
dsrun; check 0 "an executable scope file is still a plain file" $?
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n.adlc/scope/12.txt\n'
nohead
dsrun; [ $? -ne 0 ] && ok "full lane: a PR head that cannot be fetched fails the check" || bad "full lane: an unfetchable PR head must fail the check"
dsfx '' '12\n' 12 'stage:design\n' - 'src/api/x.py\n'
nohead
dsrun; check 0 "a PR with no lane stage never fetches, nor asks for a scope file" $?
# The fast lane: the same step also applies the cap, to the PR's real diff (refs/pull/7/head
# against its merge base), with the BASE branch's adlc-triage.sh.
prhead() { # <commands run in a clone of the base> — the result becomes refs/pull/7/head
  rm -rf "$DS/pr"; git clone -q "$DS/remote.git" "$DS/pr" >/dev/null 2>&1
  ( cd "$DS/pr" && eval "$1" && dg add -A && dg commit -q -m pr && dg push -q -f origin HEAD:refs/pull/7/head ) >/dev/null 2>&1
}
fastfx() { dsfx "$1" '13\n' 13 'stage:fast\n' 'src/\nauth/\n.adlc/\n' "$2"; }   # a scope wide enough to isolate the cap
prhead 'echo "y = 2" >> src/a.py'
fastfx '' 'src/a.py\n';                    dsrun; check 0 "fast lane: a small change inside scope and cap passes" $?
fastfx 'lane:fast\n' 'src/a.py\n';         dsrun; check 0 "…and the same once the Builder has added lane:fast" $?
prhead 'for f in b c d e f g; do echo x > src/$f.py; done'
fastfx '' 'src/b.py\n';                    dsrun; check 1 "fast lane: more files than the cap fails" $?
prhead 'mkdir -p auth; echo "k = 1" > auth/login.py'
fastfx '' 'auth/login.py\n';               dsrun; check 1 "fast lane: a sensitive path fails" $?
prhead 'mkdir -p auth; echo "k = 1" > auth/login.py; printf "#!/usr/bin/env bash\ncat >/dev/null; echo FAST; exit 0\n" > .adlc/scripts/adlc-triage.sh'
fastfx '' 'auth/login.py\n.adlc/scripts/adlc-triage.sh\n'
dsrun; check 1 "fast lane: a PR that rewrites the cap script is still judged by the base copy" $?
dsfx '' '12\n' 12 'stage:build\n' 'src/\nauth/\n.adlc/\n' 'auth/login.py\n'
dsrun; check 0 "the cap applies to the fast lane only" $?
prhead 'echo "y = 2" >> src/a.py'
dsfx '' '13\n' 13 'stage:fast\n' 'README.md\n' 'src/a.py\n'
dsrun; check 1 "fast lane: inside the cap but outside the scope still fails" $?
prhead 'git mv src/a.py src/b.py'
fastfx '' 'src/b.py\nsrc/a.py\n';         dsrun; check 0 "fast lane: a small rename is counted as two files, not refused" $?
# a link planted at the scope path on the default branch must not redirect the write into a guard
prhead 'mkdir -p auth; echo "k = 1" > auth/login.py'
dsfx '' '13\n' 13 'stage:fast\n' '#!/usr/bin/env bash\ncat >/dev/null; echo FAST; exit 0\n' 'auth/login.py\n'
mkdir -p "$DS/repo/.adlc/scope"; ln -s ../scripts/adlc-triage.sh "$DS/repo/.adlc/scope/13.txt"
dsrun; check 1 "fast lane: a link at the scope path does not let the PR rewrite the cap" $?
cmp -s "$DS/repo/.adlc/scripts/adlc-triage.sh" "$S/adlc-triage.sh" && ok "…and the default branch's cap script is untouched" || bad "the PR's scope file was written through a link into the cap script"
cp "$S/adlc-triage.sh" "$DS/repo/.adlc/scripts/adlc-triage.sh"
# a base that is not the default branch: the cap is measured against the PR's base, fetched by name
rm -rf "$DS/pr"; git clone -q "$DS/remote.git" "$DS/pr" >/dev/null 2>&1
( cd "$DS/pr" && git checkout -q -b release && for f in r1 r2 r3 r4 r5 r6; do echo x > "src/$f.py"; done && dg add -A && dg commit -q -m "release work" && dg push -q origin release \
  && echo "y = 3" >> src/a.py && dg add -A && dg commit -q -m pr && dg push -q -f origin HEAD:refs/pull/7/head ) >/dev/null 2>&1
fastfx '' 'src/a.py\n';                    dsrun claude/work someone release; check 0 "fast lane: a PR into another branch is measured against that branch" $?
# a tag named like the base branch must not stand in for it (it would hide the PR's first commits)
prhead 'mkdir -p auth; echo "k = 1" > auth/login.py; dg add -A; dg commit -q -m first; echo "y = 2" >> src/a.py'
( cd "$DS/repo" && dg fetch -q origin refs/pull/7/head && dg tag origin/main FETCH_HEAD~1 ) >/dev/null 2>&1
fastfx '' 'auth/login.py\nsrc/a.py\n';     dsrun; check 1 "fast lane: a tag named origin/main does not shorten the diff" $?
( cd "$DS/repo" && dg tag -d origin/main ) >/dev/null 2>&1
# main moves on after the PR branched: the cap is measured from the merge base, not from the tip
prhead 'echo "y = 2" >> src/a.py'
( cd "$DS/repo" && for f in m1 m2 m3 m4 m5 m6; do echo x > "src/$f.py"; done && dg add -A && dg commit -q -m "main moves on" && dg push -q origin main && dg fetch -q origin ) >/dev/null 2>&1
fastfx '' 'src/a.py\n';                    dsrun; check 0 "fast lane: the cap is measured from the merge base, not from main's tip" $?
# A submodule is a gitlink (mode 160000): a one-line entry in numstat however much code the
# commit it points to brings in. This PR adds one under src/ — no sensitive path is involved — so
# only the entry's mode can tell the cap what it is. (The empty directory is what keeps a gitlink
# through `git add -A`; without it the entry is staged as deleted.)
prhead 'mkdir -p src/lib; git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),src/lib"'
fastfx '' 'src/lib\n';                     dsrun; check 1 "fast lane: a new submodule fails the cap, at an innocent path" $?
case "$(dsout)" in *"submodule change: src/lib"*) ok "…and the cap names it" ;; *) bad "the cap must report the submodule" ;; esac
# The default branch now carries that submodule, and a .gitmodules that tells git never to show
# it as changed (`ignore = all`, which a repo may set to quiet `git status`). The diff reads THIS
# checkout's .gitmodules, so a plain `git diff` here shows a bump as no change at all.
( cd "$DS/repo" && mkdir -p src/lib && dg update-index --add --cacheinfo "160000,$(dg rev-parse HEAD),src/lib" \
  && printf '[submodule "lib"]\n\tpath = src/lib\n\turl = ./lib\n\tignore = all\n' > .gitmodules \
  && dg add -A && dg commit -q -m "add a submodule, ignore = all" && dg push -q origin main && dg fetch -q origin ) >/dev/null 2>&1
prhead 'git update-index --cacheinfo "160000,$(git rev-parse HEAD),src/lib"'   # a bump: it pointed at HEAD~1
eq "" "fixture: a plain diff in that checkout shows the bump as nothing at all" \
   "$(cd "$DS/repo" && dg fetch -q origin refs/pull/7/head && dg diff --numstat --no-renames refs/remotes/origin/main FETCH_HEAD 2>/dev/null || echo GIT-FAILED)"
case "$(cd "$DS/repo" && dg diff --numstat --no-renames --raw --ignore-submodules=none refs/remotes/origin/main FETCH_HEAD 2>/dev/null)" in
  *":160000 160000 "*"M"$'\t'"src/lib"*"1"$'\t'"1"$'\t'"src/lib"*) ok "fixture: …and with the cap's flags it is a one-line gitlink entry" ;;
  *) bad "fixture: with the cap's flags the bump must show as a gitlink entry" ;; esac
fastfx '' 'src/lib\n';                     dsrun; check 1 "fast lane: a submodule bump fails the cap, though the default branch's .gitmodules says ignore = all" $?
case "$(dsout)" in *"submodule change: src/lib"*) ok "…and the cap names it" ;; *) bad "the cap must report the hidden submodule bump" ;; esac
prhead 'echo "z = 3" >> src/a.py'
fastfx '' 'src/a.py\n';                    dsrun; check 0 "fast lane: an ordinary small change still passes beside an unchanged submodule" $?
prhead 'echo "y = 2" >> src/a.py'
dsfx 'lane:fast\n' '' 0 - - 'src/a.py\n'
dsrun; check 1 "lane:fast with no issue and no scope file fails" $?
fastfx '' 'src/a.py\n'; nohead
dsrun; [ $? -ne 0 ] && ok "fast lane: a PR head that cannot be fetched fails the check" || bad "fast lane: an unfetchable PR head must fail the check"
# The stub does not run --jq. Where a real jq exists, run the two non-trivial filters as shipped.
if command -v jq >/dev/null 2>&1; then
  cf=$(sed -n "s/.*closingIssuesReferences --jq '\(.*\)')\$/\1/p" "$DS/step.sh")
  ff=$(sed -n "s/.*per_page=100\" --jq '\(.*\)')\$/\1/p" "$DS/step.sh")
  pr='{"url":"https://github.com/o/r/pull/7","closingIssuesReferences":[{"number":123,"url":"https://github.com/o/tracker/issues/123"},{"number":45,"url":"https://github.com/o/r/issues/45"}]}'
  eq 45 "closing reference: the first one in THIS repo"        "$(printf '%s' "$pr" | jq -r "$cf" 2>&1)"
  lf=$(sed -n "s/.*closingIssuesReferences,body --jq '\(.*\)')\$/\1/p" "$DS/step.sh")
  eq "#123 See #9 " "the lanes' rule: the first closing reference of any repo, then the body" "$(printf '%s' "${pr%\}},\"body\":\"See #9\"}" | jq -r "$lf" 2>&1 | tr '\n' ' ')"
  eq "See #9 "      "the lanes' rule: no closing reference → the body alone"                  "$(printf '%s' '{"closingIssuesReferences":[],"body":"See #9"}' | jq -r "$lf" 2>&1 | tr '\n' ' ')"
  eq "" "closing reference: only another repo's → none"        "$(printf '%s' '{"url":"https://github.com/o/r/pull/7","closingIssuesReferences":[{"number":123,"url":"https://github.com/o/r-fork/issues/123"}]}' | jq -r "$cf" 2>&1)"
  jf=$(sed -n "s/.*issues\/\$n\" --jq '\(.*\)' 2>.*/\1/p" "$DS/step.sh")
  eq "stage:build " "issue lookup: an open issue gives its labels" "$(printf '%s' '{"state":"open","labels":[{"name":"stage:build"}]}' | jq -r "$jf" 2>&1 | tr '\n' ' ')"
  eq ""             "issue lookup: a closed issue gives none"      "$(printf '%s' '{"state":"closed","labels":[{"name":"stage:qa"},{"name":"gate:deploy"}]}' | jq -r "$jf" 2>&1 | tr '\n' ' ')"
  eq "src/api/new.py src/db/old.py a.py " "file list: a rename counts under both paths" "$(printf '%s' '[{"filename":"src/api/new.py","previous_filename":"src/db/old.py"},{"filename":"a.py"}]' | jq -r "$ff" 2>&1 | tr '\n' ' ')"
else
  echo "  · skipped the --jq filter checks (no jq here)"
fi
rm -rf "$DS"

echo "fix-loop cap step (the workflow's own run: script, on a real git history):"
# The cap bounds the fix rounds of ONE pull request. The step once counted `adlc-fix:` subjects
# over the whole history of the PR head — which holds every earlier PR's fix commits once they
# are merged — so after a single PR that took 3 rounds, each new PR stopped before its first
# fix. Run the step as shipped: a scratch repository holding that history, and a checkout shaped
# like the runner's. Nothing here has a remote, and nothing is pushed.
if command -v git >/dev/null 2>&1; then
  FC="$(mktemp -d)"; FW="$ROOT/templates/github/adlc-fix.yml"
  step_run "$FW" '- name: Loop cap' > "$FC/cap.sh"
  fgit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
  fbranch() { # <new branch> <from> <commit subject>… — cut the branch, one commit per subject
    local b="$1" from="$2" s; shift 2
    fgit -C "$FC/seed" checkout -q -b "$b" "$from"
    for s in "$@"; do fgit -C "$FC/seed" commit -q --allow-empty -m "$s"; done
  }
  {
    fgit init -q "$FC/seed"; fgit -C "$FC/seed" symbolic-ref HEAD refs/heads/main
    mkdir -p "$FC/seed/.adlc/scripts"; cp "$S/adlc-fix-cap.sh" "$FC/seed/.adlc/scripts/"
    fgit -C "$FC/seed" add -A; fgit -C "$FC/seed" commit -q -m init
    fbranch feat/1-old     main 'feat: old' 'adlc-fix: a' 'adlc-fix: b' 'adlc-fix: c'   # an earlier PR: 3 rounds…
    fbranch feat/2-behind  main 'feat: behind'                                          # (two PRs opened before
    fbranch feat/3-synced  main 'feat: synced'                                          #  that one merged)
    fgit -C "$FC/seed" checkout -q main
    fgit -C "$FC/seed" merge -q --no-ff -m 'Merge pull request #1 from o/feat/1-old' feat/1-old   # …merged with a merge commit
    fbranch feat/4-new     main 'feat: new'
    # 2 rounds, among subjects that only look like one: the prefix mid-subject and in a body
    # line, in capitals, and as the start of a longer word
    fbranch feat/5-two     main 'feat: two' 'adlc-fix: a' 'adlc-fix: b' \
      $'docs: adlc-fix: is the prefix\n\nadlc-fix: a body line' 'ADLC-FIX: shouted' 'adlc-fixture: x'
    fbranch feat/6-three   main 'feat: three' 'adlc-fix: a' 'adlc-fix: b' 'adlc-fix: c'
    fbranch feat/7-stacked feat/6-three 'feat: stacked'
    fgit -C "$FC/seed" checkout -q feat/3-synced
    fgit -C "$FC/seed" merge -q --no-ff -m "Merge branch 'main' into feat/3-synced" main
    fgit -C "$FC/seed" commit -q --allow-empty -m 'adlc-fix: a'; fgit -C "$FC/seed" commit -q --allow-empty -m 'adlc-fix: b'
  } >/dev/null 2>&1
  # caprun <PR head> <base ref> — the step, run as Actions does (bash -e), in a checkout as
  # actions/checkout leaves it with fetch-depth: 0: every branch a remote-tracking ref, the PR
  # head the only local branch (there is no local `main` to read).
  caprun() {
    rm -rf "$FC/run"; : > "$FC/out"; : > "$FC/said"
    { fgit init -q "$FC/run" && fgit -C "$FC/run" fetch -q "$FC/seed" '+refs/heads/*:refs/remotes/origin/*' \
        && fgit -C "$FC/run" checkout -q -B "$1" "refs/remotes/origin/$1"; } >/dev/null 2>&1 || return 99
    ( cd "$FC/run" && env BASE_REF="$2" GITHUB_OUTPUT="$FC/out" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -e "$FC/cap.sh" ) > "$FC/said" 2>/dev/null
  }
  capsaid() { cat "$FC/said" "$FC/out" | tr '\n' ' '; }   # its decision + the output it set
  fixes()   { fgit -C "$FC/seed" log --format='%s' "$1" 2>/dev/null | grep -c '^adlc-fix:' || true; }   # <branch> → adlc-fix: commits in its whole history
  [ -s "$FC/cap.sh" ] && ok "run: script extracted from the template" || bad "could not extract the run: script"
  # the cases mean nothing unless the history really holds another PR's fix commits
  eq 3 "fixture: main holds an earlier PR's 3 adlc-fix: commits, merged"  "$(fixes main)"
  eq 3 "fixture: …so they are in the history of a branch cut from it"     "$(fixes feat/4-new)"
  caprun feat/4-new main;    eq "decision=GO stop=false "  "a new PR with 0 fix rounds → GO (was: STOP, on the merged PR's 3)" "$(capsaid)"
  caprun feat/5-two main;    eq "decision=GO stop=false "  "2 fix rounds on the PR → GO (only a subject that starts with adlc-fix: is a round)" "$(capsaid)"
  caprun feat/6-three main;  eq "decision=STOP stop=true " "3 fix rounds on the PR → STOP" "$(capsaid)"
  caprun feat/2-behind main; eq "decision=GO stop=false "  "a PR cut before the other one merged: fix commits only main has are not its rounds" "$(capsaid)"
  caprun feat/3-synced main; eq "decision=GO stop=false "  "…nor once it has merged main into itself (2 rounds of its own → GO)" "$(capsaid)"
  caprun feat/7-stacked feat/6-three
  eq "decision=GO stop=false " "a PR stacked on another PR's branch is not charged that branch's 3 rounds, while it is its base" "$(capsaid)"
  # the base branch reaches the script through env:, never written into it by ${{ }}
  case "$(cat "$FC/cap.sh")" in *'${{'*) bad "the script has no \${{ }} expression written into it" ;; *) ok "the script has no \${{ }} expression written into it" ;; esac
  eq 1 "the step's env: hands it the PR's base branch as BASE_REF" \
     "$(awk '/^      - / { s = ($0 ~ /- name: Loop cap/) } s' "$FW" | tr -d "\"'" | grep -cE '^ +BASE_REF: \$\{\{ github\.(event\.pull_request\.base\.ref|base_ref) \}\}[[:space:]]*$' || true)"
  # a count that cannot be taken must stop the step: read as "0 rounds" it would never cap
  caprun feat/4-new gone; rc=$?   # (99 = the fixture checkout itself failed)
  case "$rc" in 0|99) bad "a base branch the checkout does not have fails the step (exit $rc)" ;; *) ok "a base branch the checkout does not have fails the step" ;; esac
  eq "" "…with no decision and no output (not a GO)" "$(capsaid)"
  grep -qE '^ +fetch-depth: 0([[:space:]]|$)' "$FW" && ok "adlc-fix.yml checks out the full history (the base branch + every commit of the PR)" \
    || bad "adlc-fix.yml must check out with fetch-depth: 0 — the cap reads the base branch and every commit of the PR"
  rm -rf "$FC"
else
  bad "fix-loop cap step tests need git"
fi

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
hg reset -q; rm -f "$HK/.adlc/scope/12.txt"; ln -s ../../src "$HK/.adlc/scope/12.txt"; : > "$HK/src/api/z.py"; hg add src/api/z.py
hook; check 1 "a scope file that is a link blocks the commit, whatever it points at (CI refuses it too)" $?
rm -f "$HK/.adlc/scope/12.txt"; ln -s nowhere "$HK/.adlc/scope/12.txt"
hook; check 1 "…a dangling link too" $?
rm -rf "$HK/.adlc/scope"; mkdir -p "$HK/elsewhere"; printf 'src/api/\n' > "$HK/elsewhere/12.txt"; ln -s ../elsewhere "$HK/.adlc/scope"
hook; check 1 "…and a link at the scope folder, though its target holds a file that would allow the change (CI reads nothing through it)" $?
rm -f "$HK/.adlc/scope"; mkdir -p "$HK/.adlc/scope"; ln -s ../../src "$HK/.adlc/scope/12.txt"; hg add .adlc/scope; rm -f "$HK/.adlc/scope/12.txt"; printf 'src/api/\n' > "$HK/.adlc/scope/12.txt"
hook; check 1 "a link that is staged blocks the commit even when the working tree now holds a plain file" $?
rm -rf "$HK"

echo "adlc-metrics.sh (against a stub gh):"
# first_pass_approved once counted merged PRs whose reviewDecision was APPROVED — which the
# pipeline's PRs never carry: the review lane advances build → qa on the agents' verdict comments
# (`ADLC-ADV: PASS|CHANGES`, `ADLC-ARCH: PASS|CHANGES`), and a bot cannot approve its own PR, so
# the count read 0 everywhere. Now a merged PR is first-pass when no comment of its holds a CHANGES
# verdict. Run the script as shipped against a stub gh that serves the PR list from a fixture and
# runs the script's own --jq filter over it (the window check lives in that filter).
if command -v jq >/dev/null 2>&1; then
  MX="$(mktemp -d)"; mkdir -p "$MX/bin" "$MX/repo"
  cat > "$MX/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: `pr list` serves $MX_PRS, `run list` $MX_RUNS, `run view <id>` $MX_JOBS/<id>.json (none → gh's failure),
# `issue list` an empty list; all through the call's own --jq
echo "$1 $2" >> "$MX_CALLS"
case "$1 $2" in "pr list") src="$MX_PRS" ;; "run list") src="$MX_RUNS" ;; "run view") src="$MX_JOBS/$3.json"; [ -f "$src" ] || { echo "run 1 not found" >&2; exit 1; } ;; "issue list") src=/dev/null ;; *) exit 2 ;; esac
f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done
[ "$src" = /dev/null ] && echo '[]' | jq -r "$f" || jq -r "$f" "$src"   # -r: gh --jq prints a string result raw
SH
  chmod +x "$MX/bin/gh"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # <number> <mergedAt> <comment bodies…> → one PR object
  mxpr() { local n="$1" at="$2"; shift 2; jq -cn --argjson n "$n" --arg at "$at" '$ARGS.positional | map({body: .}) | {number: $n, mergedAt: $at, createdAt: ($at | fromdate - 3600 | todate), changedFiles: 1, headRefName: ("feat/" + ($n|tostring)), comments: .}' --args "$@"; }
  {
    mxpr 1 "$now" 'Findings: none.
ADLC-ADV: PASS' 'Conforms.
ADLC-ARCH: PASS'
    mxpr 2 "$now" 'Critical: …
ADLC-ADV: CHANGES' 'ADLC-ARCH: PASS' 'Fixed now.
ADLC-ADV: PASS'
    mxpr 3 "$now" 'ADLC-ADV: PASS' 'Out of scope.
ADLC-ARCH:  CHANGES' 'ADLC-ARCH: PASS'
    mxpr 4 "$now"
    mxpr 5 "2000-01-01T00:00:00Z" 'ADLC-ADV: CHANGES'
    mxpr 6 "$now" 'The lane reads `ADLC-ADV: CHANGES` to start the fix loop; nothing to fix here.
ADLC-ADV: PASS' 'ADLC-ARCH: PASS'
    mxpr 7 "$now" '**ADLC-ADV:** CHANGES' 'ADLC-ARCH: PASS'
    mxpr 8 "$now" 'ADLC-ADV: PASSED' 'ADLC-ARCH: CHANGESET pending'
    mxpr 9 "$now"
    mxpr 10 "$now"
  } | jq -s . > "$MX/prs.json"
  # CI runs: PR 1's branch went green first time, PR 2's took a red run then a green one; another workflow's
  # run is ignored, and so is a red run on PR 1's branch name from BEFORE that PR was opened (a reused name).
  # Issue 56: PR 3's first run died creating an ephemeral database, before any test ran — an infra failure,
  # not a red test run; PR 9's red run cannot be looked up (gh fails) and stays a plain failure; PR 10's first
  # run is a fail-fast matrix whose cancelled leg is listed before the leg that died in "Set up job".
  jq -n --arg at "$now" '[
    {databaseId: 11, workflowName: "ADLC CI", headBranch: "feat/1", status: "completed", conclusion: "success", createdAt: $at},
    {databaseId: 10, workflowName: "ADLC CI", headBranch: "feat/1", status: "completed", conclusion: "failure", createdAt: ($at | fromdate - 7200 | todate)},
    {databaseId: 21, workflowName: "ADLC CI", headBranch: "feat/2", status: "completed", conclusion: "failure", createdAt: $at},
    {databaseId: 22, workflowName: "ADLC CI", headBranch: "feat/2", status: "completed", conclusion: "success", createdAt: $at},
    {databaseId: 23, workflowName: "ADLC diff-scope", headBranch: "feat/2", status: "completed", conclusion: "failure", createdAt: $at},
    {databaseId: 31, workflowName: "ADLC CI", headBranch: "feat/3", status: "completed", conclusion: "failure", createdAt: $at},
    {databaseId: 32, workflowName: "ADLC CI", headBranch: "feat/3", status: "completed", conclusion: "success", createdAt: $at},
    {databaseId: 91, workflowName: "ADLC CI", headBranch: "feat/9", status: "completed", conclusion: "failure", createdAt: $at},
    {databaseId: 92, workflowName: "ADLC CI", headBranch: "feat/9", status: "completed", conclusion: "success", createdAt: $at},
    {databaseId: 101, workflowName: "ADLC CI", headBranch: "feat/10", status: "completed", conclusion: "failure", createdAt: $at},
    {databaseId: 102, workflowName: "ADLC CI", headBranch: "feat/10", status: "completed", conclusion: "success", createdAt: $at}]' > "$MX/runs.json"
  mkdir -p "$MX/jobs"
  jq -n '{jobs: [{name: "backend", conclusion: "failure", steps: [{name: "Set up job", conclusion: "success"}, {name: "Checkout", conclusion: "success"}, {name: "Run tests", conclusion: "failure"}, {name: "Upload coverage", conclusion: "skipped"}]}]}' > "$MX/jobs/21.json"
  jq -n '{jobs: [{name: "lint", conclusion: "success", steps: [{name: "Lint", conclusion: "success"}]},
                 {name: "backend", conclusion: "failure", steps: [{name: "Set up job", conclusion: "success"}, {name: "Create ephemeral Neon branch", conclusion: "failure"}, {name: "Run tests", conclusion: "skipped"}]}]}' > "$MX/jobs/31.json"
  jq -n '{jobs: [{name: "test (3.11)", conclusion: "cancelled", steps: [{name: "Set up job", conclusion: "success"}, {name: "Checkout", conclusion: "success"}, {name: "Run tests", conclusion: "cancelled"}]},
                 {name: "test (3.12)", conclusion: "failure", steps: [{name: "Set up job", conclusion: "failure"}, {name: "Checkout", conclusion: "skipped"}]}]}' > "$MX/jobs/101.json"
  : > "$MX/calls"
  OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs.json" MX_RUNS="$MX/runs.json" MX_JOBS="$MX/jobs" MX_CALLS="$MX/calls" bash "$S/adlc-metrics.sh" 30 2>&1 ); check 0 "the script runs to the end" $?
  eq "iterations_to_green: avg 1.4 CI runs per merged PR; failed_first: 2 / 5" "iterations-to-green: CI runs per merged PR branch since the PR opened, from one run list call; other lanes and older runs on a reused branch name do not count; a run that died in a setup step is left out (also when a cancelled matrix leg is listed before the failed one, and when the step is the runner's own 'Set up job'), a red run gh cannot describe stays red" "$(printf '%s\n' "$OUT" | grep '^iterations_to_green:')"
  eq "infra_failed: 2 / 9 CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran; not counted above" "infra_failed: the setup-step failures, against every CI run of the merged PRs" "$(printf '%s\n' "$OUT" | grep '^infra_failed:')"
  eq 1 "…from one gh run list call" "$(grep -c '^run list$' "$MX/calls")"
  eq 4 "…and one gh run view call per red run on a merged PR's branch (none for green runs, none for the pre-PR red run)" "$(grep -c '^run view$' "$MX/calls")"
  eq "merged_prs: 9"             "merged PRs: those in the window"                                   "$(printf '%s\n' "$OUT" | grep '^merged_prs:')"
  eq "first_pass_approved: 6 / 9" "first pass: no comment whose last verdict is CHANGES (a later PASS comment does not undo one; a PR with no verdict counts; a CHANGES quoted in the prose of a PASS comment is not one; a bold **ADLC-ADV:** CHANGES is one, as adlc-verdict.sh reads it; PASSED and CHANGESET are no verdict)" "$(printf '%s\n' "$OUT" | grep '^first_pass_approved:')"
  eq 1 "…from one gh pr list call, whatever the number of PRs" "$(grep -c '^pr list$' "$MX/calls")"
  eq 0 "a host with no blocked run and no local CI marker gets no blocked: or local_ci: line (the lines above are as they were)" "$(printf '%s\n' "$OUT" | grep -cE '^(blocked|local_ci):')"
  OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs.json" MX_RUNS="$MX/runs.json" MX_JOBS="$MX/jobs" MX_CALLS="$MX/calls" ADLC_SETUP_STEPS='^nothing matches$' bash "$S/adlc-metrics.sh" 30 2>&1 )
  eq "iterations_to_green: avg 1.8 CI runs per merged PR; failed_first: 4 / 5" "ADLC_SETUP_STEPS is the rule: a regex that matches no step counts every red run as a test failure" "$(printf '%s\n' "$OUT" | grep '^iterations_to_green:')"
  eq "infra_failed: 0 / 9 CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran; not counted above" "…and reports 0 setup failures" "$(printf '%s\n' "$OUT" | grep '^infra_failed:')"
  # the default regex: setup-shaped names match, test steps that merely contain one of its words do not
  DEF=$(sed -n 's/^ADLC_SETUP_STEPS="${ADLC_SETUP_STEPS:-\(.*\)}"$/\1/p' "$S/adlc-metrics.sh"); [ -n "$DEF" ] && ok "the default ADLC_SETUP_STEPS is read off the script" || bad "the default ADLC_SETUP_STEPS could not be read off the script"
  for st in "Set up job" "Post Run actions/checkout@v4" "Checkout" "Install dependencies" "Setup Python" "Restore cache" "Cache node modules" "Docker login" "Log in to the registry" "Provision database" "Create ephemeral Neon branch" "Install and test"; do
    printf '%s' "$st" | grep -qiE "$DEF" && ok "default ADLC_SETUP_STEPS matches '$st'" || bad "default ADLC_SETUP_STEPS must match '$st'"
  done
  for st in "Run tests" "Run pytest" "Login flow tests" "Test cache invalidation" "Run installer tests" "Run setup tests" "Test create branch flow" "Set upstream" "Build"; do
    printf '%s' "$st" | grep -qiE "$DEF" && bad "default ADLC_SETUP_STEPS must not match '$st'" || ok "default ADLC_SETUP_STEPS does not match '$st'"
  done
  jq -n --arg at "$now" '[{databaseId: 31, workflowName: "ADLC CI", headBranch: "feat/3", status: "completed", conclusion: "failure", createdAt: $at}]' > "$MX/only-infra.json"
  OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs.json" MX_RUNS="$MX/only-infra.json" MX_JOBS="$MX/jobs" MX_CALLS="$MX/calls" bash "$S/adlc-metrics.sh" 30 2>&1 )
  eq "iterations_to_green: every CI run of the window's merged PRs failed in a setup step (1 runs); no test signal" "only setup failures: says there is no test signal instead of dividing by zero" "$(printf '%s\n' "$OUT" | grep '^iterations_to_green:')"
  # Issue 34: a host whose Actions is blocked, running the battery with adlc-local-ci.sh. PR 20: two runs GitHub
  # failed in 3 s with no step (no job at all; a job with no step), and two local CI comments, FAIL then PASS
  # (the second ends in blank lines). PR 21: no Actions run, two PASS markers wearing markup, the second on a
  # last line that holds a FAIL marker before it (the last one is read). PR 22: a run that failed in 3 s but RAN its steps (a
  # real failure), a green one, and a comment that quotes a FAIL marker and ends in PASS (one PASS). PR 23: a fast
  # failure gh cannot describe and a no-step failure that took five minutes both stay failures; its four
  # near-markers (PASSED, a short sha, another word ending in ADLC-CI, no "head") are none, and neither are two
  # comments that QUOTE a real marker (QA's verdict does): one in the prose of its only line, one on a line that
  # is not the comment's last. PR 24: one blocked
  # run (exactly 60 s; its only steps skipped or never concluded) and nothing else: no test signal from it.
  H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
  {
    mxpr 20 "$now" "Local CI on \`$H1\`, run on a local machine.

| check | result | exit | seconds |
|---|---|---|---|
| tests | FAIL | 1 | 12 |

ADLC-CI: FAIL head $H1" "ADLC-CI: PASS head $H2

  "
    mxpr 21 "$now" "**ADLC-CI: PASS** head \`$H1\`" "\`ADLC-CI: FAIL head $H1\` \`ADLC-CI: PASS head $H2\`"
    mxpr 22 "$now" "The marker reads \`ADLC-CI: FAIL head $H1\`; this run:
ADLC-CI: PASS head $H2"
    mxpr 23 "$now" "ADLC-CI: PASSED head $H1" 'ADLC-CI: PASS head abc1234' "MY-ADLC-CI: PASS head $H1" "ADLC-CI: PASS $H1" \
      "QA: the local run says ADLC-CI: PASS head $H1" "ADLC-CI: FAIL head $H1

That is the local run; the battery is red, so the verdict is CHANGES."
    mxpr 24 "$now"
  } | jq -s . > "$MX/prs2.json"
  jq -n --arg at "$now" 'def r(id; br; c; s): {databaseId: id, workflowName: "ADLC CI", headBranch: br, status: "completed", conclusion: c, createdAt: $at, updatedAt: ($at | fromdate + s | todate)};
    [r(201; "feat/20"; "failure"; 3), r(202; "feat/20"; "failure"; 3), r(221; "feat/22"; "failure"; 3), r(222; "feat/22"; "success"; 300),
     r(231; "feat/23"; "failure"; 3), r(232; "feat/23"; "failure"; 300), r(233; "feat/23"; "success"; 300), r(241; "feat/24"; "failure"; 60)]' > "$MX/runs2.json"
  mkdir -p "$MX/jobs2"
  echo '{"jobs": []}' > "$MX/jobs2/201.json"; echo '{"jobs": []}' > "$MX/jobs2/232.json"
  echo '{"jobs": [{"name": "tests", "conclusion": "failure", "steps": []}]}' > "$MX/jobs2/202.json"
  echo '{"jobs": [{"name": "tests", "conclusion": "failure", "steps": [{"name": "Set up job", "conclusion": "success"}, {"name": "Run tests", "conclusion": "failure"}]}]}' > "$MX/jobs2/221.json"
  echo '{"jobs": [{"name": "tests", "conclusion": "failure", "steps": [{"name": "Set up job", "conclusion": "skipped"}, {"name": "Run tests", "conclusion": ""}]}]}' > "$MX/jobs2/241.json"
  : > "$MX/calls"
  OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs2.json" MX_RUNS="$MX/runs2.json" MX_JOBS="$MX/jobs2" MX_CALLS="$MX/calls" bash "$S/adlc-metrics.sh" 30 2>&1 ); check 0 "blocked runs + local CI markers: the script runs to the end" $?
  eq "iterations_to_green: avg 2.5 CI runs per merged PR; failed_first: 3 / 4" "a run GitHub failed within 60 s with no step is not a red test run, and a local CI marker comment is a CI run (FAIL = red): a PR with only blocked runs and markers is counted from its markers, one with markers and no Actions run too, one with only blocked runs not at all; a fast failure whose steps ran, one gh cannot describe and a slow no-step failure stay red" "$(printf '%s\n' "$OUT" | grep '^iterations_to_green:')"
  eq "blocked: 3 / 8 CI runs were failed by GitHub within 60 s with no step run (what an exhausted Actions budget looks like); not counted above" "blocked: its own line, against every Actions CI run of the merged PRs (60 s is still within; a skipped step and one with no conclusion did not run)" "$(printf '%s\n' "$OUT" | grep '^blocked:')"
  eq "local_ci: 5 ADLC-CI marker comments on 3 merged PRs (1 FAIL), counted above as CI runs" "local_ci: one per comment whose last non-blank line starts with the marker (trailing blank lines allowed; the last marker on that line is read; a FAIL quoted on an earlier line does not count); bold and backtick markup read; PASSED, a short sha, a longer word ending in ADLC-CI and a marker with no 'head' are not markers; a marker quoted in prose, or on a line that is not the last, is not a run" "$(printf '%s\n' "$OUT" | grep '^local_ci:')"
  eq "infra_failed: 0 / 8 CI runs died in a setup step (ADLC_SETUP_STEPS), before any test ran; not counted above" "…and the infra_failed line keeps its shape beside them" "$(printf '%s\n' "$OUT" | grep '^infra_failed:')"
  eq 6 "…from the run view calls the script already made: one per red run on a merged PR's branch, none added" "$(grep -c '^run view$' "$MX/calls")"
  eq 1 "…and still one pr list call: the markers come with the comments it already carries" "$(grep -c '^pr list$' "$MX/calls")"
  jq '[.[] | select(.number == 24)]' "$MX/prs2.json" > "$MX/prs3.json"
  OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs3.json" MX_RUNS="$MX/runs2.json" MX_JOBS="$MX/jobs2" MX_CALLS="$MX/calls" bash "$S/adlc-metrics.sh" 30 2>&1 )
  eq "iterations_to_green: every CI run of the window's merged PRs was blocked or failed in a setup step (1 runs); no test signal" "only blocked runs: says there is no test signal, and why" "$(printf '%s\n' "$OUT" | grep '^iterations_to_green:')"
  eq "blocked: 1 / 1 CI runs were failed by GitHub within 60 s with no step run (what an exhausted Actions budget looks like)" "…with the blocked line" "$(printf '%s\n' "$OUT" | grep '^blocked:')"
  echo '[]' > "$MX/prs.json"
  OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs.json" MX_RUNS="$MX/runs.json" MX_JOBS="$MX/jobs" MX_CALLS="$MX/calls" bash "$S/adlc-metrics.sh" 30 2>&1 )
  eq "first_pass_approved: 0 / 0" "no merged PRs: 0 / 0" "$(printf '%s\n' "$OUT" | grep '^first_pass_approved:')"
  eq "iterations_to_green: no CI runs found for the merged PRs of the window" "no merged PRs: iterations-to-green says so" "$(printf '%s\n' "$OUT" | grep '^iterations_to_green:')"
  rm -rf "$MX"
else
  echo "  · skipped the metrics checks (no jq here)"
fi

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

echo "design → build handoff steps (the workflows' own run: scripts, real git + a stub gh):"
# The Architect cannot commit. adlc-design.yml's last step commits its docs/ to adlc/design-<n>
# (plus the scope file that keeps the ADR in scope on the Builder's PR) and only then advances
# the issue; adlc-builder.yml's first step starts the Builder from that branch. Run both as
# shipped: a bare origin, fresh clones as the runner's checkout, and a git that refuses to
# guess an identity (so a commit that names none fails here as it would on a bare runner).
if command -v git >/dev/null 2>&1; then
  HO="$(mktemp -d)"; mkdir -p "$HO/bin"
  step_run "$ROOT/templates/github/adlc-design.yml"  '- name: Hand the design to the Builder' > "$HO/handoff.sh"
  step_run "$ROOT/templates/github/adlc-builder.yml" '- name: Start from the design branch'   > "$HO/start.sh"
  cat > "$HO/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: the issue's comments come from $HO_COMMENTS; the write calls the handoff makes are logged
case "$1 $2" in
  "issue view") [ -z "${HO_FAIL_VIEW:-}" ] || { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
                case "$*" in *"--json comments"*) cat "$HO_COMMENTS" ;; *"--json labels"*) printf '%s\n' adlc:auto stage:design ;; *) exit 2 ;; esac ;;
  "issue comment"|"issue edit") shift; echo "$*" >> "$HO_CALLS" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$HO/bin/gh"
  hgit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
  hgit init -q --bare "$HO/origin.git"; hgit -C "$HO/origin.git" symbolic-ref HEAD refs/heads/main
  hgit init -q "$HO/seed"; hgit -C "$HO/seed" symbolic-ref HEAD refs/heads/main
  mkdir -p "$HO/seed/.adlc/scripts" "$HO/seed/docs/adr" "$HO/seed/src/api"
  cp "$S/adlc-diff-scope.sh" "$S/adlc-relabel.sh" "$HO/seed/.adlc/scripts/"
  echo template > "$HO/seed/docs/adr/template.md"; echo first > "$HO/seed/docs/adr/0001-adopt.md"
  echo guide > "$HO/seed/docs/guide.md"; echo x > "$HO/seed/src/api/a.py"
  ( cd "$HO/seed" && hgit add -A && hgit -c user.name=t -c user.email=t@example.com commit -qm init \
    && hgit remote add origin "$HO/origin.git" && hgit push -q origin main ) >/dev/null 2>&1
  runner() { rm -rf "$HO/run"; hgit clone -q "$HO/origin.git" "$HO/run" >/dev/null 2>&1; }   # a fresh checkout, as each job gets
  hstep() { # <script> <issue> [ENV=val …] — runs it as Actions does (bash -e) in the runner checkout
    local script="$1" n="$2"; shift 2
    : > "$HO/calls"
    ( cd "$HO/run" && env PATH="$HO/bin:$PATH" HO_CALLS="$HO/calls" HO_COMMENTS="$HO/comments" N="$n" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
        "$@" bash -e "$HO/$script" ) >/dev/null 2>&1
  }
  says()   { printf '%b' "$1" > "$HO/comments"; }                     # the issue's comments
  hcalls() { cut -d' ' -f1-6 "$HO/calls" | tr '\n' '|'; }
  lacks()  { grep -c -- "finished without $1" "$HO/calls" 2>/dev/null || true; }   # what the step said was missing
  otree()  { hgit -C "$HO/origin.git" -c core.quotePath=false ls-tree -r --name-only "$1" 2>/dev/null | tr '\n' '|'; }
  oref()   { hgit -C "$HO/origin.git" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
  oscope() { hgit -C "$HO/origin.git" show "adlc/design-$1:.adlc/scope/$1.txt" 2>/dev/null | tr '\n' '|'; }
  [ -s "$HO/handoff.sh" ] && [ -s "$HO/start.sh" ] && ok "both run: scripts extracted from the templates" || bad "could not extract the handoff run: scripts"
  main0=$(oref main)

  # ── no ADR ⇒ no advance ──
  runner; echo stray > "$HO/run/src/api/b.py"; says 'ADLC-BREAKDOWN: docs/adr/0002-login.md\n'
  hstep handoff.sh 7; check 1 "no ADR: the step fails" $?
  eq "comment 7 --body ⚠️ The design|" "…says so on the issue and leaves the labels alone" "$(hcalls)"
  eq "" "…and pushes no design branch" "$(oref adlc/design-7)"
  # (each has a breakdown line naming it, so only the ADR rule can be what stops the step)
  runner; echo changed > "$HO/run/docs/adr/template.md"; echo more > "$HO/run/docs/guide.md"; says 'ADLC-BREAKDOWN: docs/adr/template.md\n'
  hstep handoff.sh 7; check 1 "the template (and other docs) are not an ADR" $?
  eq 1 "…and that is what the step reports" "$(lacks 'an ADR')"
  runner; rm "$HO/run/docs/adr/0001-adopt.md"; says 'ADLC-BREAKDOWN: docs/adr/0001-adopt.md\n'
  hstep handoff.sh 7; check 1 "a deleted ADR is not a design" $?
  eq 1 "…and that is what the step reports" "$(lacks 'an ADR')"

  # ── no task breakdown ⇒ no advance ──
  runner; echo adr > "$HO/run/docs/adr/0002-login.md"; says 'Stories look fine.\n'
  hstep handoff.sh 7; check 1 "ADR but no task-breakdown comment: the step fails" $?
  eq 1 "…for the missing breakdown" "$(lacks 'a task-breakdown comment')"
  eq "comment 7 --body ⚠️ The design|" "…says so, and neither pushes nor relabels" "$(hcalls)$(oref adlc/design-7)"
  runner; echo adr > "$HO/run/docs/adr/0002-login.md"; says '## Tasks\nADLC-BREAKDOWN: docs/adr/0001-adopt.md\n'
  hstep handoff.sh 7; check 1 "a breakdown that names another ADR (an earlier round) does not count" $?
  runner; echo adr > "$HO/run/docs/adr/0002-login.md"
  hstep handoff.sh 7 HO_FAIL_VIEW=1; check 1 "a failed read of the comments fails the step" $?
  eq "" "…without claiming the breakdown is missing" "$(hcalls)"

  # ── ADR + breakdown ⇒ hand off ──
  runner; echo adr > "$HO/run/docs/adr/0002-login.md"; echo more > "$HO/run/docs/guide.md"; echo stray > "$HO/run/src/api/b.py"
  says 'Q: which roles?\n## Task breakdown\n- T1 …\n\nADLC-BREAKDOWN: `docs/adr/0002-login.md`\r\n'
  hstep handoff.sh 7; check 0 "ADR + breakdown: the handoff succeeds (the commit names its own identity)" $?
  eq ".adlc/scope/7.txt|.adlc/scripts/adlc-diff-scope.sh|.adlc/scripts/adlc-relabel.sh|docs/adr/0001-adopt.md|docs/adr/0002-login.md|docs/adr/template.md|docs/guide.md|src/api/a.py|" \
     "the design branch holds the docs and the scope file, not the stray file" "$(otree adlc/design-7)"
  eq "docs/adr/0002-login.md|docs/guide.md|" "the scope file lists exactly the design files it committed" "$(oscope 7)"
  eq "adlc-design <adlc-design@users.noreply.github.com>" "the commit is the design lane's" "$(hgit -C "$HO/origin.git" log -1 --format='%an <%ae>' adlc/design-7 2>/dev/null)"
  eq "comment 7 --body 📐 Design handed|edit 7 --remove-label stage:design --add-label stage:build|" "the issue advances, after the push, in one edit through the relabel script" "$(hcalls)"
  eq "$main0" "main is untouched" "$(oref main)"

  # ── the Builder starts from it ──
  runner; hstep start.sh 7; check 0 "builder: the start step runs" $?
  eq "adlc/design-7" "builder: starts on the design branch" "$(hgit -C "$HO/run" symbolic-ref --short HEAD 2>/dev/null)"
  [ -f "$HO/run/docs/adr/0002-login.md" ] && ok "builder: the ADR is in its checkout" || bad "builder: the ADR is in its checkout"
  # the Builder's PR, as the diff-scope check sees it: the ADR + the scope file + its own change
  bcommit() { ( cd "$HO/run" && hgit add -A && hgit -c user.name=t -c user.email=t@example.com commit -qm "$1" ) >/dev/null 2>&1; }
  # (-z: raw names, as the pull-request files API gives them to the real check)
  bscope()  { ( cd "$HO/run" && hgit diff --name-only --no-renames -z origin/main...HEAD | tr '\0' '\n' | bash .adlc/scripts/adlc-diff-scope.sh build ".adlc/scope/$1.txt" ) >/dev/null 2>&1; }
  ( cd "$HO/run" && hgit checkout -q -b feat/7-login && echo y > src/api/b.py && echo src/api/ >> .adlc/scope/7.txt ) >/dev/null 2>&1; bcommit build
  bscope 7; check 0 "builder PR: the ADR it carries is in the declared scope" $?
  echo src/api/ > "$HO/run/.adlc/scope/7.txt"; bcommit overwrite
  bscope 7; check 1 "builder PR: a scope file that drops the design lines fails the check (loud, not silent)" $?
  runner; hstep start.sh 8; check 0 "builder: no design branch for the issue → the step still passes" $?
  eq "main" "builder: …and builds on the default branch" "$(hgit -C "$HO/run" symbolic-ref --short HEAD 2>/dev/null)"
  runner; hgit -C "$HO/run" remote set-url origin "$HO/nowhere.git"
  hstep start.sh 7; check 1 "builder: an unreachable origin fails the step (it is not 'no design branch')" $?

  # ── odd names, a moved doc ──
  runner; odd='docs/adr/0003-café "new" login.md'; echo adr > "$HO/run/$odd"
  ( cd "$HO/run" && mv docs/guide.md docs/handbook.md )
  says 'ADLC-BREAKDOWN: docs/adr/0003-café "new" login.md\n'
  hstep handoff.sh 9; check 0 "an ADR name with a space, a quote and a non-ASCII letter hands off" $?
  eq "$odd|docs/guide.md|docs/handbook.md|" "its scope file holds the raw names, and a moved doc under both paths" "$(oscope 9)"
  runner; hstep start.sh 9
  ( cd "$HO/run" && hgit checkout -q -b feat/9-x && echo y > src/api/c.py && echo src/api/ >> .adlc/scope/9.txt ) >/dev/null 2>&1; bcommit build
  bscope 9; check 0 "…and the Builder's PR passes the scope check with them" $?

  # ── re-runs and failures ──
  runner; echo adr2 > "$HO/run/docs/adr/0004-roles.md"; says 'ADLC-BREAKDOWN: docs/adr/0004-roles.md\n'
  hstep handoff.sh 7; check 0 "a re-run of the design lane hands off again" $?
  case "$(otree adlc/design-7)" in *0002-login*) bad "a re-run replaces the design branch" ;; *0004-roles*) ok "a re-run replaces the design branch" ;; *) bad "a re-run replaces the design branch (branch missing)" ;; esac
  runner; echo adr > "$HO/run/docs/adr/0005-x.md"; says 'ADLC-BREAKDOWN: docs/adr/0005-x.md\n'
  hgit -C "$HO/run" remote set-url origin "$HO/nowhere.git"
  hstep handoff.sh 11; rc=$?
  [ "$rc" -ne 0 ] && ok "a failed push fails the step" || bad "a failed push fails the step"
  eq "" "…before any comment or label change" "$(hcalls)"
  rm -rf "$HO"
else
  bad "handoff step tests need git"
fi

echo "lanes (each template runs its agent with the plugin + tools):"
T="$ROOT/templates/github"
for f in "$T"/adlc-*.yml; do
  body=$(grep -vE '^[[:space:]]*#' "$f")
  n=$(printf '%s\n' "$body" | grep -cE 'uses:[[:space:]]*anthropics/claude-code-action' || true)
  [ "$n" -gt 0 ] || continue
  b=$(basename "$f")
  count() { printf '%s\n' "$body" | grep -cE -- "$1" || true; }
  eq "$n" "$b: installs the plugin"        "$(count '^[[:space:]]*plugins:[[:space:]]*"adlc@')"
  eq "$n" "$b: names the marketplace"      "$(count '^[[:space:]]*plugin_marketplaces:[[:space:]]*"https://.*\.git"')"
  eq "$n" "$b: grants tools"               "$(count '--allowedTools "')"
  eq "$n" "$b: denies everything else"     "$(count '--permission-mode dontAsk')"
  eq "$n" "$b: lists the dispatch bot"     "$(count '^[[:space:]]*allowed_bots:')"
  eq "$n" "$b: runs a named agent or skill" "$(count '--agent adlc:[a-z-]+$|prompt: "/adlc:[a-z-]+"')"
done
# WHAT each lane may do is the security boundary of the unattended pipeline, so it is pinned
# here: widening a grant, or running a lane as another agent, has to change this table too.
grants() { # <template> → "<agent>=<tools>;" per agent step, in file order ("-" = no --agent)
  awk '
    /^[ \t]*#/ { next }
    /uses:[ \t]*anthropics\/claude-code-action/ { if (seen) printf "%s=%s;", agent, tools; seen = 1; agent = "-"; tools = "" }
    seen && /^[ \t]*--agent / { agent = $2 }
    seen && /^[ \t]*--allowedTools / { t = $0; sub(/^[^"]*"/, "", t); sub(/".*$/, "", t); tools = t }
    END { if (seen) printf "%s=%s;", agent, tools }' "$T/$1"
}
FULL='Read,Edit,Write,Skill,Bash'
GITRO='Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)'
REVIEW="Skill,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh pr list:*),Bash(gh pr checks:*),Bash(gh issue view:*),$GITRO"
eq "adlc:product-analyst=Skill,Bash(gh issue view:*),Bash(gh issue comment:*),Bash(gh issue edit:*),Bash(gh issue list:*),Bash(gh label list:*),Bash(gh search:*),Bash(.adlc/scripts/adlc-triage.sh:*),Bash(.adlc/scripts/adlc-relabel.sh:*);" \
   "intake: the Analyst, named gh commands, no edit tools" "$(grants adlc-intake.yml)"
eq "adlc:architect=Edit(docs/**),Skill,Bash(gh issue view:*),Bash(gh issue comment:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr list:*),Bash(gh pr diff:*),$GITRO;" \
   "design: the Architect, edits under docs/ only, no commit/push/label" "$(grants adlc-design.yml)"
eq "adlc:adversarial-reviewer=$REVIEW;adlc:architect=$REVIEW;" "review: both reviewers read and comment only" "$(grants adlc-review.yml)"
eq "adlc:builder=$FULL;adlc:adversarial-reviewer=$REVIEW;"      "fast: the Builder builds, the reviewer reads and comments" "$(grants adlc-fast.yml)"
eq "adlc:builder=$FULL;"         "builder: the Builder"  "$(grants adlc-builder.yml)"
eq "adlc:builder=$FULL;"         "fix: the Builder"      "$(grants adlc-fix.yml)"
eq "adlc:qa-release-ops=$FULL;"  "qa: QA"                "$(grants adlc-qa.yml)"
eq "-=$FULL;-=$FULL;"            "retro: the /adlc:retro and /adlc:cycle-retro skills, two steps, no agent" "$(grants adlc-retro.yml)"
eq 2 "retro: each step names its skill once" "$(grep -c '^          prompt: "/adlc:\(cycle-\)\?retro"$' "$ROOT/templates/github/adlc-retro.yml")"
eq "retro cycle-retro" "retro: a checkout reset (default branch, clean) sits between the two proposals, so the second does not carry the first's branch or ledgers" \
   "$(awk '/prompt: "\/adlc:retro"/{a=1} a && /git checkout -q -f .*default_branch/{b=1} b && /git clean -fdq/{c=1} c && /prompt: "\/adlc:cycle-retro"/{print "retro cycle-retro"; exit}' "$ROOT/templates/github/adlc-retro.yml")"
eq 0 "retro: the second proposal does not run on a cancelled job" "$(grep -c 'if: always()' "$ROOT/templates/github/adlc-retro.yml")"
for f in "$T"/adlc-*.yml; do   # no template this table does not know about
  case "$(basename "$f")" in adlc-intake.yml|adlc-design.yml|adlc-review.yml|adlc-fast.yml|adlc-builder.yml|adlc-fix.yml|adlc-qa.yml|adlc-retro.yml) ;;
    *) eq "" "$(basename "$f"): runs no agent (or add it to the grants table)" "$(grants "$(basename "$f")")" ;; esac
done
for a in $(grep -hoE -- '--agent adlc:[a-z-]+' "$T"/adlc-*.yml | sed 's/.*adlc://' | sort -u); do
  [ -f "$ROOT/agents/$a.md" ] && ok "lane agent exists: $a" || bad "lane names a missing agent: $a"
done
# A `skills:` preload happens only for subagents. A lane runs its agent with --agent, so the role
# prompt reaches the model only through a Skill call the prompt asks for: each agent step's prompt
# must name that step's own role skill (adlc:role-<agent>), and no other role's.
role_calls() { # <template> → "<agent>=<role skill named in its prompt>;" per mention, in file order
  awk '/^[ \t]*#/ { next }
       /^[ \t]*--agent adlc:/ { cur = $2; sub(/^adlc:/, "", cur) }
       match($0, /adlc:role-[a-z-]+/) { printf "%s=%s;", cur, substr($0, RSTART + 10, RLENGTH - 10) }' "$T/$1"
}
for f in "$T"/adlc-*.yml; do
  b=$(basename "$f")
  agents=$(grants "$b" | tr ';' '\n' | sed -n 's/=.*//p' | grep -v '^-$' | sed 's/^adlc://')
  [ -n "$agents" ] || continue
  eq "$(printf '%s\n' $agents | awk '{ printf "%s=%s;", $1, $1 }')" "$b: each agent step's prompt names its own role skill to load first" "$(role_calls "$b")"
done
# `tools:` takes tool NAMES. A command specifier there is ignored and grants the whole tool.
for f in "$ROOT"/agents/*.md; do
  case "$(grep -m1 '^tools:' "$f")" in
    *"("*) bad "$(basename "$f"): tools: has a command specifier" ;;
    *Skill*) ok "$(basename "$f"): tools: are plain names, Skill included" ;;
    *) bad "$(basename "$f"): tools: lacks Skill (the agent could not load its skills)" ;;
  esac
done

echo "agents (thin wrappers over role skills · vendored copies · the RUNBOOK · /adlc-model):"
# Each agent is a wrapper: frontmatter (tools, model, the skills to preload) and a few lines of
# body. The role prompt is the plugin skill adlc:role-<role>, so the plugin's agent and the
# copy /adlc-init writes into a repo (templates/agents/, name adlc-<role>, model from the wizard)
# can share it. A `skills:` preload happens only for subagents, so the body must name the role
# skill for a --agent session to load it with the Skill tool.
ROLES="product-analyst architect builder adversarial-reviewer qa-release-ops"
fm()   { awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f' "$1"; }   # the frontmatter's lines
body() { awk 'f==2{print} $0=="---"{f++}' "$1"; }                               # everything after it
eq "$(printf '%s\n' $ROLES | sort | tr '\n' ' ')" "exactly the five agents" "$(ls "$ROOT"/agents/*.md | xargs -n1 basename | sed 's/\.md$//' | sort | tr '\n' ' ')"
for a in $ROLES; do
  f="$ROOT/agents/$a.md"; F="$(fm "$f")"; sk="$ROOT/skills/role-$a/SKILL.md"
  for k in name description tools model skills; do printf '%s\n' "$F" | grep -q "^$k:" || bad "agents/$a.md: no $k: in the frontmatter"; done
  eq "$a" "agents/$a.md: name is the role" "$(printf '%s\n' "$F" | sed -n 's/^name: *//p')"
  printf '%s\n' "$F" | grep -qx "  - adlc:role-$a" && ok "agents/$a.md preloads adlc:role-$a" || bad "agents/$a.md: skills: must list adlc:role-$a"
  [ -f "$sk" ] && ok "skills/role-$a/SKILL.md exists" || { bad "skills/role-$a/SKILL.md missing"; continue; }
  eq "role-$a" "role-$a: the skill's name" "$(fm "$sk" | sed -n 's/^name: *//p')"
  grep -qE '^disable-model-invocation: *true' "$sk" && bad "role-$a: disable-model-invocation would stop the Skill load" || ok "role-$a: the model may load it"
  n=$(body "$f" | grep -c .); [ "$n" -le 12 ] && ok "agents/$a.md is a thin wrapper ($n body lines)" || bad "agents/$a.md: $n body lines — the role prompt belongs in skills/role-$a/"
  body "$f" | grep -q "\`adlc:role-$a\` first" && ok "…whose body says to load the role skill first (a --agent session gets no preload)" || bad "agents/$a.md: the body must say to load \`adlc:role-$a\` first"
  body "$f" | grep -q 'Skill tool' && : || bad "agents/$a.md: the body must say to load the skills with the Skill tool under --agent"
  # the body's prose list is what a --agent session loads: every preloaded skill must be in it
  for sk in $(printf '%s\n' "$F" | sed -n 's/^  - //p'); do body "$f" | grep -q "\`$sk\`" || bad "agents/$a.md: the body does not name the preloaded skill $sk"; done
  A=$(printf '%s' "$a" | tr 'a-z-' 'A-Z_'); t="$ROOT/templates/agents/adlc-$a.md.tmpl"
  [ -f "$t" ] || { bad "templates/agents/adlc-$a.md.tmpl missing"; continue; }
  sed -e "s/^name: $a\$/name: adlc-$a/" -e "s/^model: .*/model: {{${A}_MODEL}}/" "$f" | diff -q - "$t" >/dev/null \
    && ok "adlc-$a.md.tmpl is the wrapper with name adlc-$a and model {{${A}_MODEL}}" || bad "templates/agents/adlc-$a.md.tmpl drifted from agents/$a.md (regenerate it)"
done
# the charter: every role but the reviewer, which stays fresh-context (the diff + the criteria only)
for a in $ROLES; do
  has=$(grep -cx '  - adlc:charter' "$ROOT/agents/$a.md")
  case "$a" in adversarial-reviewer) eq 0 "the reviewer preloads no charter (fresh context)" "$has" ;; *) eq 1 "$a preloads adlc:charter" "$has" ;; esac
done
# the placeholders in templates/agents are exactly the ones the wizard fills, one per role
want=$(for a in $ROLES; do printf '{{%s_MODEL}}\n' "$(printf '%s' "$a" | tr 'a-z-' 'A-Z_')"; done | sort)
eq "$want" "templates/agents: one {{<ROLE>_MODEL}} placeholder per role, nothing else" "$(grep -ohE '\{\{[A-Z_]+\}\}' "$ROOT"/templates/agents/*.tmpl | sort -u)"
eq "$want" "bootstrap names every one of them" "$(grep -oE '\{\{[A-Z_]+_MODEL\}\}' "$ROOT/skills/bootstrap/SKILL.md" | sort -u)"
eq 5 "templates/agents holds the five copies and no other file" "$(ls "$ROOT"/templates/agents | wc -l | tr -d ' ')"
grep -q 'templates/agents/adlc-<role>.md.tmpl' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap copies them" || bad "bootstrap: must copy templates/agents/adlc-<role>.md.tmpl"
grep -q 'Model per agent' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap asks for the model per agent" || bad "bootstrap: must ask for the model per agent"
for m in "\`opus\` for the Analyst" "\`fable\` for the Builder"; do grep -q "$m" "$ROOT/skills/bootstrap/SKILL.md" || bad "bootstrap: the pre-filled default is not today's ($m)"; done
eq "opus opus fable fable opus" "…and those defaults are the plugin agents' models" \
   "$(for a in $ROLES; do sed -n 's/^model: *//p' "$ROOT/agents/$a.md"; done | tr '\n' ' ' | sed 's/ $//')"
# the RUNBOOK invokes the copies only, and says where each model lives
RB="$ROOT/templates/RUNBOOK.md.tmpl"
eq "" "RUNBOOK invokes no agent by a bare or plugin name" "$(grep -oE 'Invoke the \*\*[a-z:-]+\*\*' "$RB" | grep -vE '^Invoke the \*\*adlc-(product-analyst|architect|builder|adversarial-reviewer|qa-release-ops)\*\*$')"
eq "$(grep -c 'Invoke the \*\*' "$RB")" "RUNBOOK: every invoke line names one of the five copies" "$(grep -cE 'Invoke the \*\*adlc-(product-analyst|architect|builder|adversarial-reviewer|qa-release-ops)\*\* ' "$RB")"
for a in $ROLES; do grep -q "adlc-$a\.md" "$RB" && ok "RUNBOOK says where adlc-$a's model is" || bad "RUNBOOK must name .claude/agents/adlc-$a.md"; done
grep -q '/adlc-model' "$RB" && ok "RUNBOOK points at /adlc-model" || bad "RUNBOOK: must point at /adlc-model"
# Gate 2 (issue 40): two PRs each green on their own head made main red; the Principal checks for BEHIND first
# mergeStateStatus says BEHIND only where the up-to-date rule is on (a behind PR on a Free-plan private repo reads CLEAN/UNSTABLE), so the recipe asks the compare API
grep -q 'gh api "repos/{owner}/{repo}/compare/$(gh pr view <n> --json baseRefName,headRefName' "$RB" && ok "RUNBOOK Gate 2 asks the compare API how far behind the PR is, before the merge" || bad "RUNBOOK Gate 2 must ask the compare API (behind_by)"
grep -q -- '--jq .behind_by' "$RB" && ok "…reading behind_by" || bad "RUNBOOK Gate 2 must read behind_by"
grep -qE 'On `BEHIND`' "$RB" && bad "RUNBOOK Gate 2 must not key on mergeStateStatus BEHIND" || ok "…and does not key on mergeStateStatus BEHIND"
grep -q 'wait for the checks to go green on the' "$RB" && ok "…and waits for green checks on the new head" || bad "RUNBOOK Gate 2 must wait for the checks after merging the base"
grep -q '^Base: ' "$ROOT/templates/skills/release-ops.SKILL.md.tmpl" && ok "Action Card records the base the battery ran against" || bad "release-ops card needs a Base: line"
grep -q 'adlc-relabel.sh <n> gate:deploy' "$RB" && ok "RUNBOOK fast lane moves the issue to gate:deploy with the relabel script (one state)" || bad "RUNBOOK fast lane must move the issue to gate:deploy with adlc-relabel.sh"
grep -q -- '--remove-label stage:\|--add-label stage:\|--add-label gate:' "$RB" && bad "RUNBOOK must not spell out a state-label pair (adlc-relabel.sh does it)" || ok "RUNBOOK spells out no state-label pair"
for f in "$ROOT"/templates/github/adlc-*.yml; do
  hits=$(grep -nE 'gh issue edit .*--(add|remove)-label (stage|gate):' "$f" || true)
  eq "" "$(basename "$f"): moves state labels through adlc-relabel.sh, never a hand-spelled pair" "$hits"
done
# the prose an agent reads counts too: "add gate:deploy" in the QA prompt was the wording behind the 25 double-labelled issues
for f in "$ROOT"/templates/github/adlc-*.yml "$RB"; do
  hits=$(grep -nE '\badds? `?(stage|gate):[a-z]+' "$f" || true)
  eq "" "$(basename "$f"): no prompt or step tells anyone to \"add\" a state label" "$hits"
done
# /adlc-model
CM="$ROOT/commands/adlc-model.md"
[ -f "$CM" ] && ok "commands/adlc-model.md exists" || bad "commands/adlc-model.md missing"
for a in $ROLES; do grep -q "\`$a\`" "$CM" || bad "/adlc-model: does not name the $a role"; done
grep -q '\$ARGUMENTS' "$CM" && ok "/adlc-model takes arguments" || bad "/adlc-model: must take \$ARGUMENTS"
grep -q 'adlc:<role>' "$CM" && ok "/adlc-model says the plugin's agents keep their defaults" || bad "/adlc-model: must say the plugin's adlc:<role> agents keep their defaults"
grep -q 'still wins' "$CM" && ok "/adlc-model says a model named in the call still wins" || bad "/adlc-model: must say a per-call model still wins"
grep -q 'Commit nothing' "$CM" && ok "/adlc-model commits nothing" || bad "/adlc-model: must commit nothing"
# the lanes keep running the plugin's agents (the copies are the local recipe's)
eq "" "no lane runs a repo copy" "$(grep -hoE -- '--agent adlc-[a-z-]+' "$ROOT"/templates/github/adlc-*.yml)"
# the guard's docstring and the reporter name both spellings
grep -q 'adlc-<role>' "$ROOT/hooks/adlc_guard.py" && ok "the guard documents the adlc-<role> spelling" || bad "adlc_guard.py: document the vendored copies' name"
grep -q 'adlc\[:-\]' "$ROOT/mission-control/hook.sh" && ok "Mission Control's reporter forwards adlc-<role> events" || bad "mission-control/hook.sh: must match adlc-<role> too"
# a session starting is sent too: that is how a repo gets on the page's menu before any agent runs in it
grep -q '"SessionStart"' "$ROOT/mission-control/hook.sh" && ok "Mission Control's reporter forwards a session starting" || bad "mission-control/hook.sh: must forward SessionStart"
python3 -c 'import json,sys; assert "SessionStart" in json.load(open(sys.argv[1]))["hooks"]' "$ROOT/hooks/hooks.json" 2>/dev/null \
  && ok "hooks.json fires the reporter on SessionStart" || bad "hooks.json: the reporter must run on SessionStart"
# Mission Control decides "adopted" by the guard's rule. Run the two side by side over the same folders: a grep for
# the marker names would pass on the guard's comment alone.
if command -v python3 >/dev/null 2>&1; then
  AD="$(mktemp -d)"
  mkdir -p "$AD/plain/src" "$AD/bare/.adlc" "$AD/scripts/.adlc/scripts" "$AD/scripts/src/api" "$AD/version/.adlc" "$AD/version/a/b" \
           "$AD/charter/docs/adlc" "$AD/charter/docs/x" "$AD/wrongtype/.adlc/VERSION" "$AD/wrongtype2/.adlc" "$AD/wrongtype3/docs/adlc/CHARTER.md" \
           "$AD/scripts/vendor/nested/src"
  : > "$AD/version/.adlc/VERSION"; : > "$AD/charter/docs/adlc/CHARTER.md"; : > "$AD/wrongtype2/.adlc/scripts"
  eval "$(sed -n '/^adopted() {/,/^}/p' "$ROOT/hooks/adlc-guard.sh")"
  mc_adopted() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from mc import ingest; sys.exit(0 if ingest.adopted(sys.argv[2]) else 1)' "$ROOT/mission-control" "$1"; }
  for case in plain:1 plain/src:1 bare:1 scripts:0 scripts/src/api:0 scripts/vendor/nested/src:0 version:0 version/a/b:0 charter:0 charter/docs/x:0 \
              wrongtype:1 wrongtype2:1 wrongtype3:1 missing/dir:1; do
    d="$AD/${case%:*}"; want="${case#*:}"
    adopted "$d"; g=$?; mc_adopted "$d"; m=$?
    [ "$g" = "$want" ] && [ "$m" = "$want" ] && ok "adopted, guard and Mission Control alike: ${case%:*} → $want" \
      || bad "adopted(${case%:*}): want $want, the guard says $g, Mission Control says $m"
  done
  unset -f adopted mc_adopted; rm -rf "$AD"
else
  echo "  · skipped the guard / Mission Control adopted() comparison (needs python3)"
fi

echo "guard hook (merge / push-to-main / force-push / role limits):"
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  H="$ROOT/hooks/adlc-guard.sh"
  # hooks.json is shared with Mission Control's reporter: find the guard by what it is (the
  # Bash matcher + its command), not by its position, and check neither feature lost its wiring.
  guard_cmd() { python3 -c 'import json,sys
found = [h["command"] for e in json.load(open(sys.argv[1]))["hooks"]["PreToolUse"] if e.get("matcher") == "Bash"
         for h in e["hooks"] if "hooks/adlc-guard.sh" in h["command"]]
assert len(found) == 1, found
print(found[0])' "$ROOT/hooks/hooks.json" 2>/dev/null; }
  [ -n "$(guard_cmd)" ] && ok "hooks.json wires the guard to Bash, once" || bad "hooks.json wires the guard to Bash, once"
  python3 -c 'import json,sys
hooks = json.load(open(sys.argv[1]))["hooks"]
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]
for ev in events:
    assert any("mission-control/hook.sh" in h["command"] and "matcher" not in e for e in hooks[ev] for h in e["hooks"]), ev' "$ROOT/hooks/hooks.json" 2>/dev/null \
    && ok "…and Mission Control's reporter is still on all nine events" || bad "hooks.json lost Mission Control's reporter on some event"
  GR="$(mktemp -d)"; GIT="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false"
  git init -q --bare -b main "$GR/origin.git"
  git init -q -b main "$GR/feat" && ( cd "$GR/feat" && echo x > f && mkdir src && echo y > src/a && git add -A && $GIT commit -qm init \
    && git remote add origin "$GR/origin.git" && git push -q -u origin main && git checkout -q -b feat/1-x ) >/dev/null 2>&1
  git clone -q "$GR/origin.git" "$GR/onmain" >/dev/null 2>&1
  git clone -q "$GR/origin.git" "$GR/track" >/dev/null 2>&1 && ( cd "$GR/track" && git checkout -q -b topic origin/main ) >/dev/null 2>&1
  git init -q --bare -b trunk "$GR/origin2.git"
  git init -q -b trunk "$GR/t0" && ( cd "$GR/t0" && echo x > f && git add f && $GIT commit -qm init \
    && git remote add origin "$GR/origin2.git" && git push -q -u origin trunk ) >/dev/null 2>&1
  git clone -q "$GR/origin2.git" "$GR/trunk" >/dev/null 2>&1 && ( cd "$GR/trunk" && git checkout -q -b feat/x ) >/dev/null 2>&1
  git clone -q "$GR/origin.git" "$GR/matching" >/dev/null 2>&1 && ( cd "$GR/matching" && git checkout -q -b feat/2-y && git config push.default matching ) >/dev/null 2>&1
  hook_json() { # hook_json <role|-> <cwd> <command>  → the PreToolUse input the harness sends
    python3 -c 'import json,sys
d={"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[3]}}
if sys.argv[1]!="-": d["agent_type"]=sys.argv[1]
print(json.dumps(d))' "$@"
  }
  g() { # g <A|D> <role|-> <repo> <command>
    local got rc
    hook_json "$2" "$GR/$3" "$4" | GITHUB_ACTIONS=true bash "$H" >/dev/null 2>&1; rc=$?
    case $rc in 0) got=A ;; 2) got=D ;; *) got="exit-$rc" ;; esac
    [ "$got" = "$1" ] && pass=$((pass+1)) || bad "guard [$2] want $1 got $got: $(printf '%s' "$4" | head -1)"
  }
  # the cases mean nothing unless each fixture really is where its name says
  eq feat/1-x     "fixture feat is on its feature branch"  "$(git -C "$GR/feat" symbolic-ref --short HEAD 2>/dev/null)"
  eq main         "fixture onmain is on main"              "$(git -C "$GR/onmain" symbolic-ref --short HEAD 2>/dev/null)"
  eq origin/main  "fixture track follows origin/main"      "$(git -C "$GR/track" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
  eq origin/trunk "fixture trunk's default branch is trunk" "$(git -C "$GR/trunk" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  eq matching     "fixture matching pushes every matching branch" "$(git -C "$GR/matching" config push.default 2>/dev/null)"
  before=$pass; before_fail=$fail
  . "$ROOT/tests/guard-cases.sh"
  [ "$fail" -eq "$before_fail" ] && printf '  ✓ %s command cases (see tests/guard-cases.sh)\n' "$((pass-before))"
  # scope: a no-op outside CI unless the repo adopted ADLC — a marker only /adlc-init writes
  # (.adlc/scripts/, .adlc/VERSION, docs/adlc/CHARTER.md) at or above the project dir; a bare
  # .adlc/ directory is not one, since Mission Control keeps its state in ~/.adlc/mission-control
  # and the walk-up reaches the home directory. Fails CLOSED without python3.
  # Run from a directory that is NOT an ADLC repo, with the CI marker unset, so the result
  # does not depend on where (or under which runner) this suite itself runs.
  M="$(hook_json - "$GR/feat" 'gh pr merge 5')"
  mkdir -p "$GR/adopted/.adlc/scripts" "$GR/adopted/sub/dir" "$GR/chartered/docs/adlc" "$GR/versioned/.adlc" "$GR/bare/.adlc" \
           "$GR/home/.adlc/mission-control" "$GR/home/plain" "$GR/plain" "$GR/fakepy" "$GR/plug in/hooks"
  : > "$GR/chartered/docs/adlc/CHARTER.md"; echo 0.3.0 > "$GR/versioned/.adlc/VERSION"
  local_hook() { # <project dir | -> [ENV=val …] — the launcher as a local session runs it, from $GR/plain
    local proj="$1"; shift
    if [ "$proj" = - ]; then ( cd "$GR/plain" && printf '%s' "$M" | env -u GITHUB_ACTIONS -u CLAUDE_PROJECT_DIR "$@" bash "$H" ) >/dev/null 2>&1
    else ( cd "$GR/plain" && printf '%s' "$M" | env -u GITHUB_ACTIONS CLAUDE_PROJECT_DIR="$proj" "$@" bash "$H" ) >/dev/null 2>&1; fi
  }
  local_hook "$GR/plain";            check 0 "no-op in a repo that has not adopted ADLC" $?
  local_hook -;                      check 0 "…also with no project dir at all" $?
  local_hook "$GR/home/plain";       check 0 "…and under a home directory that holds .adlc/mission-control (Mission Control's state)" $?
  local_hook "$GR/bare";             check 0 "…and where a bare .adlc/ directory is the only candidate marker" $?
  local_hook "$GR/adopted";          check 2 "active locally when .adlc/scripts/ exists" $?
  local_hook "$GR/adopted/sub/dir";  check 2 "active from a subdirectory of an ADLC repo" $?
  local_hook "$GR/versioned";        check 2 "active locally when .adlc/VERSION exists" $?
  local_hook "$GR/chartered";        check 2 "active locally when only docs/adlc/CHARTER.md exists (an adopter older than 0.2.0)" $?
  ( cd "$GR/adopted/sub/dir" && printf '%s' "$M" | env -u GITHUB_ACTIONS CLAUDE_PROJECT_DIR="$GR/plain" bash "$H" ) >/dev/null 2>&1
  check 2 "active when the session has moved INTO an ADLC repo (its project dir is elsewhere)" $?
  printf '%s' "$M" | env -i GITHUB_ACTIONS=true PATH=/nonexistent /bin/bash "$H" >/dev/null 2>&1;               check 2 "fails closed in scope when python3 is missing" $?
  ( cd "$GR/plain" && printf '%s' "$M" | env -i PATH=/nonexistent CLAUDE_PROJECT_DIR="$GR/plain" /bin/bash "$H" ) >/dev/null 2>&1; check 0 "stays a no-op out of scope when python3 is missing" $?
  printf '#!/bin/sh\nexit 1\n' > "$GR/fakepy/python3"; chmod +x "$GR/fakepy/python3"
  printf '%s' "$M" | GITHUB_ACTIONS=true PATH="$GR/fakepy:$PATH" bash "$H" >/dev/null 2>&1;                    check 2 "fails closed when python3 itself fails (exit 1 would let the command run)" $?
  printf '#!/bin/sh\nexit 0\n' > "$GR/fakepy/python3"
  printf '%s' "$M" | GITHUB_ACTIONS=true PATH="$GR/fakepy:$PATH" bash "$H" >/dev/null 2>&1;                    check 0 "…and passes on only when the guard says so (exit 0)" $?
  printf 'not json' | GITHUB_ACTIONS=true bash "$H" >/dev/null 2>&1;                                           check 2 "fails closed on unreadable hook input" $?
  printf '{"tool_name":"Write","tool_input":{"content":"gh pr merge 5"}}' | GITHUB_ACTIONS=true bash "$H" >/dev/null 2>&1; check 0 "ignores tools other than Bash" $?
  # the command hooks.json really registers, run the way the harness runs it — from a plugin
  # directory whose path has a space in it
  cp "$ROOT/hooks/adlc-guard.sh" "$ROOT/hooks/adlc_guard.py" "$GR/plug in/hooks/"
  HC="$(guard_cmd)"
  printf '%s' "$M" | GITHUB_ACTIONS=true CLAUDE_PLUGIN_ROOT="$GR/plug in" CLAUDE_PROJECT_DIR="$GR/feat" bash -c "$HC" >/dev/null 2>&1; check 2 "the hooks.json command blocks a merge (plugin path with a space)" $?
  printf '%s' "$(hook_json - "$GR/feat" 'git status')" | GITHUB_ACTIONS=true CLAUDE_PLUGIN_ROOT="$GR/plug in" CLAUDE_PROJECT_DIR="$GR/feat" bash -c "$HC" >/dev/null 2>&1; check 0 "…and lets an ordinary command through" $?
  hook_json - "$GR/feat" 'git push origin release' | GITHUB_ACTIONS=true ADLC_PROTECTED_BRANCHES="release, staging" bash "$H" >/dev/null 2>&1; check 2 "ADLC_PROTECTED_BRANCHES adds protected names" $?
  eq "ADLC guard: blocked" "tells the agent why" "$(printf '%s' "$M" | GITHUB_ACTIONS=true bash "$H" 2>&1 >/dev/null | cut -c1-19)"
  eq 1 "…and, for a program named by a variable, how to get past a wrong guess" \
     "$(hook_json - "$GR/onmain" '"$DOCKER" push image:tag' | GITHUB_ACTIONS=true bash "$H" 2>&1 >/dev/null | grep -c 'write its name out')"
  rm -rf "$GR"
else
  bad "guard tests need python3 and git"
fi

echo "adlc-run-log.sh + adlc-cycle.sh (the cycle-retro's ledgers):"
# Every figure the cycle-retro ranks must come from a record no agent wrote about itself: Mission
# Control's store (OTel api_request events), the collector's OTLP file, Actions run durations, and
# the issue label timeline. Fixtures stand in for each; the scripts run as shipped.
if command -v jq >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1; then
  CY="$(mktemp -d)"; mkdir -p "$CY/bin" "$CY/repo/.adlc/metrics" "$CY/fx"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # --- otel: session A = adlc:builder (2 events, 60 s apart), session B = 'custom' (unnamed), one non-api record,
  #     session C = adlc-builder (a repo's copy of the plugin agent reports by its file name)
  otlp() { # <session> <agent> <ts-seconds> <input> <output> <cache_read> <cache_creation> <cost> [event]
    jq -cn --arg s "$1" --arg a "$2" --arg t "$3" --argjson i "$4" --argjson o "$5" --argjson r "$6" --argjson w "$7" --arg c "$8" --arg e "${9:-claude_code.api_request}" '
      {resourceLogs: [{resource: {attributes: [{key: "service.name", value: {stringValue: "adlc"}}]},
        scopeLogs: [{logRecords: [{timeUnixNano: (($t | tonumber) * 1000000000 | tostring), body: {stringValue: $e},
          attributes: [{key: "event.name", value: {stringValue: $e}}, {key: "session.id", value: {stringValue: $s}},
                       {key: "agent.name", value: {stringValue: $a}}, {key: "model", value: {stringValue: "claude-x"}},
                       {key: "input_tokens", value: {intValue: ($i | tostring)}}, {key: "output_tokens", value: {intValue: ($o | tostring)}},
                       {key: "cache_read_tokens", value: {intValue: ($r | tostring)}}, {key: "cache_creation_tokens", value: {intValue: ($w | tostring)}},
                       {key: "cost_usd", value: {doubleValue: ($c | tonumber)}}, {key: "duration_ms", value: {doubleValue: 1500}}]}]}]}]}'
  }
  e0=$(( $(date -u +%s) - 7200 ))
  { otlp A adlc:builder "$e0"           10 5 90 0 0.10
    otlp A adlc:builder "$((e0 + 60))"  10 5 90 20 0.10
    otlp B custom       "$e0"           50 1  0  0 0.05
    otlp C adlc-builder "$e0"           10 5  0  0 0.01
    otlp A adlc:builder "$((e0 + 30))"  99 99 99 99 9 claude_code.tool_result; } > "$CY/fx/telemetry.jsonl"
  OUT=$( cd "$CY/repo" && ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" otel "$CY/fx/telemetry.jsonl" 2>&1 ); check 0 "otel: runs to the end" $?
  eq 3 "otel: one row per session+agent (the tool_result record is not a run)" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
  eq "builder builder C:adlc-builder" "otel: a repo's adlc-builder copy is the builder stage too" "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "C:adlc-builder") | "\(.stage) \(.agent) \(.run_id)"')"
  B=$(printf '%s\n' "$OUT" | jq -c 'select(.run_id == "A:adlc:builder")')
  eq "builder 60 20 10 180 20 230 81.8 0.2 claude-x acme/shop" "otel: builder row sums its events; seconds = event span; cached% = read/(input+read+write)" \
     "$(printf '%s' "$B" | jq -r '"\(.stage) \(.seconds) \(.input) \(.output) \(.cache_read) \(.cache_creation) \(.tokens) \(.cache_read_pct) \(.cost_usd) \(.model) \(.repo)"')"
  eq "unknown null" "otel: an unnamed ('custom') agent is kept as unknown, with no stage" "$(printf '%s\n' "$OUT" | jq -r 'select(.agent == "unknown") | "\(.agent) \(.stage)"')"
  # --- mc: Mission Control's schema, two runs of this repo (+ one of another repo, one with no station)
  DB="$CY/mc.sqlite"
  sqlite3 "$DB" "CREATE TABLE runs (id TEXT PRIMARY KEY, session TEXT, agent_id TEXT, agent_type TEXT, station TEXT, repo TEXT, cwd TEXT, branch TEXT, issue INTEGER, pr INTEGER, model TEXT, prompt TEXT, report TEXT, started REAL, ended REAL, last_seen REAL);
               CREATE TABLE api (id INTEGER PRIMARY KEY AUTOINCREMENT, run TEXT, ts REAL, model TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_creation INTEGER, cost REAL, ms REAL);"
  t0=$(( $(date -u +%s) - 3600 ))
  sqlite3 "$DB" "INSERT INTO runs VALUES ('r1','s1','a1','adlc:builder','builder','acme/shop','/x','feat/42-x',42,NULL,NULL,'','',$t0,$((t0+300)),$((t0+300)));
               INSERT INTO runs VALUES ('r2','s1',NULL,'adlc:architect','architect','acme/shop','/x','feat/42-x',42,NULL,'claude-y','','',$t0,NULL,$t0);
               INSERT INTO runs VALUES ('r3','s2','a3','adlc:builder','builder','other/repo','/y','main',NULL,NULL,NULL,'','',$t0,$((t0+10)),$((t0+10)));
               INSERT INTO runs VALUES ('r4','s3',NULL,NULL,NULL,'acme/shop','/x','main',NULL,NULL,NULL,'','',$t0,$((t0+10)),$((t0+10)));
               INSERT INTO runs VALUES ('r5','s4','a5','adlc-builder','builder','acme/shop','/x','feat/43-y',43,NULL,NULL,'','',$t0,$((t0+100)),$((t0+100)));
               INSERT INTO api (run,ts,model,input,output,cache_read,cache_creation,cost,ms) VALUES ('r1',$((t0+5)),'claude-x',10,5,90,0,0.10,1000),('r1',$((t0+200)),'claude-x',10,5,90,20,0.10,1000);
               INSERT INTO api (run,ts,model,input,output,cache_read,cache_creation,cost,ms) VALUES ('r2',$((t0+20)),'claude-y',0,1,0,0,0.01,500),('r2',$((t0+80)),'claude-y',0,1,0,0,0.01,500);
               INSERT INTO api (run,ts,model,input,output,cache_read,cache_creation,cost,ms) VALUES ('r3',$t0,'claude-x',1,1,1,1,1.0,1);"
  OUT=$( cd "$CY/repo" && ADLC_MC_DB="$DB" ADLC_REPO=Acme/Shop bash "$S/adlc-run-log.sh" mc 7 2>&1 ); check 0 "mc: runs to the end" $?
  eq 3 "mc: only this repo's runs with a station (repo name case-insensitive)" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
  eq "builder builder 43" "mc: a repo's adlc-builder copy is the builder agent" "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "r5") | "\(.stage) \(.agent) \(.issue)"')"
  eq "builder builder 42 300 20 10 180 20 230 81.8 0.2 claude-x" "mc: the run's own started→ended is its latency; tokens/cost summed from its api events" \
     "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "r1") | "\(.stage) \(.agent) \(.issue) \(.seconds) \(.input) \(.output) \(.cache_read) \(.cache_creation) \(.tokens) \(.cache_read_pct) \(.cost_usd) \(.model)"')"
  eq "architect 80 null claude-y" "mc: a run still open runs from its start to its last api event; no cache → null share; the run's model wins" \
     "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "r2") | "\(.agent) \(.seconds) \(.cache_read_pct) \(.model)"')"
  ( cd "$CY/repo" && ADLC_MC_DB="$CY/none.sqlite" ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" mc >/dev/null 2>&1 ); check 2 "mc: no store → exit 2, not an empty ledger" $?
  # --- gh stub: `run list`, `issue list`, `pr list` and `api …/issues/N/timeline` from fixtures, through the call's own --jq
  cat > "$CY/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$CY_CALLS"
case "$1 $2" in
  "run list")   [ -n "${CY_FAIL_RUNS:-}" ] && { echo "gh: HTTP 502" >&2; exit 1; }; src="${CY_RUNS:-$CY_FX/runs.json}" ;;
  "run view")   src="$CY_FX/jobs-$3.json"; [ -f "$src" ] || { echo "run $3 not found" >&2; exit 1; } ;;
  "issue list") src="$CY_FX/issues.json" ;;
  "pr list")    src="$CY_FX/prs.json" ;;
  "pr view")    src="$CY_FX/pr-$3.json"; [ -f "$src" ] || src="$CY_FX/pr-none.json" ;;
  "repo view")  src="$CY_FX/repo.json" ;;
  api*)         n=$(printf '%s' "$2" | sed -nE 's#.*/issues/([0-9]+)/timeline.*#\1#p')
                [ "$n" = 10 ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                src="$CY_FX/timeline-$n.json"; [ -f "$src" ] || src="$CY_FX/empty.json" ;;
  *) exit 2 ;;
esac
f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done
jq -r "$f" "$src"
SH
  chmod +x "$CY/bin/gh"; echo '[]' > "$CY/fx/empty.json"; echo '{"nameWithOwner":"Acme/Shop"}' > "$CY/fx/repo.json"; : > "$CY/calls"
  T1=$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  T2=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg a "$T1" --arg b "$T2" '[
    {databaseId: 1, workflowName: "ADLC Builder",  headBranch: "Feat/042-thing", status: "completed", conclusion: "success", createdAt: $a, startedAt: $a, updatedAt: ($a | fromdate + 120 | todate)},
    {databaseId: 2, workflowName: "ADLC CI",       headBranch: "feat/42-thing", status: "completed", conclusion: "failure", createdAt: $a, startedAt: $a, updatedAt: ($a | fromdate + 30 | todate)},
    {databaseId: 3, workflowName: "ADLC CI",       headBranch: "feat/42-thing", status: "completed", conclusion: "success", createdAt: $b, startedAt: $b, updatedAt: ($b | fromdate + 40 | todate)},
    {databaseId: 4, workflowName: "ADLC review",   headBranch: "main",          status: "in_progress", conclusion: null, createdAt: $b, startedAt: $b, updatedAt: $b},
    {databaseId: 6, workflowName: "ADLC preview deploy", headBranch: "main",    status: "completed", conclusion: "success", createdAt: $b, startedAt: $b, updatedAt: ($b | fromdate + 7 | todate)},
    {databaseId: 5, workflowName: "Deploy site",   headBranch: "main",          status: "completed", conclusion: "failure", createdAt: $b, startedAt: $b, updatedAt: $b}]' > "$CY/fx/runs.json"
  # run 2 failed in 30 s, so it is looked up: its steps ran, so it is a failure of the lane, not a blocked run
  echo '{"jobs": [{"name": "tests", "conclusion": "failure", "steps": [{"name": "Set up job", "conclusion": "success"}, {"name": "Run tests", "conclusion": "failure"}]}]}' > "$CY/fx/jobs-2.json"
  OUT=$( cd "$CY/repo" && env PATH="$CY/bin:$PATH" CY_FX="$CY/fx" CY_CALLS="$CY/calls" ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" actions 7 2>&1 ); check 0 "actions: runs to the end" $?
  eq 4 "actions: completed ADLC workflows only (not the live run, not another workflow)" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
  eq "failure failure success" "actions: outcome is the conclusion for a run that ran its steps, a failure included" "$(printf '%s\n' "$OUT" | jq -rs '[.[] | select(.run_id == "actions:2") | .conclusion, .outcome] + [.[] | select(.run_id == "actions:3") | .outcome] | join(" ")')"
  eq 1 "actions: one run view call, for the one ADLC run that failed within 60 s (none for a green run, a slow one, or another workflow's fast failure)" "$(grep -c '^run view$' "$CY/calls")"
  eq "builder 42 120 null" "actions: the template's lane name → stage, branch → issue by adlc-branch-issue.sh's rule (case, leading zeros), seconds from the run; no tokens" \
     "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "actions:1") | "\(.stage) \(.issue) \(.seconds) \(.tokens)"')"
  eq "adlc-ci failure" "actions: a guard lane keeps its own name and its conclusion" "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "actions:2") | "\(.stage) \(.conclusion)"')"
  eq "adlc-preview-deploy null" "actions: a host repo's own 'ADLC …' workflow is a slug, not a reviewer; a default-branch run names no issue" "$(printf '%s\n' "$OUT" | jq -r 'select(.run_id == "actions:6") | "\(.stage) \(.issue)"')"
  # the branch → issue rule is adlc-branch-issue.sh's; both must answer alike
  for br in feat/12-add-login feat/012-x Feat/42-x fix-lane/042 main feat/x-12 12; do
    want="$(bash "$S/adlc-branch-issue.sh" "$br")"; want="${want:-null}"
    got="$(jq -rn --arg b "$br" 'def branch_issue: capture("^[^/]*/0*(?<n>[0-9]+)(-.*)?$") | .n | tonumber; ($b | branch_issue? // null)')"
    eq "$want" "branch → issue agrees with adlc-branch-issue.sh for '$br'" "$got"
  done
  ( cd "$CY/repo" && ADLC_REPO="o'brien/shop" bash "$S/adlc-run-log.sh" actions 7 >/dev/null 2>&1 ); check 2 "run-log: a repo name that is not owner/name is refused before any query" $?
  ( cd "$CY/repo" && ADLC_REPO= bash "$S/adlc-run-log.sh" otel "$CY/fx/telemetry.jsonl" >/dev/null 2>&1 ); check 2 "run-log: otel with no repo exits 2 like mc, not an empty-repo row" $?
  printf '%s\n' "$OUT" > "$CY/repo/.adlc/metrics/runs.jsonl"; printf '%s\n' "$B" >> "$CY/repo/.adlc/metrics/runs.jsonl"
  # Issue 34: a blocked account. Runs 7 and 8 failed 3 s after creation with no step (no job; a job with no step):
  # blocked, the tripwire's included. Run 9 failed in 20 s but ran its steps: a real diff-scope failure. Run 10 sat
  # queued 200 s and failed 3 s after it STARTED: more than 60 s from creation, never looked up. Run 11 failed fast
  # and gh cannot describe it: it stays a failure, and stderr says one was not read. Runs 12 and 13, neither with a
  # step: 60 s from creation is still blocked, 61 s is a failure and is never looked up.
  jq -n --arg b "$T2" 'def r(id; wf; c; q; s): {databaseId: id, workflowName: wf, headBranch: "feat/42-thing", status: "completed", conclusion: c, createdAt: ($b | fromdate - q | todate), startedAt: $b, updatedAt: ($b | fromdate + s | todate)};
    [r(7; "ADLC CI"; "failure"; 0; 3), r(8; "ADLC main tripwire"; "failure"; 0; 3), r(9; "ADLC diff-scope"; "failure"; 0; 20),
     r(10; "ADLC CI"; "failure"; 200; 3), r(11; "ADLC CI"; "failure"; 0; 7),
     r(12; "ADLC fast lane"; "failure"; 0; 60), r(13; "ADLC fast lane"; "failure"; 0; 61)]' > "$CY/fx/runs-blocked.json"
  echo '{"jobs": []}' > "$CY/fx/jobs-12.json"; echo '{"jobs": []}' > "$CY/fx/jobs-13.json"
  echo '{"jobs": []}' > "$CY/fx/jobs-7.json"; echo '{"jobs": [{"name": "tripwire", "conclusion": "failure", "steps": []}]}' > "$CY/fx/jobs-8.json"
  echo '{"jobs": [{"name": "scope", "conclusion": "failure", "steps": [{"name": "Check scope", "conclusion": "failure"}]}]}' > "$CY/fx/jobs-9.json"
  : > "$CY/calls"
  BL=$( cd "$CY/repo" && env PATH="$CY/bin:$PATH" CY_FX="$CY/fx" CY_RUNS="$CY/fx/runs-blocked.json" CY_CALLS="$CY/calls" ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" actions 7 2>"$CY/err" ); check 0 "actions, blocked account: runs to the end" $?
  eq "7:blocked 8:blocked 9:failure 10:failure 11:failure 12:blocked 13:failure" "actions: a run that failed within 60 s of its creation with no step run is blocked (60 s included, 61 s not); one whose steps ran, one that was slow from creation, and one gh cannot describe stay failures" "$(printf '%s\n' "$BL" | jq -rs 'map((.run_id | sub("actions:"; "")) + ":" + .outcome) | join(" ")')"
  eq "failure failure failure" "actions: a blocked row keeps GitHub's own conclusion beside the outcome" "$(printf '%s\n' "$BL" | jq -rs '[.[] | select(.outcome == "blocked") | .conclusion] | join(" ")')"
  eq 5 "actions: one run view call per run that failed within 60 s of its creation, none for the queued one or the 61 s one" "$(grep -c '^run view$' "$CY/calls")"
  eq 1 "actions: the run it could not read is counted on stderr, not guessed" "$(grep -c '1 run(s) that failed within 60 s could not be read' "$CY/err")"
  ( cd "$CY/repo" && env PATH="$CY/bin:$PATH" CY_FX="$CY/fx" CY_FAIL_RUNS=1 CY_CALLS="$CY/calls" ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" actions 7 >"$CY/out" 2>"$CY/err" ); check 1 "actions: a failed run listing exits 1" $?
  eq "0 1" "…with no row on stdout, and a line on stderr that says what failed" "$(wc -l < "$CY/out" | tr -d ' ') $(grep -c 'could not list the workflow runs' "$CY/err")"
  printf '%s\n' "$BL" >> "$CY/repo/.adlc/metrics/runs.jsonl"
  # --- cycle: issue 7 goes intake (10 min) → gate:stories (5 min) → design → build; PR 9 references it and drew one changes-requested
  tl() { jq -cn --arg t "$1" --arg e "$2" --arg l "$3" '{event: $e, created_at: $t, label: (if $l == "" then null else {name: $l} end), actor: {login: "bot"}}'; }
  xref() { jq -cn --arg t "$1" --argjson n "$2" --argjson pr "$3" --arg repo "${4:-acme/shop}" '{event: "cross-referenced", created_at: $t, source: {issue: ({number: $n, repository: {full_name: $repo}} + (if $pr then {pull_request: {url: "x"}} else {} end))}}'; }
  at() { jq -rn --arg b "$T1" --argjson s "$1" '$b | fromdate + $s | todate'; }
  { tl "$(at 0)" labeled stage:intake; xref "$(at 30)" 5 false; tl "$(at 600)" unlabeled stage:intake; tl "$(at 600)" labeled gate:stories
    tl "$(at 900)" unlabeled gate:stories; tl "$(at 900)" labeled stage:design; tl "$(at 1000)" unlabeled stage:design; tl "$(at 1000)" labeled stage:build
    xref "$(at 1800)" 9 true; tl "$(at 2000)" unlabeled stage:build; tl "$(at 2000)" labeled stage:qa; tl "$(at 2600)" unlabeled stage:qa; tl "$(at 2600)" labeled gate:deploy
    tl "$(at 3500)" labeled stage:intake; } | jq -s . > "$CY/fx/timeline-7.json"   # re-labeled 500 s AFTER the close: counts 0, not -500
  { tl "$(at 1900)" labeled adlc:changes-requested; tl "$(at 1950)" unlabeled adlc:changes-requested; tl "$(at 1990)" labeled lane:full; } | jq -s . > "$CY/fx/timeline-9.json"
  # PR 9's comments (issue 58): the label marks one round, the verdict comments three — a reviewer that asked for
  # changes three times (its fourth comment only QUOTES "ADLC-ADV: CHANGES" and ends PASS), the other once; a repo
  # that runs the pipeline by hand never applies the label, so the verdicts count too: max(1, max(3, 1)) = 3
  # (not 2 distinct markers, not 4 CHANGES comments, not 1 + 3)
  jq -n '{comments: [
    {body: "Found two things.\nADLC-FINDING: High | authz-gap | src/a.py\n\nADLC-ADV: CHANGES"},
    {body: "Conformance: the ADR says otherwise.\n\n**ADLC-ARCH: CHANGES**"},
    {body: "Still one left.\n\n`ADLC-ADV: CHANGES`"},
    {body: "And the test for it.\n\nADLC-ADV: CHANGES"},
    {body: "The earlier ADLC-ADV: CHANGES is addressed.\n\nADLC-ADV: PASS"},
    {body: "ADLC-ARCH: PASS"}]}' > "$CY/fx/pr-9.json"
  echo '{"comments": []}' > "$CY/fx/pr-none.json"
  # issue 8: fast lane, its PR predates its intake label (filed from the PR) → intake_to_pr null
  { xref "$(at -50)" 500 true other/plugin; xref "$(at 0)" 11 true; tl "$(at 100)" labeled stage:intake; tl "$(at 200)" unlabeled stage:intake; tl "$(at 200)" labeled stage:fast; } | jq -s . > "$CY/fx/timeline-8.json"
  # issue 12 (issue 38): QA put gate:deploy on and never took stage:qa off; closed at 1000. The stage ends at the
  # next state label (600), not at the close (1000); the gate runs from 600 to the close (400).
  { tl "$(at 0)" labeled stage:qa; tl "$(at 600)" labeled gate:deploy; } | jq -s . > "$CY/fx/timeline-12.json"
  # issue 13: as 12, then gate:deploy taken off at 700 (a Gate 2 rejection): stage:qa, still on the issue, is the
  # state again from 700 to the close at 1000 — 600 + 300, not 600 with 300 s in no bucket
  { tl "$(at 0)" labeled stage:qa; tl "$(at 600)" labeled gate:deploy; tl "$(at 700)" unlabeled gate:deploy; } | jq -s . > "$CY/fx/timeline-13.json"
  jq -n --arg t1 "$T1" --arg close "$(at 3000)" --arg close12 "$(at 1000)" --arg old "2020-01-01T00:00:00Z" '[
    {number: 7, title: "thing", createdAt: $t1, closedAt: $close, labels: []},
    {number: 8, title: "small", createdAt: $t1, closedAt: $close, labels: []},
    {number: 12, title: "two labels", createdAt: $t1, closedAt: $close12, labels: []},
    {number: 13, title: "gate taken off again", createdAt: $t1, closedAt: $close12, labels: []},
    {number: 10, title: "transferred away (timeline 404)", createdAt: $t1, closedAt: $close, labels: []},
    {number: 3, title: "ancient", createdAt: $old, closedAt: $old, labels: []}]' > "$CY/fx/issues.json"
  : > "$CY/calls"
  OUT=$( cd "$CY/repo" && env PATH="$CY/bin:$PATH" CY_FX="$CY/fx" CY_CALLS="$CY/calls" bash "$S/adlc-cycle.sh" issues 7 2>"$CY/err" ); check 0 "cycle issues: runs to the end although one timeline read failed" $?
  eq 4 "cycle issues: one row per readable issue created in the window" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
  eq 1 "cycle issues: the unreadable issue is named on stderr and skipped, not silently dropped" "$(grep -c 'timeline of #10; skipped' "$CY/err")"
  eq 1 "…and gh's own error is kept" "$(grep -c 'HTTP 404' "$CY/err")"
  R7=$(printf '%s\n' "$OUT" | jq -c 'select(.issue == 7)')
  eq "600 300 100 1000 600 400" "cycle: dwell per label from labeled→unlabeled intervals; the open gate ends at the next label put on, capped at the close (3500 → 3000); that label, put on after the close, adds 0" \
     "$(printf '%s' "$R7" | jq -r '"\(.dwell["stage:intake"]) \(.dwell["gate:stories"]) \(.dwell["stage:design"]) \(.dwell["stage:build"]) \(.dwell["stage:qa"]) \(.dwell["gate:deploy"])"')"
  eq "full 9 1800 3 2300 700" "cycle: lane, first PR that references the issue (not the issue xref), intake→PR, rounds = max(changes-requested labels, CHANGES verdicts per marker), stage vs gate seconds" \
     "$(printf '%s' "$R7" | jq -r '"\(.lane) \(.pr) \(.intake_to_pr_seconds) \(.rounds) \(.stage_seconds) \(.gate_seconds)"')"
  eq "fast 11 null 0" "cycle: stage:fast → fast lane; another repo's PR is not this issue's PR; a PR that predates the intake label gives no intake→PR; no changes-requested and no verdict → 0 rounds" \
     "$(printf '%s\n' "$OUT" | jq -r 'select(.issue == 8) | "\(.lane) \(.pr) \(.intake_to_pr_seconds) \(.rounds)"')"
  eq "600 400 600 400 full" "cycle: a stage left on when the next state label is put on ends there, not at the close; the gate runs to the close" \
     "$(printf '%s\n' "$OUT" | jq -r 'select(.issue == 12) | "\(.dwell["stage:qa"]) \(.dwell["gate:deploy"]) \(.stage_seconds) \(.gate_seconds) \(.lane)"')"
  eq "900 100 900 100" "cycle: a superseded stage is the state again when the gate that superseded it is taken off, until the close" \
     "$(printf '%s\n' "$OUT" | jq -r 'select(.issue == 13) | "\(.dwell["stage:qa"]) \(.dwell["gate:deploy"]) \(.stage_seconds) \(.gate_seconds)"')"
  eq 1 "cycle: one issue list call" "$(grep -c '^issue list$' "$CY/calls")"
  eq 1 "cycle: one repo view call, outside the loop" "$(grep -c '^repo view$' "$CY/calls")"
  eq 7 "cycle: one timeline call per issue, plus one per linked PR (none for a skipped issue)" "$(grep -c '^api ' "$CY/calls")"
  eq 2 "cycle: one pr view call per linked PR, for its verdict comments" "$(grep -c '^pr view$' "$CY/calls")"
  printf '%s\n' "$OUT" > "$CY/repo/.adlc/metrics/cycle.jsonl"
  OUT=$( cd "$CY/repo" && CLAUDE_PROJECT_DIR="$CY/repo" bash "$S/adlc-cycle.sh" report 7 2>&1 ); check 0 "cycle report: runs to the end" $?
  eq "builder          1               1      0.2       100%        60       100%  82%" "report: the per-stage spend table (agent runs only; cached share of the prompt)" "$(printf '%s\n' "$OUT" | grep '^builder ')"
  eq "adlc-ci: runs=5 avg_sec=20 failed=3 blocked=1" "report: guard lanes by name; a blocked run is in runs= and blocked=, not in failed= and not in avg_sec ((30+40+3+7)/4)" "$(printf '%s\n' "$OUT" | grep '^adlc-ci:')"
  eq "adlc-main-tripwire: runs=1 avg_sec=- failed=0 blocked=1" "report: a lane whose every run was blocked has no avg and no failure" "$(printf '%s\n' "$OUT" | grep '^adlc-main-tripwire:')"
  eq "fast: runs=2 avg_sec=61 failed=1 blocked=1" "report: 60 s with no step is blocked, 61 s is the lane's failure" "$(printf '%s\n' "$OUT" | grep '^fast:')"
  eq "adlc-diff-scope: runs=1 avg_sec=20 failed=1 blocked=0" "report: a fast failure that ran its steps is the lane's failure" "$(printf '%s\n' "$OUT" | grep '^adlc-diff-scope:')"
  # a ledger written before the outcome field existed: the conclusion is read, nothing is called blocked
  jq -c 'select(.source == "actions") | del(.outcome)' "$CY/repo/.adlc/metrics/runs.jsonl" > "$CY/old.jsonl"; cp "$CY/repo/.adlc/metrics/runs.jsonl" "$CY/new.jsonl"; cp "$CY/old.jsonl" "$CY/repo/.adlc/metrics/runs.jsonl"
  eq "adlc-ci: runs=5 avg_sec=17 failed=4 blocked=0" "report: rows with no outcome field (an older ledger) are read by their conclusion" "$( cd "$CY/repo" && CLAUDE_PROJECT_DIR="$CY/repo" bash "$S/adlc-cycle.sh" report 7 2>&1 | grep '^adlc-ci:')"
  cp "$CY/new.jsonl" "$CY/repo/.adlc/metrics/runs.jsonl"
  eq "issues=4  with_pr=2  fast_lane=1" "report: issue counts" "$(printf '%s\n' "$OUT" | grep '^issues=')"
  eq "rounds: total=3  issues_with_a_fix_round=1" "report: fix rounds" "$(printf '%s\n' "$OUT" | grep '^rounds:')"
  rm -f "$CY/repo/.adlc/metrics/runs.jsonl" "$CY/repo/.adlc/metrics/cycle.jsonl"
  OUT=$( cd "$CY/repo" && CLAUDE_PROJECT_DIR="$CY/repo" bash "$S/adlc-cycle.sh" report 7 2>&1 ); check 0 "report with no ledgers: still exits 0" $?
  eq 2 "report with no ledgers: says which to materialize, instead of empty tables" "$(printf '%s\n' "$OUT" | grep -c 'materialize it with')"
  ( bash "$S/adlc-cycle.sh" bogus >/dev/null 2>&1 ); check 2 "cycle: an unknown subcommand is an error" $?
  ( bash "$S/adlc-run-log.sh" bogus >/dev/null 2>&1 ); check 2 "run-log: an unknown source is an error" $?
  rm -rf "$CY"
else
  echo "  · skipped the cycle-retro ledger checks (need jq and sqlite3)"
fi

echo "adr-check (an ADR's Scope is the scope file; each Guarantees row names a test that exists):"
# Issue 55. Fixture: a checkout-shaped directory, as the script is run from the repo root.
AC="$(mktemp -d)"; mkdir -p "$AC/docs/adr" "$AC/tests" "$AC/.adlc/scope" "$AC/bare"
printf 'def test_expired_token_rejected():\n    pass\nclass TestLogin:\n    def test_ok(self): pass\n' > "$AC/tests/test_login.py"
adrc() { ( cd "$AC" && bash "$S/adlc-adr-check.sh" "$@" ) >"$AC/out" 2>"$AC/err"; }
adr() { # <file> <issue|''> <Scope block lines (%b) | - for no section | nofence> <Guarantees rows (%b) | - for no section>
  { printf '# ADR: x\n\n**Status:** Proposed  ·  **Author:** Architect'; [ -z "$2" ] || printf '  ·  **Issue:** #%s' "$2"
    printf '\n\n## Context\n\nx\n\n'
    case "$3" in -) ;; nofence) printf '## Scope\n\n- src/login/\n\n' ;; *) printf '## Scope\n\nprose\n\n```\n%b```\n\n' "$3" ;; esac
    [ "$4" = - ] || printf '## Guarantees\n\n| Claim | Pinned by |\n|---|---|\n%b\n' "$4"
    printf '## Consequences\n\ny\n'; } > "$AC/docs/adr/$1"
}
errs() { wc -l < "$AC/err" | tr -d ' '; }
GOOD='| expired tokens are rejected | `tests/test_login.py::test_expired_token_rejected` |\n| a class::method node | tests/test_login.py::TestLogin::test_ok |\n| a parametrized node | tests/test_login.py::test_ok[a-b] |\n| a \\| in the claim | tests/test_login.py::test_ok |\n| rate limit holds | unenforced — no load test in CI yet |\n'
( cd "$AC/bare" && bash "$S/adlc-adr-check.sh" ) >"$AC/out" 2>"$AC/err"; check 0 "no ADR directory: exit 0" $?
eq 1 "…with a note, not silence" "$(grep -c 'no ADR directory (docs/adr)' "$AC/out")"
# the passing case: the scope file holds the ADR's lines plus the docs/ files the design lane put there
adr 0007-login.md 12 'src/login/\n# a comment\n\ntests/\n' "$GOOD"
printf 'docs/adr/0007-login.md\ndocs/guide.md\nsrc/login/\ntests/\n' > "$AC/.adlc/scope/12.txt"
adrc; check 0 "a resolvable ADR passes (path::node, Class::method, a [param] id, a | in the claim, unenforced with a reason)" $?
eq 0 "…with nothing on stderr" "$(errs)"
eq 1 "…and says how many it checked" "$(grep -c 'OK — 1 ADR(s) checked in docs/adr' "$AC/out")"
adrc docs/adr/; check 0 "the directory can be named, with a trailing slash" $?
# older ADRs: neither section → skipped and listed; template.md is never an ADR (its placeholder rows would fail)
printf '# ADR-0001: adopt\n\n## Context\n\nold\n\n## Decision\n\nIn a block, not a section:\n\n```\n## Scope\n## Guarantees\n| a | b |\n```\n' > "$AC/docs/adr/0001-adopt.md"
cp "$ROOT/templates/adr-template.md" "$AC/docs/adr/template.md"
adrc; check 0 "an ADR with neither section (written before the template had them) does not fail; nor does template.md" $?
eq 1 "…it is listed as skipped (a heading inside a fenced block is not a section)" "$(grep -c 'skipped.*: 0001-adopt.md$' "$AC/out")"
eq 0 "…and template.md is not mentioned" "$(cat "$AC/out" "$AC/err" | grep -c 'template.md')"
# the template is in the format the script reads: as an ADR it IS checked, and only its unfilled rows fail
cp "$ROOT/templates/adr-template.md" "$AC/docs/adr/0002-from-template.md"
adrc; check 1 "the template, copied unfilled as an ADR, fails" $?
eq "0002-from-template.md: Guarantees row '<what must stay true>': tests/<file> does not exist|0002-from-template.md: Guarantees row '<a claim no test holds>': unenforced, with no reason|" \
   "…on its two placeholder rows and nothing else (its sections, block and table parse)" "$(sed 's|^docs/adr/||' "$AC/err" | tr '\n' '|')"
grep -q '\*\*Issue:\*\* #N' "$ROOT/templates/adr-template.md" && ok "the template's header names the issue" || bad "adr-template.md: the header must carry **Issue:** #N"
rm "$AC/docs/adr/0002-from-template.md"
# each failure kind, one at a time (the passing ADR above is each one's control)
adrfail() { # <what> <stderr must contain> — after the fixture was rewritten
  adrc; local rc=$?
  [ "$rc" = 1 ] && grep -qF -- "$2" "$AC/err" && ok "$1" || bad "$1 (exit $rc; stderr: $(tr '\n' '|' < "$AC/err"))"
}
adr 0007-login.md 12 'src/login/\ntests/\n' -;      adrfail "no Guarantees section fails" "0007-login.md: no '## Guarantees' section"
adr 0007-login.md 12 - "$GOOD";                     adrfail "no Scope section fails" "0007-login.md: no '## Scope' section"
adr 0007-login.md 12 nofence "$GOOD";               adrfail "a Scope with no fenced block fails" "'## Scope' has no fenced block"
adr 0007-login.md 12 'src/login/\ntests/\n' '';     adrfail "a Guarantees table with no row fails" "'## Guarantees' has no table row"
row() { adr 0007-login.md 12 'src/login/\ntests/\n' "$1"; }
row '| x | see the tests |\n';                         adrfail "a row that is neither form fails" "'see the tests' is neither a path::node nor"
row '| x | |\n';                                       adrfail "a row with an empty last cell fails" "Guarantees row 'x': '' is neither"
row '| x | `tests/nope.py::test_a` |\n';               adrfail "a path that does not exist fails" "Guarantees row 'x': tests/nope.py does not exist"
row '| x | tests/test_login.py::test_expired |\n';     adrfail "a node that is in the file only as part of a longer name fails (whole word)" "'test_expired' is not in tests/test_login.py"
row '| x | tests/test_login.py:: |\n';                 adrfail "a path with no node fails" "is not a path::node"
row '| x | unenforced |\n';                            adrfail "unenforced with no reason fails" "Guarantees row 'x': unenforced, with no reason"
row '| x | unenforced — |\n';                          adrfail "unenforced with a dash and no reason fails" "unenforced, with no reason"
row '| x | unenforced — <why not> |\n';                adrfail "unenforced with the template's unfilled <…> fails" "unenforced, with no reason"
row '| x | unenforced - ascii dash |\n| y | Unenforced: a colon |\n| z | unenforced -- two |\n'
adrc; check 0 "unenforced takes an ASCII dash, two, or a colon before the reason" $?
row "$GOOD"; printf 'docs/adr/0007-login.md\nsrc/login/\n' > "$AC/.adlc/scope/12.txt"
adrfail "a Scope line the scope file lacks fails" "0007-login.md: Scope line 'tests/' is not in .adlc/scope/12.txt"
printf 'src/login/\ntests/\nsrc/billing/\n' > "$AC/.adlc/scope/12.txt"
adrfail "a scope-file line the ADR's Scope lacks fails" ".adlc/scope/12.txt: 'src/billing/' is in no Scope section of the ADR(s) naming issue 12 (in docs/adr: 0007-login.md)"
# every problem is reported, not the first one
adr 0007-login.md 12 'src/login/\nsrc/extra/\n' '| a | tests/nope.py::t |\n| b | unenforced |\n| c | prose |\n'
printf 'src/login/\nsrc/billing/\n' > "$AC/.adlc/scope/12.txt"
adrc; check 1 "an ADR with five problems fails" $?
eq 5 "…and all five are on stderr, one line each (three rows, one line per side of the scope)" "$(errs)"
eq 1 "…with the count on stdout" "$(grep -c '^adr-check: 5 problem(s)' "$AC/out")"
# what must NOT fail
adr 0007-login.md 12 'src/login/\n' "$GOOD"; adr 0008-login-ui.md 12 'tests/\n' "$GOOD"; printf 'src/login/\ntests/\n' > "$AC/.adlc/scope/12.txt"
adrc; check 0 "two ADRs of one issue: the scope file is compared with the union of their Scopes" $?
rm "$AC/docs/adr/0008-login-ui.md"
adr 0007-login.md '' 'src/anything/\n' "$GOOD"
adrc; check 0 "an ADR that names no issue: Scope is not compared" $?
eq 1 "…and stdout says so" "$(grep -c '0007-login.md names no issue' "$AC/out")"
adr 0007-login.md 99 'src/anything/\n' "$GOOD"
adrc; check 0 "no scope file yet (design time): Scope is not compared" $?
eq 1 "…and stdout says so" "$(grep -c 'no .adlc/scope/99.txt yet' "$AC/out")"
adr 0007-login.md 12 '' "$GOOD"; printf 'docs/adr/0007-login.md\n' > "$AC/.adlc/scope/12.txt"
adrc; check 0 "an empty Scope block against a scope file holding only the design lane's docs/ lines passes" $?
adr 0007-login.md 12 'src/login/\ntests/\n' "$GOOD"; printf 'docs/adr/0007-login.md\nsrc/login/\ntests/\n' > "$AC/.adlc/scope/12.txt"
sed 's/$/\r/' "$AC/docs/adr/0007-login.md" > "$AC/crlf" && mv "$AC/crlf" "$AC/docs/adr/0007-login.md"
adrc; check 0 "a CRLF ADR reads the same" $?
# bad arguments, and a file that cannot be read
adrc docs/adr extra;          check 2 "two arguments is an error" $?
adrc --fix;                   check 2 "an option is an error" $?
adrc tests/test_login.py;     check 2 "a path that is not a directory is an error" $?
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$AC/docs/adr/0007-login.md"
  adrc; check 1 "an ADR that cannot be read is a failure, not a skip" $?
  eq 1 "…named on stderr" "$(grep -c '0007-login.md: could not be read' "$AC/err")"
  chmod 644 "$AC/docs/adr/0007-login.md"
fi
adrc; check 0 "…and the fixture passes again once readable" $?
rm -rf "$AC"
[ -x "$S/adlc-adr-check.sh" ] && ok "adlc-adr-check.sh is executable" || bad "adlc-adr-check.sh must be executable"
# wiring: who fills the sections, who runs the script, and that nobody was granted more to do so
RA="$ROOT/skills/role-architect/SKILL.md"
for w in '`## Scope`' '`## Guarantees`' '`\*\*Issue:\*\* #N`' 'unenforced — <reason>'; do grep -q -- "$w" "$RA" && ok "role-architect: the design duty fills $w" || bad "role-architect must name $w"; done
for r in architect builder qa-release-ops; do grep -q '\.adlc/scripts/adlc-adr-check\.sh' "$ROOT/skills/role-$r/SKILL.md" && ok "role-$r runs adlc-adr-check.sh" || bad "role-$r must run .adlc/scripts/adlc-adr-check.sh"; done
grep -q 'not among your granted commands' "$RA" && ok "role-architect says the Actions review lane does not grant the script" || bad "role-architect must say the review lane does not grant adlc-adr-check.sh"
eq 0 "…and no lane grants it or calls it (the grants are as they were)" "$(cat "$ROOT"/templates/github/adlc-*.yml | grep -c 'adlc-adr-check')"
grep -q '\.adlc/scripts/adlc-adr-check\.sh' "$ROOT/templates/RUNBOOK.md.tmpl" && ok "RUNBOOK's conformance stage names the script" || bad "RUNBOOK must name adlc-adr-check.sh"
grep -q '`adlc-adr-check`' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap lists it among the scripts it copies" || bad "bootstrap must list adlc-adr-check"
grep -q "leave the" "$ROOT/skills/bootstrap/SKILL.md" && grep -q 'template.s `## Scope` and `## Guarantees` out of it' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap seeds the first ADR without the two sections (so it is skipped, not failed)" || bad "bootstrap must leave Scope/Guarantees out of the seeded ADR"
grep -q 'adlc-adr-check\.sh  ' "$ROOT/README.md" && ok "README's layout tree lists the script" || bad "README layout tree must list adlc-adr-check.sh"

echo "security-gate (text classifiers over LLM output):"
# Issue 54: the attack class lives in security-gate, once; code-review points at it.
SG="$ROOT/skills/security-gate/SKILL.md"; CR="$ROOT/skills/code-review/SKILL.md"
grep -q '^## 7\. Text classifiers over LLM output$' "$SG" && ok "security-gate has the attack class" || bad "security-gate: no '## 7. Text classifiers over LLM output'"
sg7() { sed -n '/^## 7\. /,/^## Severity/p' "$SG" | tr '\n' ' ' | tr -s ' '; }   # one line: a phrase may wrap
miss=""
for w in 'regex or word list' 'model text' 'gates a write, a retry or a user-visible claim' "project's languages" 'emoji or check mark' 'em-dash or comma join' \
         'parenthetical' 'a claim and a question in one sentence' 'idiom with no verb' 'negation' 'markup and curly quotes' 'positive control' 'shared phrasing corpus if one exists'; do
  sg7 | grep -q -- "$w" || miss="$miss [$w]"
done
eq "" "security-gate §7 names the trigger and every probe" "$miss"
classes=$(bash "$S/adlc-log-findings.sh" classes)   # read once: under pipefail a `script | grep -q` fails when grep leaves early
for c in $(sg7 | grep -oE '`[a-z]+-[a-z-]+`' | tr -d '`' | sort -u); do
  printf '%s\n' "$classes" | grep -qx "$c" && ok "§7 classes its findings with '$c', a class of the closed list" || bad "§7 names '$c', which is not in the closed class list"
done
grep -q 'adlc:security-gate` §7' "$CR" && ok "code-review points at security-gate §7" || bad "code-review must point at adlc:security-gate §7"
tr '\n' ' ' < "$CR" | grep -qE 'regex or word list over \*\*model text\*\* that gates a write, a retry or a user-visible +claim' && ok "…with the trigger" || bad "code-review must carry the trigger"
eq 0 "…and does not repeat the probe list" "$(grep -cE 'curly quotes|parenthetical|idiom with no verb' "$CR")"

echo "cache lifetime (settings.cache.json):"
# Issue 57: the template the wizard merges, and the one rule in efficient-runs.
SCJ="$ROOT/templates/settings.cache.json"
eq '{"promptCacheTtl":"1h","subagentPromptCacheTtl":"1h"}' "settings.cache.json: valid JSON; apart from _comment, exactly the two keys at 1h" "$(jq -cS 'del(._comment)' "$SCJ" 2>/dev/null)"
miss=""
for w in '1.25x' 'higher rate' 'removing them undoes it' 'CLAUDE_CODE_PROMPT_CACHE_TTL' 'CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL' 'Not checked'; do
  jq -r ._comment "$SCJ" 2>/dev/null | grep -q -- "$w" || miss="$miss [$w]"
done
eq "" "settings.cache.json: the _comment states the trade-off, the precedence and what was not checked" "$miss"
BS="$ROOT/skills/bootstrap/SKILL.md"
grep -q 'templates/settings.cache.json' "$BS" && ok "bootstrap merges settings.cache.json" || bad "bootstrap must name templates/settings.cache.json"
grep -q 'removing the two keys undoes it' "$BS" && ok "…and tells the user how to undo it" || bad "bootstrap must say removing the two keys undoes it"
grep -q 'A wait longer than the cache lifetime re-prices the next turn' "$ROOT/skills/efficient-runs/SKILL.md" && ok "efficient-runs: a wait longer than the cache lifetime re-prices the next turn" || bad "efficient-runs must carry the cache-lifetime rule"
grep -q 'settings.cache.json  ' "$ROOT/README.md" && ok "README's layout tree lists settings.cache.json" || bad "README layout tree must list settings.cache.json"
echo "adlc-ci-budget.sh (Actions minutes: will the CI battery fit):"
# Issue 34: one host's battery of 17 to 23 job-minutes ran 4.6 times per merged PR and used about 8,000 minutes
# in a month against 2,000 included; nothing had sized it. The helper is one multiplication with a verdict.
bud() { OUT=$(bash "$S/adlc-ci-budget.sh" "$@" 2>/dev/null); }
bud 20 4.6 87; check 1 "that host's figures do not fit" $?
eq "estimate: 8004 CI minutes/month (20 min/run x 4.6 runs/PR x 87 PRs/month)|included: 2000 minutes/month|OVER: 401% of the included minutes (4.0x)" "…and the three lines say by how much (2000 is the default)" "$(printf '%s' "$OUT" | tr '\n' '|')"
bud 10 4 20; check 0 "a small battery fits" $?
eq "FITS: 40% of the included minutes" "…with its share" "$(printf '%s\n' "$OUT" | tail -1)"
bud 23 4.6 20; check 1 "a decimal runs-per-PR is taken (4.6 is the measured figure)" $?
eq "estimate: 2116 CI minutes/month (23 min/run x 4.6 runs/PR x 20 PRs/month)" "…and the product is exact to the minute (2116, not 2117 from a binary tail)" "$(printf '%s\n' "$OUT" | head -1)"
bud 10 4 50; check 0 "an estimate equal to the included minutes fits" $?
bud 10 4 50 1999; check 1 "one minute over does not, against an included figure given as the fourth argument" $?
eq "OVER: 101% of the included minutes (1.0x)" "…and reads 101%" "$(printf '%s\n' "$OUT" | tail -1)"
bud 2000.001 1 1; check 1 "a thousandth of a minute over is over" $?
eq "OVER: 101% of the included minutes (1.0x)" "…and OVER never reads 100%" "$(printf '%s\n' "$OUT" | tail -1)"
bud 0.5 3 1 1; check 1 "a fraction of a minute is rounded up in the estimate only (1.5 against 1 is over)" $?
for a in "" "10" "10 4" "10 4 20 2000 1" "0 4 20" "10 0 20" "10 4 0" "10 4 20 0" "0.0 4 20" "x 4 20" "10 4.6.1 20" "10 4 2.5" "10 4 20 1e3" "-10 4 20" ".5 4 20" "10 4 20 2000.5"; do
  # shellcheck disable=SC2086
  bud $a; check 2 "bad arguments are an error, never a FITS: '$a'" $?
done
eq "" "…and print no verdict" "$OUT"
grep -q 'adlc-ci-budget.sh <minutes/run> <runs/PR> <PRs/month>' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap runs the sizing helper from the plugin's templates" || bad "bootstrap: must run adlc-ci-budget.sh in the sizing step"
BS="$(sed -n '/^7a\. \*\*Actions minutes\*\*/,/^7b\. /p' "$ROOT/skills/bootstrap/SKILL.md")"
[ -n "$BS" ] && ok "bootstrap has the Actions minutes step (7a)" || bad "bootstrap: the Actions minutes step (7a) is missing"
# (a here-string, not a pipe: under pipefail a `grep -q` that exits on its match can fail the writer)
for w in 'PRIVATE repo' '4–5' 'PRs per month' '`paths` filters' '`stage:qa`' 'adlc-local-ci.sh' 'the tripwire' 'adlc-doctor.sh'; do
  grep -qF -- "$w" <<<"$BS" && ok "bootstrap 7a names: $w" || bad "bootstrap 7a must name: $w"
done
eq "paths-heavy-local" "bootstrap 7a proposes in order: paths filters, heavy jobs later, the local recipe" "$(printf '%s' "$BS" | tr '\n' ' ' | sed -nE 's/.*\(1\)[^(]*paths.*\(2\)[^(]*heavy jobs.*\(3\)[^(]*local CI recipe.*/paths-heavy-local/p')"
grep -q '~2,000 Actions min/month free' "$ROOT/README.md" "$ROOT/skills/bootstrap/SKILL.md" && bad "the bare '~2,000 Actions min/month free' is back" || ok "README and bootstrap no longer quote the free minutes bare"
grep -q 'adlc-ci-budget.sh' "$ROOT/README.md" && grep -q 'adlc-local-ci.sh' "$ROOT/README.md" && ok "README names both new scripts" || bad "README must name adlc-ci-budget.sh and adlc-local-ci.sh"

echo "adlc-local-ci.sh (the battery run locally, one marker comment):"
# Issue 34: a host whose Actions was blocked posted free-form "Local CI on head X" comments. The recipe: run the
# host's own list of commands on the PR's head commit, post ONE comment whose last line is the marker. A real git
# repo, a stub gh that serves the PR's head and records the comment.
if command -v jq >/dev/null 2>&1; then
  LC="$(mktemp -d)"; mkdir -p "$LC/bin" "$LC/fx" "$LC/repo/.adlc"
  cat > "$LC/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$LC_CALLS"
case "$1 $2" in
  "pr view")    [ -f "$LC_FX/fail-view" ] && { echo "gh: HTTP 502" >&2; exit 1; }; cat "$LC_FX/head" ;;
  "pr comment") [ -f "$LC_FX/fail-comment" ] && { echo "gh: HTTP 403" >&2; exit 1; }
                [ "$3" = 7 ] || exit 2; b=""; while [ $# -gt 0 ]; do [ "$1" = "--body" ] && b="$2"; shift; done; printf '%s\n' "$b" > "$LC_FX/posted" ;;
  "pr list")    jq -n --arg b "$(cat "$LC_FX/posted")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[{number: 7, mergedAt: $at, createdAt: $at, changedFiles: 1, headRefName: "feat/7", comments: [{body: $b}]}]' > "$LC_FX/prs.json"
                f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done; jq -r "$f" "$LC_FX/prs.json" ;;
  "run list"|"issue list") f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done; echo '[]' | jq -r "$f" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$LC/bin/gh"
  git -C "$LC/repo" init -q . && git -C "$LC/repo" config user.email t@example.com && git -C "$LC/repo" config user.name t
  # the battery: a comment, a blank line, a name with a space around its colon, a command that holds colons and
  # must run from the repo root, a failing check in the middle, and a check after it that must still run
  printf '# the battery\n\ntests: true\n  lint : echo "a: b" >/dev/null && test -f .adlc/local-ci.txt\nimage build: exit 3\nafter: test -z "$(cat)" && echo ran >> "%s/ran"\n' "$LC" > "$LC/repo/.adlc/local-ci.txt"
  mkdir "$LC/repo/src"; echo x > "$LC/repo/src/x"
  git -C "$LC/repo" add -A && git -C "$LC/repo" commit -qm init
  HEAD_SHA="$(git -C "$LC/repo" rev-parse HEAD)"; echo "$HEAD_SHA" > "$LC/fx/head"; : > "$LC/calls"
  lci() { ( cd "$LC/repo/src" && env PATH="$LC/bin:$PATH" LC_FX="$LC/fx" LC_CALLS="$LC/calls" bash "$S/adlc-local-ci.sh" "$@" ) >"$LC/out" 2>"$LC/err"; }   # run from a subdirectory
  lci 7 --dry-run <<<"the caller's stdin"; check 1 "a battery with a failing check exits 1" $?
  eq "ADLC-CI: FAIL head $HEAD_SHA" "the LAST line of the comment is the marker, with the full sha" "$(tail -1 "$LC/out")"
  eq "| tests | pass | 0 |,| lint | pass | 0 |,| image build | FAIL | 3 |,| after | pass | 0 |," "one table row per check: name, result, exit code (seconds follow); a command with colons runs from the repo root; a failure does not stop the checks after it; a check that reads stdin gets none of the caller's" "$(grep -E '^\| (tests|lint|image build|after) ' "$LC/out" | sed -E 's/ [0-9]+ \|$//' | tr '\n' ',')"
  eq 1 "…the check after the failure ran, once" "$(wc -l < "$LC/ran" | tr -d ' ')"
  eq "1 0" "--dry-run reads the PR's head and posts nothing" "$(grep -c '^pr view$' "$LC/calls") $(grep -c '^pr comment$' "$LC/calls")"
  grep -q 'A record, not a gate' "$LC/out" && ok "the comment says it is a record, not a gate" || bad "the comment must say it is a record, not a gate"
  : > "$LC/calls"; lci 7; check 1 "posting: the exit code is still the battery's" $?
  eq 1 "…in ONE gh pr comment call" "$(grep -c '^pr comment$' "$LC/calls")"
  eq "ADLC-CI: FAIL head $HEAD_SHA" "…whose last line is the marker" "$(tail -1 "$LC/fx/posted")"
  eq "" "…and stdout stays empty (the checks' output and the progress go to stderr)" "$(cat "$LC/out")"
  # the reader: adlc-metrics.sh counts the comment this script wrote as one red CI run of the merged PR
  M=$( cd "$LC/repo" && env PATH="$LC/bin:$PATH" LC_FX="$LC/fx" LC_CALLS="$LC/calls" bash "$S/adlc-metrics.sh" 30 2>&1 )
  eq "local_ci: 1 ADLC-CI marker comments on 1 merged PRs (1 FAIL), counted above as CI runs" "adlc-metrics.sh reads the comment adlc-local-ci.sh writes" "$(printf '%s\n' "$M" | grep '^local_ci:')"
  eq "iterations_to_green: avg 1 CI runs per merged PR; failed_first: 1 / 1" "…as a CI run of a PR that has no Actions run at all" "$(printf '%s\n' "$M" | grep '^iterations_to_green:')"
  # a green battery, from a commands file named on the command line
  printf 'tests: true\nlint: test -d src\n' > "$LC/green.txt"
  : > "$LC/calls"; rm -f "$LC/fx/posted"; lci 7 "$LC/green.txt"; check 0 "a green battery exits 0 (commands file given as an argument)" $?
  eq "ADLC-CI: PASS head $HEAD_SHA" "…and posts the PASS marker" "$(tail -1 "$LC/fx/posted" 2>/dev/null)"
  # refusals: exit 2, nothing runs, nothing is posted
  refuse() { rm -f "$LC/ran" "$LC/fx/posted"; : > "$LC/calls"; lci "${@:2}"; check 2 "$1: exit 2" $?
             eq "no no 0" "…no check ran, nothing posted" "$([ -f "$LC/ran" ] && echo yes || echo no) $([ -f "$LC/fx/posted" ] && echo yes || echo no) $(grep -c '^pr comment$' "$LC/calls")"; }
  echo y > "$LC/repo/untracked.txt"; refuse "an untracked file (the tree is not clean)" 7
  grep -q 'working tree is not clean' "$LC/err" && ok "…and says why" || bad "a dirty tree must be named"
  rm "$LC/repo/untracked.txt"; echo changed > "$LC/repo/src/x"; refuse "a modified tracked file" 7; git -C "$LC/repo" checkout -q -- src/x
  echo 3333333333333333333333333333333333333333 > "$LC/fx/head"; refuse "HEAD is not the PR's head commit" 7
  grep -q "PR #7's head is 3333333333333333333333333333333333333333" "$LC/err" && ok "…and names both commits" || bad "a wrong head must be named"
  echo "$HEAD_SHA" > "$LC/fx/head"; touch "$LC/fx/fail-view"; refuse "the PR's head cannot be read from gh" 7; rm "$LC/fx/fail-view"
  refuse "no PR number" --dry-run; refuse "a PR that is not a number" abc; refuse "an unknown option" 7 --post; refuse "a third argument" 7 a b
  refuse "a commands file that does not exist" 7 "$LC/none.txt"
  printf 'tests: touch "%s/ran"\njust a command\n' "$LC" > "$LC/bad.txt"; refuse "a line with no '<name>: <command>' (the checks before it do not run either)" 7 "$LC/bad.txt"
  printf 'tests: touch "%s/ran"\nlint:\n' "$LC" > "$LC/bad.txt"; refuse "a name with no command" 7 "$LC/bad.txt"
  printf 'te|sts: touch "%s/ran"\n' "$LC" > "$LC/bad.txt"; refuse "a name that would break the table" 7 "$LC/bad.txt"
  printf '# nothing yet\n\n' > "$LC/bad.txt"; refuse "a commands file with no check" 7 "$LC/bad.txt"
  ( cd "$LC" && env PATH="$LC/bin:$PATH" LC_FX="$LC/fx" LC_CALLS="$LC/calls" bash "$S/adlc-local-ci.sh" 7 --dry-run "$LC/green.txt" >/dev/null 2>&1 ); check 2 "outside a git checkout: exit 2" $?
  # a repo that hides untracked files from git status: they count all the same
  git -C "$LC/repo" config status.showUntrackedFiles no; echo y > "$LC/repo/untracked.txt"
  refuse "an untracked file in a repo with status.showUntrackedFiles=no" 7; rm "$LC/repo/untracked.txt"; git -C "$LC/repo" config --unset status.showUntrackedFiles
  # a check that changes the tree: the checks after it ran on something that is not the commit the marker names.
  # A formatter that fixes a tracked file and a generator that leaves an untracked one, each followed by a check
  # that is green only BECAUSE of the change.
  printf 'fmt: echo fixed >> src/x\ntests: grep -q fixed src/x\n' > "$LC/fmt.txt"
  rm -f "$LC/fx/posted"; : > "$LC/calls"; lci 7 "$LC/fmt.txt"; check 2 "a check that rewrote a tracked file: exit 2, although every check was green" $?
  eq "no 0" "…and nothing is posted" "$([ -f "$LC/fx/posted" ] && echo yes || echo no) $(grep -c '^pr comment$' "$LC/calls")"
  grep -q 'the battery changed the working tree' "$LC/err" && grep -q '^ M src/x$' "$LC/err" && ok "…and stderr names the changed file" || bad "a tree the battery changed must be named"
  lci 7 --dry-run "$LC/fmt.txt"; check 2 "…with --dry-run too" $?
  eq "" "…which prints no comment" "$(cat "$LC/out")"
  git -C "$LC/repo" checkout -q -- src/x
  printf 'gen: echo y > src/gen.py\ntests: test -f src/gen.py\n' > "$LC/gen.txt"
  rm -f "$LC/fx/posted"; : > "$LC/calls"; lci 7 "$LC/gen.txt"; check 2 "a check that left an untracked file: exit 2" $?
  eq "no 0" "…and nothing is posted" "$([ -f "$LC/fx/posted" ] && echo yes || echo no) $(grep -c '^pr comment$' "$LC/calls")"
  rm -f "$LC/repo/src/gen.py"
  # a check that moves HEAD: the sha the marker would name is no longer what is checked out
  printf 'tests: true\nmoves head: git commit -q --allow-empty -m moved\n' > "$LC/move.txt"
  rm -f "$LC/fx/posted"; : > "$LC/calls"; lci 7 "$LC/move.txt"; check 2 "HEAD moved during the battery: exit 2" $?
  eq "no 0" "…and nothing is posted" "$([ -f "$LC/fx/posted" ] && echo yes || echo no) $(grep -c '^pr comment$' "$LC/calls")"
  git -C "$LC/repo" reset -q --hard "$HEAD_SHA"
  # the post fails: exit 2 (no record exists), and the comment is printed so the result is not lost
  touch "$LC/fx/fail-comment"; lci 7 "$LC/green.txt"; check 2 "a failed gh pr comment: exit 2, although the battery was green" $?
  eq "ADLC-CI: PASS head $HEAD_SHA" "…with the comment on stdout" "$(tail -1 "$LC/out")"
  grep -q 'nothing was posted' "$LC/err" && ok "…and stderr says nothing was posted" || bad "a failed post must be said"
  rm -rf "$LC"
else
  echo "  · skipped the local CI checks (no jq here)"
fi
LCS="$S/adlc-local-ci.sh"
grep -q 'RECORD, not a gate' "$LCS" && grep -q 'Anyone who can comment on the PR can write that line' "$LCS" && ok "the script's header says the marker is a record, not a gate" || bad "adlc-local-ci.sh: the header must say the marker is a record, not a gate"
grep -q 'per-command timeout' "$LCS" && ok "…and that there is no per-command timeout" || bad "adlc-local-ci.sh: the header must say there is no per-command timeout"
QA="$ROOT/skills/role-qa-release-ops/SKILL.md"
grep -q 'ADLC-CI: PASS|FAIL head <sha>' "$QA" && ok "QA's role prompt names the local CI marker" || bad "role-qa-release-ops: must name the ADLC-CI marker"
grep -q "only when that SHA is the PR's current head" <<<"$(tr '\n' ' ' < "$QA")" && ok "…as the battery result only for the PR's current head" || bad "role-qa-release-ops: a local CI marker counts only for the PR's current head"
grep -q 'one for an older commit does not' <<<"$(tr '\n' ' ' < "$QA")" && ok "…and not for an older commit" || bad "role-qa-release-ops: must say an older marker does not count"
grep -q 'a record, not a gate' "$QA" && ok "…and calls it a record, not a gate" || bad "role-qa-release-ops: must call the marker a record, not a gate"
grep -q '\.adlc/scripts/adlc-local-ci\.sh <pr>' "$RB" && grep -q '\.adlc/local-ci\.txt' "$RB" && ok "RUNBOOK has the local CI recipe (script and commands file)" || bad "RUNBOOK must name adlc-local-ci.sh and .adlc/local-ci.txt"
grep -q 'a record, not a gate: anyone who can comment can write that line' <<<"$(tr '\n' ' ' < "$RB")" && ok "…and says the marker is a record, not a gate" || bad "RUNBOOK: must say the marker is a record, not a gate"
grep -q '`blocked=`' "$ROOT/skills/cycle-retro/SKILL.md" && ok "cycle-retro explains the blocked= figure" || bad "cycle-retro must explain blocked="

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
