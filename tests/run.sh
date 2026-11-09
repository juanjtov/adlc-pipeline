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

echo "fix-cap (the older form: commit subjects on stdin):"
eq GO   "GO below cap"   "$(printf 'adlc-fix: a\nadlc-fix: b\n'              | bash "$S/adlc-fix-cap.sh" 3)"
eq STOP "STOP at cap"    "$(printf 'adlc-fix: a\nadlc-fix: b\nadlc-fix: c\n' | bash "$S/adlc-fix-cap.sh" 3)"
eq GO   "GO when none"   "$(printf 'feat: x\nfix: y\n'                       | bash "$S/adlc-fix-cap.sh" 3)"
eq STOP "a scoped subject adlc-fix(<scope>): counts" "$(printf 'adlc-fix(api): a\nadlc-fix: b\nadlc-fix(db): c\n' | bash "$S/adlc-fix-cap.sh" 3)"
eq GO   "adlc-fixed: is not a fix round"            "$(printf 'adlc-fixed: a\nadlc-fix-up: b\nadlc-fix: c\n' | bash "$S/adlc-fix-cap.sh" 2)"
printf 'adlc-fix: a\n' | bash "$S/adlc-fix-cap.sh" abc >/dev/null 2>&1; check 2 "a max that is not a number is an error, not a GO" $?
eq "" "…and prints no verdict" "$(printf 'adlc-fix: a\n' | bash "$S/adlc-fix-cap.sh" 3x 2>/dev/null)"
eq GO "an empty max is the default 3, not an error" "$(printf 'adlc-fix: a\nadlc-fix: b\n' | bash "$S/adlc-fix-cap.sh" '')"

echo "fix rounds (adlc-rounds.sh and the cap's --pr form, against a stub gh):"
# One definition everywhere (issues 35 and 13): a fix round of a PR is a review that sent it back,
# read from the PR's own `adlc:changes-requested` label events and CHANGES verdict comments, never
# from its commits. adlc-rounds.sh is the one place that counts; the cap, adlc-cycle.sh and
# Mission Control must all give its number.
# rounds_stub <dir>: a stub gh in <dir>/bin serving <dir>/fx. `api …/issues/N/timeline` answers
# from timeline-N.json (none → no events), `pr view N --json comments` from pr-N.json (none → no
# comments), `issue list` and `repo view` are there for adlc-cycle.sh; a file fail-timeline-N or
# fail-comments-N makes that one read fail as gh does. Every call is logged to <dir>/calls, and
# what `pr comment` was asked to post to <dir>/said.
rounds_stub() {
  mkdir -p "$1/bin" "$1/fx"; : > "$1/calls"
  cat > "$1/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$RD_DIR/calls"
case "$1 $2" in
  "pr view")    [ -f "$RD_DIR/fx/fail-comments-$3" ] && { echo "gh: HTTP 502" >&2; exit 1; }
                src="$RD_DIR/fx/pr-$3.json"; [ -f "$src" ] || src="$RD_DIR/fx/no-comments.json" ;;
  "repo view")  src="$RD_DIR/fx/repo.json" ;;
  "issue list") src="$RD_DIR/fx/issues.json" ;;
  "pr comment") shift 2; echo "comment $*" >> "$RD_DIR/said"; exit 0 ;;
  api*)         n=$(printf '%s' "$2" | sed -nE 's#.*/issues/([0-9]+)/timeline.*#\1#p')
                [ -f "$RD_DIR/fx/fail-timeline-$n" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                src="$RD_DIR/fx/timeline-$n.json"; [ -f "$src" ] || src="$RD_DIR/fx/empty.json" ;;
  *) exit 2 ;;
esac
f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done
jq -r "$f" "$src"
SH
  chmod +x "$1/bin/gh"; echo '[]' > "$1/fx/empty.json"; echo '{"comments": []}' > "$1/fx/no-comments.json"
  echo '{"nameWithOwner":"acme/shop"}' > "$1/fx/repo.json"
}
# rounds_labels <dir> <pr> <n>: the PR's timeline as the lanes leave it after n requests for changes: the label
# put on and taken off again each time, among events that are not a round
rounds_labels() {
  jq -n --argjson n "$3" '[{event: "labeled", label: {name: "lane:full"}}, {event: "commented"}]
    + [range(0; $n) | ({event: "labeled", label: {name: "adlc:changes-requested"}}, {event: "unlabeled", label: {name: "adlc:changes-requested"}})]
    + [{event: "labeled", label: {name: "needs:human"}}]' > "$1/fx/timeline-$2.json"
}
# rounds_comments <dir> <pr> <comment body>…
rounds_comments() {
  local d="$1" pr="$2" b; shift 2
  for b in "$@"; do jq -n --arg b "$b" '{body: $b}'; done | jq -s '{comments: .}' > "$d/fx/pr-$pr.json"
}
if command -v jq >/dev/null 2>&1; then
  RD="$(mktemp -d)"; rounds_stub "$RD"
  rd()  { ( cd "$RD" && env PATH="$RD/bin:$PATH" RD_DIR="$RD" bash "$S/adlc-rounds.sh" "$@" ); }
  cap() { ( cd "$RD" && env PATH="$RD/bin:$PATH" RD_DIR="$RD" bash "$S/adlc-fix-cap.sh" "$@" ); }
  # PR 1: no review sent it back · PR 2: the Actions lane labelled it twice, and no verdict comment is left to read
  rounds_labels "$RD" 2 2
  # PR 3: a repo run by hand, no label: the adversarial reviewer asked three times (markup is fine), the Architect once
  rounds_comments "$RD" 3 $'Two findings.\nADLC-FINDING: High | authz-gap | src/a.py\n\nADLC-ADV: CHANGES' $'Off the ADR.\n\n**ADLC-ARCH: CHANGES**' \
    $'One left.\n\n`ADLC-ADV: CHANGES`' $'And its test.\n\n**ADLC-ADV:** CHANGES' 'ADLC-ADV: PASS' 'ADLC-ARCH: PASS'
  # PR 4: both sources, the comments ahead (2 label events, 3 CHANGES) · PR 5: the labels ahead (3 events, 1 CHANGES)
  rounds_labels "$RD" 4 2; rounds_comments "$RD" 4 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES' 'ADLC-ARCH: CHANGES'
  rounds_labels "$RD" 5 3; rounds_comments "$RD" 5 'ADLC-ARCH: CHANGES' 'ADLC-ADV: PASS'
  # PR 6: CHANGES only quoted in a comment that ends PASS, and near-markers that are no verdict
  rounds_comments "$RD" 6 $'The earlier ADLC-ADV: CHANGES is addressed.\n\nADLC-ADV: PASS' 'ADLC-ADV: CHANGESET' 'ADLC-ARCH: changes' 'ADLC-ADV-X: CHANGES'
  # PR 7: the timeline cannot be read (its comments hold 3 CHANGES) · PR 8: the comments cannot (its timeline holds 2 events)
  rounds_comments "$RD" 7 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES'; : > "$RD/fx/fail-timeline-7"
  rounds_labels "$RD" 8 2; : > "$RD/fx/fail-comments-8"
  # PR 9: sent back four times
  rounds_labels "$RD" 9 4
  eq 0 "rounds: a PR no review sent back → 0"                                  "$(rd 1 2>&1)"
  : > "$RD/calls"
  eq 2 "rounds: label events only (the Actions lane) → one per time the label was put on; taking it off, and other labels, are not rounds" "$(rd 2 2>&1)"
  eq "1 1" "rounds: one timeline call and one pr view call" "$(grep -c '^api ' "$RD/calls") $(grep -c '^pr view$' "$RD/calls")"
  eq 3 "rounds: verdict comments only (a repo run by hand) → CHANGES per marker, the larger marker; markup after the colon is fine" "$(rd 3 2>&1)"
  eq 3 "rounds: both sources, comments ahead → the larger (not 2, not 2 + 3)"  "$(rd 4 2>&1)"
  eq 3 "rounds: both sources, labels ahead → the larger (not 1, not 3 + 1)"    "$(rd 5 2>&1)"
  eq 0 "rounds: a CHANGES quoted inside a comment that ends PASS is a PASS; CHANGESET, lowercase and ADLC-ADV-X are no verdict" "$(rd 6 2>&1)"
  eq 4 "rounds: four requests → 4"                                             "$(rd 9 2>&1)"
  rd 7 >"$RD/out" 2>"$RD/err"; check 1 "rounds: a timeline that cannot be read is exit 1" $?
  eq "" "…with nothing on stdout (not the 3 its comments would give, not 0)" "$(cat "$RD/out")"
  eq 1 "…and a line on stderr that names the PR" "$(grep -c 'adlc-rounds: could not read the timeline of PR #7' "$RD/err")"
  eq 1 "…beside gh's own error" "$(grep -c 'HTTP 404' "$RD/err")"
  rd 8 >"$RD/out" 2>"$RD/err"; check 1 "rounds: comments that cannot be read are exit 1" $?
  eq "" "…with nothing on stdout (not the 2 its label events would give)" "$(cat "$RD/out")"
  eq 1 "…and a line on stderr that names the PR" "$(grep -c 'adlc-rounds: could not read the comments of PR #8' "$RD/err")"
  rd >/dev/null 2>&1;       check 2 "rounds: no PR number is a usage error" $?
  rd abc >/dev/null 2>&1;   check 2 "rounds: a PR number that is not a number is a usage error" $?
  rd 2 3 >/dev/null 2>&1;   check 2 "rounds: a second argument is a usage error (the max belongs to the cap)" $?
  # the cap, --pr form: GO while rounds <= max, STOP past it; the request being handled is one of the rounds
  eq GO   "cap --pr: 0 rounds → GO"                                            "$(cap --pr 1 2>&1)"
  eq GO   "cap --pr: 3 rounds → GO (the third request still gets its Builder round)" "$(cap --pr 4 2>&1)"
  eq STOP "cap --pr: 4 rounds → STOP"                                          "$(cap --pr 9 2>&1)"
  eq GO   "cap --pr: max 3 is the default, and an empty max is the default too" "$(cap --pr 5 '' 2>&1)"
  eq "GO STOP" "cap --pr: a max of its own (2 rounds: GO at max 2, STOP at max 1)" "$(cap --pr 2 2 2>&1) $(cap --pr 2 1 2>&1)"
  cap --pr 7 >"$RD/out" 2>"$RD/err"; check 1 "cap --pr: a timeline that cannot be read is exit 1" $?
  eq "" "…and no decision on stdout: never a GO" "$(cat "$RD/out")"
  eq 1 "…and it says so on stderr" "$(grep -c 'adlc-fix-cap: could not count the fix rounds of PR #7' "$RD/err")"
  cap --pr 8 >"$RD/out" 2>/dev/null; check 1 "cap --pr: comments that cannot be read are exit 1" $?
  eq "" "…and no decision on stdout" "$(cat "$RD/out")"
  eq "" "cap --pr: no PR number → no decision"                  "$(cap --pr 2>/dev/null)";      cap --pr >/dev/null 2>&1;     check 2 "…exit 2" $?
  eq "" "cap --pr: a PR number that is not a number → no decision" "$(cap --pr abc 2>/dev/null)"; cap --pr abc >/dev/null 2>&1; check 2 "…exit 2" $?
  eq "" "cap --pr: a max that is not a number → no decision"    "$(cap --pr 1 3x 2>/dev/null)"; cap --pr 1 3x >/dev/null 2>&1; check 2 "…exit 2" $?
  # the cap finds adlc-rounds.sh beside itself, whatever the working directory; a copy without it gives no decision
  mkdir -p "$RD/alone"; cp "$S/adlc-fix-cap.sh" "$RD/alone/"
  ( cd "$RD" && env PATH="$RD/bin:$PATH" RD_DIR="$RD" bash "$RD/alone/adlc-fix-cap.sh" --pr 1 ) >"$RD/out" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] && ok "cap --pr: without adlc-rounds.sh beside it the cap fails (exit $rc)" || bad "cap --pr: without adlc-rounds.sh beside it the cap must fail"
  eq "" "…and prints no decision" "$(cat "$RD/out")"
  grep -q 'bash "$(dirname "$0")/adlc-rounds.sh" "$pr"' "$S/adlc-fix-cap.sh" && ok "the cap counts through adlc-rounds.sh" || bad "adlc-fix-cap.sh --pr must count through adlc-rounds.sh"
  # adlc-cycle.sh: the same script, so the same number; its own callers still get rounds: null when the PR cannot be read
  grep -q 'bash "$(dirname "$0")/adlc-rounds.sh" "$1"' "$S/adlc-cycle.sh" && ok "adlc-cycle.sh counts through adlc-rounds.sh" || bad "adlc-cycle.sh must count rounds through adlc-rounds.sh"
  eq 0 "…and holds no copy of the count" "$(grep -cE 'ADLC-\(ADV\|ARCH\)|changes-requested"' "$S/adlc-cycle.sh" || true)"
  rnow=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rounds_issue() { # <issue> <its PR>: an issue at intake, cross-referenced by that PR
    jq -n --arg t "$rnow" --argjson pr "$2" '[{event: "labeled", created_at: $t, label: {name: "stage:intake"}},
      {event: "cross-referenced", created_at: $t, source: {issue: {number: $pr, repository: {full_name: "acme/shop"}, pull_request: {url: "x"}}}}]' > "$RD/fx/timeline-$1.json"
  }
  rounds_issue 20 4; rounds_issue 21 8; rounds_issue 22 7
  jq -n --arg t "$rnow" '[20, 21, 22] | map({number: ., title: "x", createdAt: $t, closedAt: null, labels: []})' > "$RD/fx/issues.json"
  OUT=$( cd "$RD" && env PATH="$RD/bin:$PATH" RD_DIR="$RD" bash "$S/adlc-cycle.sh" issues 7 2>"$RD/err" ); check 0 "cycle: runs to the end although two PRs could not be read" $?
  eq "20=3 21=null 22=null" "cycle: rounds is adlc-rounds.sh's number for the linked PR, and null when its comments or its timeline cannot be read" \
     "$(printf '%s\n' "$OUT" | jq -r '"\(.issue)=\(.rounds)"' | tr '\n' ' ' | sed 's/ $//')"
  eq 2 "…each named on stderr, as before" "$(grep -c 'adlc-cycle: could not read the timeline or the comments of PR #[78] (issue #2[12]); rounds unknown' "$RD/err")"
  # Mission Control counts with the same rule (mission-control/mc/pipeline.py, fix_rounds): run both over the same PRs
  if command -v python3 >/dev/null 2>&1; then
    mcr() { python3 -B - "$ROOT/mission-control" "$RD/fx/timeline-$1.json" "$RD/fx/pr-$1.json" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
from mc import pipeline
load = lambda path, default: json.load(open(path)) if os.path.exists(path) else default
events, comments = load(sys.argv[2], []), load(sys.argv[3], {'comments': []})['comments']
labelled = [i for i, e in enumerate(events) if e.get('event') == 'labeled' and (e.get('label') or {}).get('name') == pipeline.CHANGES_LABEL]
print(len(pipeline.fix_rounds(labelled, [{'ts': i, 'body': c['body']} for i, c in enumerate(comments)])))
PY
    }
    same=""; for n in 1 2 3 4 5 6 9; do same="$same$n:$(rd "$n" 2>&1)=$(mcr "$n" 2>&1) "; done
    eq "1:0=0 2:2=2 3:3=3 4:3=3 5:3=3 6:0=0 9:4=4 " "Mission Control's fix_rounds gives adlc-rounds.sh's number for every PR above" "$same"
  else
    bad "the Mission Control half of the fix-rounds checks needs python3"
  fi
  rm -rf "$RD"
else
  echo "  · skipped the fix-rounds checks (need jq)"
fi

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
# which commits a push asks about (issue 39): the range decision is the script's, not inline YAML
TWC() { bash "$S/adlc-tripwire-check.sh" range "$@" 2>/dev/null; }
eq "abc123..def456" "range: an ordinary push walks before..after" "$(TWC false abc123 def456)"
eq "def456 -n 1" "range: a new branch (all-zero before) asks about the new commit alone" "$(TWC false 0000000000 def456)"
eq "FORCED" "range: a force-push has no range to walk (before is no longer on the branch)" "$(TWC true abc123 def456)"
TWC true abc123 def456 >/dev/null;  check 0 "…and says so with exit 0: the workflow alerts, the script only decides" $?
TWC "" abc123 def456 >/dev/null;    check 2 "range: an event with no forced field is an error, not an ordinary push" $?
TWC false abc123 "" >/dev/null;     check 2 "range: a missing commit id is an error" $?
TWC false 'abc; rm' def456 >/dev/null; check 2 "range: a commit id that is not hexadecimal is an error" $?
TWY="$ROOT/templates/github/adlc-main-tripwire.yml"
grep -q 'FORCED: \${{ github.event.forced }}' "$TWY" && ok "adlc-main-tripwire.yml reads github.event.forced" || bad "adlc-main-tripwire.yml: must pass github.event.forced to the step"
grep -qE '^\s+range=\$\(\.adlc/scripts/adlc-tripwire-check\.sh range "\$FORCED" "\$BEFORE" "\$AFTER"\)$' "$TWY" && ok "…and asks the script for the range, in a statement of its own" || bad "adlc-main-tripwire.yml: the range must come from adlc-tripwire-check.sh range"
eq 1 "…alerts on a force-push before any rev-list" "$(awk '/adlc-tripwire-alert.sh forced "\$BEFORE" "\$AFTER"/ { f = NR } /git rev-list/ { r = NR } END { print (f && r && f < r) ? 1 : 0 }' "$TWY")"
grep -q 'adlc-tripwire-alert.sh direct \$shas' "$TWY" && ok "…and files a direct push through the alert script" || bad "adlc-main-tripwire.yml: a direct push must be filed by adlc-tripwire-alert.sh"
grep -q 'gh issue create\|--label "bug"' "$TWY" && bad "adlc-main-tripwire.yml must not file the issue inline, nor as a bug (issue 21)" || ok "…with no inline gh issue create and no bug label (issue 21: a direct push is not a defect)"
eq "contents: read|issues: write|pull-requests: read|" "…with the permissions it had (the alert listing needs no more than issues: write)" "$(sed -n '/^permissions:/,/^jobs:/p' "$TWY" | grep -E '^  [a-z-]+: ' | sed 's/^  //' | tr '\n' '|')"

echo "tripwire-alert (the alert issue, against a stub gh):"
# Issue 39: the tripwire filed the same four commits twice, a minute apart. The alert's body now
# ends with a machine-readable line and the script files nothing while an open adlc:tripwire issue
# carries the same line. Issue 21: the label is adlc:tripwire, not bug, and a repo without that
# label still gets the alert. The stub serves `issue list` from $TW/labelled.json (a --label
# filter was passed) or $TW/all.json (none), and `issue create` prints a URL; a fail-* or no-label
# file makes that call fail as the real gh does.
if command -v jq >/dev/null 2>&1; then
  TW="$(mktemp -d)"; mkdir -p "$TW/bin"
  cat > "$TW/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$TW/calls"
case "$1 $2" in
  "issue list")
    src=all; for a in "$@"; do [ "$a" = "--label" ] && src=labelled; done
    [ -e "$TW/fail-list-$src" ] && { echo "HTTP 502: Server Error" >&2; exit 1; }
    cat "$TW/$src.json" ;;
  "issue create")
    label=""; body=""; title=""
    while [ $# -gt 0 ]; do case "$1" in --label) label="$2" ;; --body) body="$2" ;; --title) title="$2" ;; esac; shift; done
    if [ -n "$label" ] && [ -e "$TW/no-label" ]; then echo "could not add label: '$label' not found" >&2; exit 1; fi
    [ -e "$TW/fail-create" ] && { echo "HTTP 502: Server Error" >&2; exit 1; }
    printf '%s\n' "$body" > "$TW/body"; printf '%s\n' "$title" > "$TW/title"; echo "${label:-none}" > "$TW/label"
    echo "https://github.com/o/r/issues/7" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$TW/bin/gh"
  A1=1111111111111111111111111111111111111111; A2=2222222222222222222222222222222222222222; A3=3333333333333333333333333333333333333333
  twreset() { rm -f "$TW"/fail-* "$TW/no-label" "$TW/body" "$TW/title" "$TW/label"; echo '[]' > "$TW/labelled.json"; echo '[]' > "$TW/all.json"; : > "$TW/calls"; }
  tw()      { TWOUT=$(TW="$TW" PATH="$TW/bin:$PATH" bash "$S/adlc-tripwire-alert.sh" "$@" 2>&1); }
  creates() { grep -c '^issue create ' "$TW/calls"; }
  open_issue() { jq -cn --argjson n "$1" --arg b "$2" '[{number: $n, body: $b}]'; }   # <number> <body>
  twreset; tw direct "$A2" "$A1"; check 0 "direct: no open alert → the issue is filed" $?
  eq "adlc:tripwire" "…with the label adlc:tripwire (not bug)" "$(cat "$TW/label")"
  eq "ADLC-TRIPWIRE: direct $A1 $A2" "…its body ends with the machine-readable line, the ids sorted" "$(tail -n 1 "$TW/body")"
  eq 1 "…after one listing of the open alerts, by label, with their bodies" "$(grep -c '^issue list --state open --label adlc:tripwire --limit 200 --json number,body$' "$TW/calls")"
  eq 1 "…and names the commits and the branch in its text" "$(grep -c "reached \`main\` with no associated merged PR: $A1 $A2" "$TW/body")"
  FILED="$(cat "$TW/body")"
  twreset; open_issue 41 "$FILED" > "$TW/labelled.json"; tw direct "$A1" "$A2"; check 0 "direct: an open alert for the same commits → exit 0" $?
  eq 0 "…and no second issue is filed" "$(creates)"
  case "$TWOUT" in *"issue #41"*) ok "…the output names the open alert" ;; *) bad "a duplicate must name the open alert (got: $TWOUT)" ;; esac
  eq 1 "…with no comment on it either (one gh call: the listing)" "$(grep -c . "$TW/calls")"
  twreset; open_issue 41 "$(printf '%s' "$FILED" | awk '{ printf "%s\r\n", $0 }')" > "$TW/labelled.json"; tw direct "$A2" "$A1"
  eq 0 "…also when the open alert's body has CRLF line ends and the ids come in another order" "$(creates)"
  twreset; open_issue 41 "$FILED" > "$TW/labelled.json"; tw direct "$A1" "$A2" "$A3"; check 0 "direct: an open alert for a different set of commits → filed" $?
  eq 1 "…one new issue" "$(creates)"
  twreset; open_issue 41 "$FILED" > "$TW/labelled.json"; tw direct "$A1"
  eq 1 "…a subset of an open alert's commits is a different set too (the line is compared whole)" "$(creates)"
  twreset; open_issue 41 "As the alert said: ADLC-TRIPWIRE: direct $A1 $A2 (quoted)" > "$TW/labelled.json"; tw direct "$A1" "$A2"
  eq 1 "…and the line quoted inside a sentence is not the line" "$(creates)"
  twreset; : > "$TW/fail-list-labelled"; tw direct "$A1"; check 0 "direct: the listing fails → the alert is filed anyway (when in doubt, file)" $?
  eq 1 "…one issue" "$(creates)"
  case "$TWOUT" in *"could not list"*) ok "…and the failed read is said" ;; *) bad "a failed listing must be said (got: $TWOUT)" ;; esac
  twreset; echo 'not json' > "$TW/labelled.json"; tw direct "$A1"
  eq 1 "…a listing that is not JSON files too" "$(creates)"
  twreset; : > "$TW/no-label"; tw direct "$A1"; check 0 "direct: the label does not exist in the repo → still filed" $?
  eq none "…without a label" "$(cat "$TW/label")"
  eq 2 "…on the second attempt" "$(creates)"
  eq "ADLC-TRIPWIRE: direct $A1" "…with the same machine-readable line" "$(tail -n 1 "$TW/body")"
  twreset; : > "$TW/no-label"; open_issue 52 "$(printf 'x\n\nADLC-TRIPWIRE: direct %s' "$A1")" > "$TW/all.json"; tw direct "$A1"; check 0 "…and an unlabelled open alert for the same commits is found before filing unlabelled" $?
  eq 1 "…so only the refused labelled attempt was made" "$(creates)"
  eq 1 "…the second listing carries no label filter" "$(grep -c '^issue list --state open --limit 200 --json number,body$' "$TW/calls")"
  twreset; : > "$TW/no-label"; : > "$TW/fail-list-all"; tw direct "$A1"
  eq none "…a failed second listing files the unlabelled alert" "$(cat "$TW/label" 2>/dev/null)"
  twreset; : > "$TW/fail-create"; tw direct "$A1"; check 1 "direct: gh cannot create the issue at all → exit 1" $?
  twreset; tw forced "$A2" "$A1"; check 0 "forced: the alert is filed" $?
  eq "ADLC-TRIPWIRE: forced $A2 $A1" "…its line keeps before and after in order" "$(tail -n 1 "$TW/body")"
  eq 1 "…the text says the branch was force-pushed and from where to where" "$(grep -c "was force-pushed: its tip moved from $A2 to $A1" "$TW/body")"
  case "$(cat "$TW/title")" in *"Force-push to main"*"history was rewritten"*) ok "…and so does the title" ;; *) bad "forced: the title must say the history was rewritten (got: $(cat "$TW/title"))" ;; esac
  FORCED_BODY="$(cat "$TW/body")"
  twreset; open_issue 60 "$FORCED_BODY" > "$TW/labelled.json"; tw forced "$A2" "$A1"
  eq 0 "forced: the same rewrite is not filed twice" "$(creates)"
  twreset; open_issue 60 "$FORCED_BODY" > "$TW/labelled.json"; tw forced "$A1" "$A2"
  eq 1 "…the reverse move is another event" "$(creates)"
  twreset; open_issue 60 "$FORCED_BODY" > "$TW/labelled.json"; tw direct "$A1" "$A2"
  eq 1 "…and a direct push of the same two ids is not a force-push" "$(creates)"
  twreset; TWOUT=$(ADLC_TRIPWIRE_BRANCH=trunk TW="$TW" PATH="$TW/bin:$PATH" bash "$S/adlc-tripwire-alert.sh" direct "$A1" 2>&1)
  case "$(cat "$TW/title")" in *"Direct push to trunk"*) ok "ADLC_TRIPWIRE_BRANCH names the branch in the text" ;; *) bad "the title must name the branch (got: $(cat "$TW/title"))" ;; esac
  twreset; tw direct;               check 2 "bad arguments: direct with no commit" $?
  tw forced "$A1";                  check 2 "bad arguments: forced with one commit" $?
  tw direct "$A1" 'x y';            check 2 "bad arguments: a commit id that is not hexadecimal" $?
  tw sideways "$A1";                check 2 "bad arguments: an unknown kind" $?
  tw;                               check 2 "bad arguments: none" $?
  eq 0 "…none of which reached gh" "$(grep -c . "$TW/calls")"
  rm -rf "$TW"
else
  echo "  · skipped the tripwire-alert checks (no jq here)"
fi

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
  "label list"*)  here && printf '%s\n' stage:intake gate:stories stage:design stage:build stage:qa gate:deploy
                  here && [ ! -e "$DFX/old-labels" ] && printf '%s\n' adlc:change-failure adlc:tripwire   # old-labels: a repo set up before issue 21
                  here && [ ! -e "$DFX/no-chain-labels" ] && printf '%s\n' adlc:follow-up adlc:accepted-risk
                  exit 0 ;;
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
# issue 21: the two labels a script filters on — a repo whose labels predate them (labels.sh not re-run)
gate true 1 none; : > "$FIX/fx/old-labels"
GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1); check 1 "labels: a repo without adlc:change-failure is flagged" $?
eq yes "…naming the label and the fix" "$(says_gate "missing GitHub label: adlc:change-failure (the change-failure metric counts issues that carry it) — re-run the plugin's templates/github/labels.sh")"
eq no  "…adlc:tripwire is not asked for where the tripwire is not installed" "$(says_gate "missing GitHub label: adlc:tripwire")"
gate false - none tripwire; : > "$FIX/fx/old-labels"
GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1)
eq yes "…and is where it is, saying the alerts are filed unlabelled without it" "$(says_gate "missing GitHub label: adlc:tripwire (the tripwire files its alerts under it; without it they are filed unlabelled)")"
gate false - none tripwire;  check 0 "labels: with both labels and the tripwire installed, nothing is flagged" $?
eq no  "…no missing label" "$(says_gate "missing GitHub label")"
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
# the follow-up chain labels (issue 37): a repo set up before them has the six state labels only
gate true 1 none; touch "$FIX/fx/no-chain-labels"
GATE=$(DFX="$FIX/fx" DFX_ROOT="$FIX" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1); check 1 "labels: a repo without the two follow-up chain labels is flagged" $?
eq yes "…naming adlc:follow-up, and the script that creates it" "$(says_gate "missing GitHub label: adlc:follow-up (follow-up chains; run the plugin's templates/github/labels.sh again")"
eq yes "…and adlc:accepted-risk" "$(says_gate "missing GitHub label: adlc:accepted-risk")"
eq no  "…not a state label, which it has" "$(says_gate "missing GitHub label: stage:")"
rm -f "$FIX/fx/no-chain-labels"
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

echo "fix-loop cap step (the workflow's own run: script, on a real git history, against a stub gh):"
# The cap bounds the fix rounds of ONE pull request, and a round is a review that sent it back
# (adlc-rounds.sh). The step once counted `adlc-fix:` commit subjects: first over the whole
# history of the PR head, then over `<base>..HEAD`. That still charged a PR for the fix commits
# its branch carried from another PR (issue 13: a stacked PR whose parent was squash-merged, a
# promotion PR), stopped a Builder after one round when it had made three commits in it, and
# never stopped one that left the prefix out (issue 35). Run the step as shipped, in a checkout
# shaped like the runner's whose history holds exactly those commits, with each PR's own record
# served by the stub gh. Nothing here has a remote, and nothing is pushed.
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  FC="$(mktemp -d)"; FW="$ROOT/templates/github/adlc-fix.yml"
  step_run "$FW" '- name: Loop cap' > "$FC/cap.sh"
  rounds_stub "$FC"
  fgit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
  fbranch() { # <new branch> <from> <commit subject>… — cut the branch, one commit per subject
    local b="$1" from="$2" s; shift 2
    fgit -C "$FC/seed" checkout -q -b "$b" "$from"
    for s in "$@"; do fgit -C "$FC/seed" commit -q --allow-empty -m "$s"; done
  }
  {
    fgit init -q "$FC/seed"; fgit -C "$FC/seed" symbolic-ref HEAD refs/heads/main
    mkdir -p "$FC/seed/.adlc/scripts"; cp "$S/adlc-fix-cap.sh" "$S/adlc-rounds.sh" "$FC/seed/.adlc/scripts/"
    fgit -C "$FC/seed" add -A; fgit -C "$FC/seed" commit -q -m init
    fgit -C "$FC/seed" branch production main                                           # promoted so far: nothing after init
    fbranch feat/1-old     main 'feat: old' 'adlc-fix: a' 'adlc-fix: b' 'adlc-fix: c'   # an earlier PR: 3 fix commits…
    fgit -C "$FC/seed" checkout -q main
    fgit -C "$FC/seed" merge -q --no-ff -m 'Merge pull request #1 from o/feat/1-old' feat/1-old   # …merged with a merge commit
    fbranch feat/6-parent  main 'feat: parent' 'adlc-fix: a' 'adlc-fix: b' 'adlc-fix: c'
    fbranch feat/7-stacked feat/6-parent 'feat: stacked'                                # PR 7, built on PR 6's branch
    fgit -C "$FC/seed" checkout -q main
    fgit -C "$FC/seed" commit -q --allow-empty -m 'feat: parent (#6)'                   # PR 6 squash-merged: one new commit, none of its own
    # PR 9: three rounds, three commits each · PR 10: a Builder that left the prefix out
    fbranch feat/9-nine    main 'feat: nine' 'adlc-fix: a1' 'adlc-fix: a2' 'adlc-fix: a3' 'adlc-fix: b1' 'adlc-fix: b2' 'adlc-fix: b3' 'adlc-fix: c1' 'adlc-fix: c2' 'adlc-fix: c3'
    fbranch feat/10-plain  main 'feat: plain' 'address the review' 'address the review again' 'and again'
  } >/dev/null 2>&1
  # each PR's own record: 7 (stacked) and 8 (promotion: main → production) were never reviewed; 9 was sent back
  # three times, by label and by verdict; 10 four times; 11's timeline and 12's comments cannot be read
  rounds_labels "$FC" 9 3;  rounds_comments "$FC" 9 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES' 'ADLC-ARCH: PASS'
  rounds_labels "$FC" 10 4
  : > "$FC/fx/fail-timeline-11"; : > "$FC/fx/fail-comments-12"
  # caprun <PR head> <PR number> — the step, run as Actions does (bash -e), in a checkout as actions/checkout leaves
  # it with fetch-depth: 0: every branch a remote-tracking ref, the PR head the only local branch.
  caprun() {
    rm -rf "$FC/run"; : > "$FC/out"; : > "$FC/said"
    { fgit init -q "$FC/run" && fgit -C "$FC/run" fetch -q "$FC/seed" '+refs/heads/*:refs/remotes/origin/*' \
        && fgit -C "$FC/run" checkout -q -B "$1" "refs/remotes/origin/$1"; } >/dev/null 2>&1 || return 99
    ( cd "$FC/run" && env PATH="$FC/bin:$PATH" RD_DIR="$FC" PR="$2" GH_TOKEN=t GITHUB_OUTPUT="$FC/out" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -e "$FC/cap.sh" ) > "$FC/said" 2>/dev/null
  }
  capsaid() { cat "$FC/said" "$FC/out" | tr '\n' ' '; }   # its decision + the output it set
  # oldcap <base> — what counting the checkout's `adlc-fix:` commits against that base would decide (the older form)
  oldcap()  { local subjects; subjects=$(fgit -C "$FC/run" log --format='%s' "refs/remotes/origin/$1..HEAD" --) || { echo "?"; return; }; printf '%s\n' "$subjects" | bash "$S/adlc-fix-cap.sh" 3; }
  [ -s "$FC/cap.sh" ] && ok "run: script extracted from the template" || bad "could not extract the run: script"
  # issue 13's two cases: the branch carries another PR's fix commits, and no review of its own
  caprun feat/7-stacked 7
  eq STOP "fixture: the stacked PR, retargeted to main after its parent's squash merge, carries the parent's 3 adlc-fix: commits" "$(oldcap main)"
  eq "decision=GO stop=false " "a stacked PR whose parent was squash-merged starts at round 0 → GO (was: STOP at its first review)" "$(capsaid)"
  caprun main 8
  eq STOP "fixture: the promotion PR (main → production) carries every fix commit merged since the last promotion" "$(oldcap production)"
  eq "decision=GO stop=false " "a promotion PR starts at round 0 → GO (was: STOP)" "$(capsaid)"
  # issue 35: rounds, not commits
  caprun feat/9-nine 9
  eq STOP "fixture: the PR holds nine adlc-fix: commits" "$(oldcap main)"
  eq "decision=GO stop=false " "nine fix commits in three rounds: the third request still gets its Builder round → GO" "$(capsaid)"
  caprun feat/10-plain 10
  eq GO   "fixture: the PR holds no adlc-fix: commit at all" "$(oldcap main)"
  eq "decision=STOP stop=true " "sent back a fourth time → STOP, whatever its commits are called (the commit count never stopped it)" "$(capsaid)"
  # the PR number and the token reach the script through env:, never written into it by ${{ }}
  case "$(cat "$FC/cap.sh")" in *'${{'*) bad "the script has no \${{ }} expression written into it" ;; *) ok "the script has no \${{ }} expression written into it" ;; esac
  capenv() { awk '/^      - / { s = ($0 ~ /- name: Loop cap/) } s' "$FW" | tr -d "\"'" | grep -cE "$1" || true; }
  eq 1 "the step's env: hands it the PR number as PR"   "$(capenv '^ +PR: \$\{\{ github\.event\.pull_request\.number \}\}[[:space:]]*$')"
  eq 1 "the step's env: hands gh a token (GH_TOKEN) to read the PR with" "$(capenv '^ +GH_TOKEN: \$\{\{ (github\.token|secrets\.[A-Z_]+) \}\}([[:space:]]|$)')"
  grep -q 'adlc-fix-cap\.sh --pr "\$PR" 3' "$FC/cap.sh" && ok "the step asks the cap for this PR's rounds (--pr), max 3" || bad "the step must call adlc-fix-cap.sh --pr \"\$PR\" 3"
  eq 0 "the step reads no commits (no git log)" "$(grep -vE '^[[:space:]]*#' "$FC/cap.sh" | grep -c 'git ' || true)"
  # a count that cannot be taken must stop the step: read as "0 rounds" it would never cap
  caprun feat/10-plain 11; rc=$?   # (99 = the fixture checkout itself failed)
  case "$rc" in 0|99) bad "a timeline gh cannot read fails the step (exit $rc)" ;; *) ok "a timeline gh cannot read fails the step" ;; esac
  eq "" "…with no decision and no output (not a GO)" "$(capsaid)"
  caprun feat/10-plain 12; rc=$?
  case "$rc" in 0|99) bad "comments gh cannot read fail the step (exit $rc)" ;; *) ok "comments gh cannot read fail the step" ;; esac
  eq "" "…with no decision and no output (not a GO)" "$(capsaid)"
  # …and the next step says so on the PR: the label is still on, the Builder did not run, and a red run is easy to miss
  step_run "$FW" '- name: Say that the cap could not run' > "$FC/tell.sh"; : > "$FC/said"
  ( cd "$FC/run" && env PATH="$FC/bin:$PATH" RD_DIR="$FC" PR=12 GH_TOKEN=t GITHUB_SERVER_URL=https://example.test GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 bash -e "$FC/tell.sh" ) >/dev/null 2>&1
  case "$(tr '\n' ' ' < "$FC/said")" in "comment 12 --body ⚠️ The fix-loop cap could not count this PR's fix rounds, so the Builder did not run."*"https://example.test/o/r/actions/runs/42 ") ok "a cap that could not run is said on the PR, with a link to the run" ;;
    *) bad "a cap that could not run is said on the PR, with a link to the run (got '$(cat "$FC/said")')" ;; esac
  eq 1 "…by a step that runs only when the cap step itself failed" \
     "$(awk '/^      - / { s = ($0 ~ /- name: Say that the cap could not run/) } s' "$FW" | grep -cE "^ +if: (failure|always)\(\) && steps\.cap\.outcome == 'failure'[[:space:]]*$" || true)"
  # an answer that is neither STOP nor GO is no GO either
  printf '#!/usr/bin/env bash\necho MAYBE\n' > "$FC/seed/.adlc/scripts/adlc-fix-cap.sh"
  { fgit -C "$FC/seed" checkout -q feat/10-plain && fgit -C "$FC/seed" commit -q -am 'a cap that answers neither'; } >/dev/null 2>&1
  caprun feat/10-plain 7; rc=$?
  case "$rc" in 0|99) bad "an answer that is neither STOP nor GO fails the step (exit $rc)" ;; *) ok "an answer that is neither STOP nor GO fails the step" ;; esac
  eq "" "…and sets no output" "$(cat "$FC/out")"
  grep -qE '^ +fetch-depth: 0([[:space:]]|$)' "$FW" && ok "adlc-fix.yml checks out the full history (the Builder compares its branch with the base)" \
    || bad "adlc-fix.yml must check out with fetch-depth: 0 — the Builder compares its branch with the base"
  rm -rf "$FC"
else
  bad "fix-loop cap step tests need git and jq"
fi
# the same cap by hand, and the scope round trip (issue 35)
RBK="$ROOT/templates/RUNBOOK.md.tmpl"; RSB="$ROOT/skills/role-builder/SKILL.md"; RSA="$ROOT/skills/role-architect/SKILL.md"
grep -q '\.adlc/scripts/adlc-fix-cap\.sh --pr <pr>' "$RBK" && ok "RUNBOOK: the fix cycle runs the cap (--pr) before the PR goes back to the Builder" || bad "RUNBOOK: the fix cycle must run adlc-fix-cap.sh --pr <pr>"
grep -q 'gh pr edit <pr> --add-label needs:human' "$RBK" && ok "RUNBOOK: on STOP the PR is labelled needs:human" || bad "RUNBOOK: on STOP the PR must be labelled needs:human"
grep -q 'ADLC-SCOPE-REQUEST: <path prefix> | <one-line reason>' "$RSB" && ok "role-builder: a path outside the scope is asked for with ADLC-SCOPE-REQUEST" || bad "role-builder must carry the ADLC-SCOPE-REQUEST marker"
grep -q 'do not touch it' "$RSB" && ok "…and not touched" || bad "role-builder: a path outside the scope must not be touched"
for m in 'ADLC-SCOPE: GRANT <path prefix>' 'ADLC-SCOPE: DENY <path prefix>'; do
  grep -q "$m" "$RSB" && ok "role-builder names the answer '$m'" || bad "role-builder must name '$m'"
  grep -q "$m" "$RSA" && ok "role-architect answers with '$m'" || bad "role-architect must carry '$m'"
done
grep -q 'ADLC-SCOPE-REQUEST: <path prefix> | <reason>' "$RSA" && ok "role-architect knows the request marker" || bad "role-architect must name the ADLC-SCOPE-REQUEST marker"
grep -q 'end that review CHANGES' "$RSA" && ok "role-architect: a grant comes with a CHANGES verdict (the loop returns the PR to the Builder)" || bad "role-architect: a grant must come with a CHANGES verdict"
grep -q 'post a PR comment whose last line is `ADLC-ARCH: PASS` or' "$RSA" && ok "role-architect: outside the lanes the verdict is a PR comment marker too (what the cap counts)" || bad "role-architect: outside the lanes the verdict must also be a PR comment marker"
# …plus the local orchestrator, which only looks for an unanswered request (it sends that PR to the review, not to a stop)
eq "skills/autopilot/SKILL.md skills/role-architect/SKILL.md skills/role-builder/SKILL.md " "the scope markers live in the two role prompts and the autopilot, and in no other prompt, lane or template" \
   "$(cd "$ROOT" && grep -rl 'ADLC-SCOPE' skills agents commands templates hooks 2>/dev/null | sort | tr '\n' ' ')"
eq "" "…and the autopilot names the request only: the answer stays the Architect's" "$(grep -n 'ADLC-SCOPE:' "$ROOT/skills/autopilot/SKILL.md" || true)"
for f in "$S"/*.sh; do
  grep -q "$(basename "$f")" "$ROOT/README.md" || bad "README's layout tree does not list $(basename "$f")"
done
grep -q 'adlc-rounds\.sh' "$ROOT/README.md" && ok "README's layout tree lists adlc-rounds.sh (and every other script)" || bad "README's layout tree must list adlc-rounds.sh"

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
echo "$*" >> "$MX_CALLS.args"   # the whole call: the change-failure cases pin the query
# `label list` serves $MX_LABELS (unset → no labels; a missing file → gh's failure); `issue list` serves $MX_ISSUES when set
if [ "$1 $2" = "label list" ] || { [ "$1 $2" = "issue list" ] && [ -n "${MX_ISSUES:-}" ]; }; then
  [ "$2 $1" = "list label" ] && src="${MX_LABELS:-/dev/null}" || src="$MX_ISSUES"
  f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done
  jq -r "$f" "$src"; exit $?
fi
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
  # failed in 3 s with no step (no job at all; a job with no step), and two local CI comments, FAIL then PASS.
  # PR 21: no Actions run, two PASS markers wearing markup. PR 22: a run that failed in 3 s but RAN its steps (a
  # real failure), a green one, and a comment that quotes a FAIL marker and ends in PASS (one PASS). PR 23: a fast
  # failure gh cannot describe and a no-step failure that took five minutes both stay failures; its four
  # near-markers (PASSED, a short sha, another word ending in ADLC-CI, no "head") are none. PR 24: one blocked
  # run (exactly 60 s; its only steps skipped or never concluded) and nothing else: no test signal from it.
  H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
  {
    mxpr 20 "$now" "Local CI on \`$H1\`, run on a local machine.

| check | result | exit | seconds |
|---|---|---|---|
| tests | FAIL | 1 | 12 |

ADLC-CI: FAIL head $H1" "ADLC-CI: PASS head $H2"
    mxpr 21 "$now" "**ADLC-CI: PASS** head \`$H1\`" "\`ADLC-CI: PASS head $H2\`"
    mxpr 22 "$now" "The marker reads \`ADLC-CI: FAIL head $H1\`; this run:
ADLC-CI: PASS head $H2"
    mxpr 23 "$now" "ADLC-CI: PASSED head $H1" 'ADLC-CI: PASS head abc1234' "MY-ADLC-CI: PASS head $H1" "ADLC-CI: PASS $H1"
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
  eq "local_ci: 5 ADLC-CI marker comments on 3 merged PRs (1 FAIL), counted above as CI runs" "local_ci: one per comment, by its last marker (a quoted FAIL before a PASS is a PASS); bold and backtick markup read; PASSED, a short sha, a longer word ending in ADLC-CI and a marker with no 'head' are not markers" "$(printf '%s\n' "$OUT" | grep '^local_ci:')"
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
  # Issue 21: the change-failure signal counted every `bug` issue, so each bug a person reported
  # through intake and each tripwire alert raised it. It now counts the issues labelled
  # adlc:change-failure (a defect Ops traced to a deploy). The stub records the whole call.
  mx() { OUT=$( cd "$MX/repo" && env PATH="$MX/bin:$PATH" MX_PRS="$MX/prs.json" MX_RUNS="$MX/runs.json" MX_JOBS="$MX/jobs" MX_CALLS="$MX/calls" "$@" bash "$S/adlc-metrics.sh" 30 2>&1 ); }
  echo '[{"name":"bug"},{"name":"adlc:change-failure"},{"name":"stage:qa"}]' > "$MX/labels.json"
  jq -n --arg at "$now" '[{createdAt: $at}, {createdAt: $at}, {createdAt: "2000-01-01T00:00:00Z"}]' > "$MX/issues.json"
  : > "$MX/calls.args"; mx MX_LABELS="$MX/labels.json" MX_ISSUES="$MX/issues.json"; check 0 "change failures: the script runs to the end" $?
  eq "change_failures: 2" "change failures: the issues in the window, printed as change_failures" "$(printf '%s\n' "$OUT" | grep '^change_failures:')"
  eq 1 "…asked for by the label adlc:change-failure, open and closed alike, in one call" "$(grep -c '^issue list --state all --label adlc:change-failure --limit 200 --json createdAt --jq ' "$MX/calls.args")"
  eq 2 "…beside one unfiltered listing, which the follow-up share reads; no other" "$(grep -c '^issue list ' "$MX/calls.args")"
  eq 0 "…and nothing is counted by the bug label any more" "$(grep -c -- '--label bug' "$MX/calls.args")"
  eq 0 "…nor printed as bugs_filed" "$(printf '%s\n' "$OUT" | grep -c '^bugs_filed')"
  echo '[{"name":"bug"},{"name":"adlc:change-failure-old"}]' > "$MX/labels.json"
  : > "$MX/calls.args"; mx MX_LABELS="$MX/labels.json" MX_ISSUES="$MX/issues.json"; check 0 "change failures: a repo without the label does not break the script" $?
  eq "change_failures: 0 (this repo has no adlc:change-failure label, so no issue carries it — run the plugin's templates/github/labels.sh)" "…it prints a zero that says why (a label with a longer name is not the label)" "$(printf '%s\n' "$OUT" | grep '^change_failures:')"
  eq 0 "…without asking for issues no label could be on" "$(grep -c '^issue list .*--label ' "$MX/calls.args")"
  mx MX_LABELS="$MX/no-such-file" MX_ISSUES="$MX/issues.json"; [ $? -ne 0 ] && ok "change failures: a label listing that fails stops the script with an error (no silent zero)" || bad "change failures: a failed label listing must stop the script"
  eq 0 "…and no change_failures line is printed" "$(printf '%s\n' "$OUT" | grep -c '^change_failures:')"
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
# issue 21: one meaning per label
for l in bug adlc:change-failure adlc:tripwire; do grep -qx "$l" "$LB/created" && ok "labels.sh creates $l" || bad "labels.sh must create $l"; done
grep -E '^create "bug" ' "$ROOT/templates/github/labels.sh" | grep -qi 'ops\|deploy' && bad "labels.sh: bug must not be described as Ops-filed or deploy-related (that is adlc:change-failure)" || ok "bug is described as any defect, not as Ops-filed"
grep -E '^create "adlc:change-failure" ' "$ROOT/templates/github/labels.sh" | grep -q 'Ops traced to a deploy' && ok "adlc:change-failure is the defect Ops traced to a deploy" || bad "labels.sh: adlc:change-failure must be described as a defect Ops traced to a deploy"
grep -q 'adlc:change-failure' "$ROOT/skills/role-qa-release-ops/SKILL.md" && ok "the QA/Ops role prompt files a deploy-caused defect with adlc:change-failure" || bad "role-qa-release-ops: must name adlc:change-failure"
grep -q 'adlc:change-failure' "$ROOT/templates/skills/release-ops.SKILL.md.tmpl" && ok "…and so does the release-ops template" || bad "release-ops template: must name adlc:change-failure"
grep -q 'add the `bug` label' "$ROOT/skills/intake/SKILL.md" && ok "intake still adds bug to a reported bug" || bad "intake: must still add the bug label"
grep -q 'adlc:change-failure' "$ROOT/skills/intake/SKILL.md" && bad "intake must not apply adlc:change-failure (it is Ops's)" || ok "…and never adlc:change-failure"
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
  # and gh cannot describe it: it stays a failure, and stderr says one was not read.
  jq -n --arg b "$T2" 'def r(id; wf; c; q; s): {databaseId: id, workflowName: wf, headBranch: "feat/42-thing", status: "completed", conclusion: c, createdAt: ($b | fromdate - q | todate), startedAt: $b, updatedAt: ($b | fromdate + s | todate)};
    [r(7; "ADLC CI"; "failure"; 0; 3), r(8; "ADLC main tripwire"; "failure"; 0; 3), r(9; "ADLC diff-scope"; "failure"; 0; 20),
     r(10; "ADLC CI"; "failure"; 200; 3), r(11; "ADLC CI"; "failure"; 0; 7)]' > "$CY/fx/runs-blocked.json"
  echo '{"jobs": []}' > "$CY/fx/jobs-7.json"; echo '{"jobs": [{"name": "tripwire", "conclusion": "failure", "steps": []}]}' > "$CY/fx/jobs-8.json"
  echo '{"jobs": [{"name": "scope", "conclusion": "failure", "steps": [{"name": "Check scope", "conclusion": "failure"}]}]}' > "$CY/fx/jobs-9.json"
  : > "$CY/calls"
  BL=$( cd "$CY/repo" && env PATH="$CY/bin:$PATH" CY_FX="$CY/fx" CY_RUNS="$CY/fx/runs-blocked.json" CY_CALLS="$CY/calls" ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" actions 7 2>"$CY/err" ); check 0 "actions, blocked account: runs to the end" $?
  eq "7:blocked 8:blocked 9:failure 10:failure 11:failure" "actions: a run that failed within 60 s of its creation with no step run is blocked; one whose steps ran, one that was slow from creation, and one gh cannot describe stay failures" "$(printf '%s\n' "$BL" | jq -rs 'map((.run_id | sub("actions:"; "")) + ":" + .outcome) | join(" ")')"
  eq "failure failure" "actions: a blocked row keeps GitHub's own conclusion beside the outcome" "$(printf '%s\n' "$BL" | jq -rs '[.[] | select(.outcome == "blocked") | .conclusion] | join(" ")')"
  eq 4 "actions: one run view call per run that failed within 60 s of its creation, none for the queued one" "$(grep -c '^run view$' "$CY/calls")"
  eq 1 "actions: the run it could not read is counted on stderr, not guessed" "$(grep -c '1 run(s) that failed within 60 s could not be read' "$CY/err")"
  ( cd "$CY/repo" && env PATH="$CY/bin:$PATH" CY_FX="$CY/fx" CY_FAIL_RUNS=1 CY_CALLS="$CY/calls" ADLC_REPO=acme/shop bash "$S/adlc-run-log.sh" actions 7 >"$CY/out" 2>"$CY/err" ); check 1 "actions: a failed run listing is an error, not an empty ledger" $?
  eq "0 1" "…no row on stdout, and stderr says what failed" "$(wc -l < "$CY/out" | tr -d ' ') $(grep -c 'could not list the workflow runs' "$CY/err")"
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
eq "OVER: 101% of the included minutes (1.0x)" "…and never reads 100%" "$(printf '%s\n' "$OUT" | tail -1)"
bud 0.5 3 1 1; check 1 "a fraction of a minute is rounded up in the estimate only (1.5 against 1 is over)" $?
for a in "" "10" "10 4" "10 4 20 2000 1" "0 4 20" "10 0 20" "10 4 0" "10 4 20 0" "0.0 4 20" "x 4 20" "10 4.6.1 20" "10 4 2.5" "10 4 20 1e3" "-10 4 20" ".5 4 20" "10 4 20 2000.5"; do
  # shellcheck disable=SC2086
  bud $a; check 2 "bad arguments are an error, never a FITS: '$a'" $?
done
eq "" "…and print no verdict" "$OUT"
grep -q 'adlc-ci-budget.sh <minutes/run> <runs/PR> <PRs/month>' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap runs the sizing helper from the plugin's templates" || bad "bootstrap: must run adlc-ci-budget.sh in the sizing step"
BS="$(sed -n '/^7a\. \*\*Actions minutes\*\*/,/^7b\. /p' "$ROOT/skills/bootstrap/SKILL.md")"
[ -n "$BS" ] && ok "bootstrap has the Actions minutes step (7a)" || bad "bootstrap: the Actions minutes step (7a) is missing"
for w in 'PRIVATE repo' '4–5' 'PRs per month' '`paths` filters' '`stage:qa`' 'adlc-local-ci.sh' 'the tripwire' 'adlc-doctor.sh'; do
  printf '%s' "$BS" | grep -qF -- "$w" && ok "bootstrap 7a names: $w" || bad "bootstrap 7a must name: $w"
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
  printf '# the battery\n\ntests: true\n  lint : echo "a: b" >/dev/null && test -f .adlc/local-ci.txt\nimage build: exit 3\nafter: cat; echo ran >> "%s/ran"\n' "$LC" > "$LC/repo/.adlc/local-ci.txt"
  mkdir "$LC/repo/src"; echo x > "$LC/repo/src/x"
  git -C "$LC/repo" add -A && git -C "$LC/repo" commit -qm init
  HEAD_SHA="$(git -C "$LC/repo" rev-parse HEAD)"; echo "$HEAD_SHA" > "$LC/fx/head"; : > "$LC/calls"
  lci() { ( cd "$LC/repo/src" && env PATH="$LC/bin:$PATH" LC_FX="$LC/fx" LC_CALLS="$LC/calls" bash "$S/adlc-local-ci.sh" "$@" ) >"$LC/out" 2>"$LC/err"; }   # run from a subdirectory
  lci 7 --dry-run; check 1 "a battery with a failing check exits 1" $?
  eq "ADLC-CI: FAIL head $HEAD_SHA" "the LAST line of the comment is the marker, with the full sha" "$(tail -1 "$LC/out")"
  eq "| tests | pass | 0 |,| lint | pass | 0 |,| image build | FAIL | 3 |,| after | pass | 0 |," "one table row per check: name, result, exit code (seconds follow); a command with colons runs from the repo root; a failure does not stop the checks after it" "$(grep -E '^\| (tests|lint|image build|after) ' "$LC/out" | sed -E 's/ [0-9]+ \|$//' | tr '\n' ',')"
  eq 1 "…the check after the failure ran, once, and with no stdin to wait on" "$(wc -l < "$LC/ran" | tr -d ' ')"
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
tr '\n' ' ' < "$QA" | grep -q "only when that SHA is the PR's current head" && ok "…as the battery result only for the PR's current head" || bad "role-qa-release-ops: a local CI marker counts only for the PR's current head"
tr '\n' ' ' < "$QA" | grep -q 'one for an older commit does not' && ok "…and not for an older commit" || bad "role-qa-release-ops: must say an older marker does not count"
grep -q 'a record, not a gate' "$QA" && ok "…and calls it a record, not a gate" || bad "role-qa-release-ops: must call the marker a record, not a gate"
grep -q '\.adlc/scripts/adlc-local-ci\.sh <pr>' "$RB" && grep -q '\.adlc/local-ci\.txt' "$RB" && ok "RUNBOOK has the local CI recipe (script and commands file)" || bad "RUNBOOK must name adlc-local-ci.sh and .adlc/local-ci.txt"
tr '\n' ' ' < "$RB" | grep -q 'a record, not a gate: anyone who can comment can write that line' && ok "…and says the marker is a record, not a gate" || bad "RUNBOOK: must say the marker is a record, not a gate"
grep -q '`blocked=`' "$ROOT/skills/cycle-retro/SKILL.md" && ok "cycle-retro explains the blocked= figure" || bad "cycle-retro must explain blocked="
echo "tripwire step (the workflow's own run: script, on a real git history + a stub gh):"
# The step of adlc-main-tripwire.yml, pulled out of the template and run as Actions runs it
# (bash -e), with the two scripts it calls. The stub gh answers the commit→PR lookup (1 PR unless
# $TS/nopr/<sha> exists), keeps the open issues in $TS/issues.json and adds each one it "creates",
# so a second run of the same event meets the first run's alert.
if command -v jq >/dev/null 2>&1; then
  TS="$(mktemp -d)"; mkdir -p "$TS/bin" "$TS/nopr" "$TS/repo/.adlc/scripts"
  cp "$S/adlc-tripwire-check.sh" "$S/adlc-tripwire-alert.sh" "$TS/repo/.adlc/scripts/"
  step_run "$ROOT/templates/github/adlc-main-tripwire.yml" '- name: Flag commits not linked to a merged PR' > "$TS/step.sh"
  [ -s "$TS/step.sh" ] && ok "the run: script is extracted from the template" || bad "could not extract the tripwire's run: script"
  cat > "$TS/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$TS/calls"
case "$1 $2" in
  "api repos/o/r/commits/"*) sha="${2#repos/o/r/commits/}"; sha="${sha%/pulls}"; [ -e "$TS/nopr/$sha" ] && echo 0 || echo 1 ;;
  "issue list") cat "$TS/issues.json" ;;
  "issue create")
    body=""; while [ $# -gt 0 ]; do [ "$1" = "--body" ] && body="$2"; shift; done
    jq --arg b "$body" '. + [{number: (length + 1), body: $b}]' "$TS/issues.json" > "$TS/issues.new" && mv "$TS/issues.new" "$TS/issues.json"
    echo "https://github.com/o/r/issues/1" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$TS/bin/gh"
  tgit() { git -C "$TS/repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
  git init -q "$TS/repo" >/dev/null 2>&1
  for c in one two three; do echo "$c" > "$TS/repo/f"; tgit add -A >/dev/null 2>&1; tgit commit -q -m "$c" >/dev/null 2>&1; done
  C1=$(tgit rev-parse HEAD~2); C2=$(tgit rev-parse HEAD~1); C3=$(tgit rev-parse HEAD); GONE=dddddddddddddddddddddddddddddddddddddddd
  tws() { # <forced> <before> <after> — one run of the step
    TSOUT=$( cd "$TS/repo" && env PATH="$TS/bin:$PATH" TS="$TS" GH_TOKEN=x REPO=o/r FORCED="$1" BEFORE="$2" AFTER="$3" ADLC_TRIPWIRE_BRANCH=main bash -e "$TS/step.sh" 2>&1 )
  }
  tscreates() { grep -c '^issue create ' "$TS/calls"; }
  echo '[]' > "$TS/issues.json"; : > "$TS/calls"
  tws false "$C1" "$C3";       check 0 "every pushed commit has a PR → the step passes" $?
  eq 0 "…and files nothing" "$(tscreates)"
  : > "$TS/nopr/$C3"; : > "$TS/calls"
  tws false "$C1" "$C3";       check 1 "a commit with no PR → the step fails" $?
  eq 1 "…and files one alert" "$(tscreates)"
  eq 1 "…labelled adlc:tripwire" "$(grep -c '^issue create .* --label adlc:tripwire ' "$TS/calls")"
  eq "ADLC-TRIPWIRE: direct $C3" "…naming that commit alone in its machine-readable line" "$(jq -r '.[0].body' "$TS/issues.json" | tail -n 1)"
  tws false "$C1" "$C3";       check 1 "the same event run again → the step still fails" $?
  eq 1 "…and no second alert is filed for the same commits (issue 39)" "$(tscreates)"
  : > "$TS/nopr/$C2"
  tws false "$C1" "$C3";       check 1 "a push with one more direct commit is a different set" $?
  eq 2 "…and gets its own alert" "$(tscreates)"
  echo '[]' > "$TS/issues.json"; : > "$TS/calls"
  tws false 0000000000000000000000000000000000000000 "$C3"; check 1 "a new branch (all-zero before): the new commit alone is checked" $?
  eq "ADLC-TRIPWIRE: direct $C3" "…so the alert names it and not the older direct commit" "$(jq -r '.[0].body' "$TS/issues.json" | tail -n 1)"
  rm -f "$TS"/nopr/*; echo '[]' > "$TS/issues.json"; : > "$TS/calls"
  tws true "$GONE" "$C3";      check 1 "a force-push → the step fails, though every commit now on the branch has a PR" $?
  eq 1 "…and files one alert" "$(tscreates)"
  eq "ADLC-TRIPWIRE: forced $GONE $C3" "…for the rewrite, from the old tip to the new" "$(jq -r '.[0].body' "$TS/issues.json" | tail -n 1)"
  eq 0 "…without walking before..after (the old tip is not in the clone)" "$(grep -c '^api ' "$TS/calls")"
  case "$TSOUT" in *"::error::Force-push to main"*) ok "…and the run's error line says it was a force-push" ;; *) bad "a force-push must be said in the run's error line (got: $TSOUT)" ;; esac
  tws true "$GONE" "$C3"
  eq 1 "the same force-push run again files no second alert" "$(tscreates)"
  echo '[]' > "$TS/issues.json"; : > "$TS/calls"
  tws false "$GONE" "$C3";     [ $? -ne 0 ] && ok "an ordinary push whose before is not in the clone fails the step (a failed rev-list is not 'no commits')" || bad "a failed rev-list must fail the step"
  tws "" "$C1" "$C3";          [ $? -ne 0 ] && ok "an event with no forced field fails the step" || bad "an unreadable event must fail the step"
  eq 0 "…neither files an alert it has no commits for" "$(tscreates)"
  rm -rf "$TS"
else
  echo "  · skipped the tripwire step checks (no jq here)"
fi

echo "adlc-refresh.sh (the refresh: per-file diff, host-owned copies kept):"
# Issue 39: the refresh copied templates/scripts/*.sh over the host's copies with no comparison
# and no way to keep a file. Run the script as shipped against a fixture host tree.
RF="$(mktemp -d)"; RH="$RF/host"; mkdir -p "$RH"
R="$S/adlc-refresh.sh"
rf()     { RFOUT=$(bash "$R" "$@" 2>&1); }
status() { printf '%s\n' "$RFOUT" | awk -v t="$1" '$NF == t { $NF = ""; sub(/ +$/, ""); print; exit }'; }   # <target> → its status line, without the path
tree()   { ( cd "$RH" && find . \( -type f -o -type l \) -exec cksum {} + | sort -k3; find . -type f -perm -u+x | sort ); }   # contents + exec bits
NSCRIPTS=$(ls "$S"/*.sh | grep -vc '/adlc-refresh\.sh$')
rf;                          check 2 "bad arguments: no host root" $?
rf "$RF/nowhere";            check 2 "bad arguments: a host root that is not a directory" $?
rf "$RH" one-extra;          check 2 "bad arguments: a filled file with no target" $?
rf --apply;                  check 2 "bad arguments: --apply alone" $?
rf --force "$RH";            check 2 "bad arguments: an unknown flag" $?
# no template may itself carry the marker where the script looks: every installed copy would read as host-owned
eq "" "no file under templates/ carries the host-owned marker in its first five lines" "$(for f in $(find "$ROOT/templates" -type f); do head -n 5 "$f" | grep -lqF 'adlc: host-owned' && echo "$f"; done)"
rf "$RH";                    check 0 "dry run on a host with no tooling yet exits 0" $?
eq "$NSCRIPTS" "…lists every templates/scripts/*.sh as new" "$(printf '%s\n' "$RFOUT" | grep -c '^new  *\.adlc/scripts/adlc-[a-z-]*\.sh$')"
eq "new" "…and the MIT notice" "$(status .adlc/LICENSE)"
eq 0 "…but not itself: it runs from the plugin and is not copied" "$(printf '%s\n' "$RFOUT" | grep -c 'adlc-refresh\.sh')"
eq "" "…and writes nothing, not even a folder" "$(ls -A "$RH")"
case "$RFOUT" in *"nothing written"*) ok "…saying so" ;; *) bad "a dry run must say nothing was written" ;; esac
rf --apply "$RH";            check 0 "--apply on the same host exits 0" $?
eq "$NSCRIPTS" "…every script is there" "$(ls "$RH/.adlc/scripts" | grep -c .)"
eq "$NSCRIPTS" "…executable" "$(find "$RH/.adlc/scripts" -type f -perm -u+x | grep -c .)"
eq "" "…byte for byte the plugin's" "$(for f in "$RH"/.adlc/scripts/*.sh; do cmp -s "$f" "$S/${f##*/}" || echo "$f"; done)"
cmp -s "$RH/.adlc/LICENSE" "$ROOT/templates/LICENSE" && [ ! -x "$RH/.adlc/LICENSE" ] && ok "…with the MIT notice, not executable" || bad "--apply must copy templates/LICENSE to .adlc/LICENSE as a plain file"
eq "" "…and nothing outside .adlc/scripts and .adlc/LICENSE" "$(cd "$RH" && find . -type f | grep -v '^\./\.adlc/scripts/adlc-[a-z-]*\.sh$' | grep -vx './.adlc/LICENSE')"
rf "$RH"
eq "$((NSCRIPTS + 1))" "a second run reads every file as same" "$(printf '%s\n' "$RFOUT" | grep -c '^same  ')"
# the host's own changes: one copy edited, one edited and marked host-owned, one deleted, one lost its
# exec bit, one marked on line 6 (too late to count), one extra file of the host's own
echo '# a local tweak' >> "$RH/.adlc/scripts/adlc-verdict.sh"
{ printf '#!/usr/bin/env bash\n# adlc: host-owned (our own metrics)\necho ours\n'; } > "$RH/.adlc/scripts/adlc-metrics.sh"; chmod 644 "$RH/.adlc/scripts/adlc-metrics.sh"
{ sed -n '1,4p' "$S/adlc-cost.sh"; echo '# kept as is. adlc: host-owned'; sed -n '5,$p' "$S/adlc-cost.sh"; } > "$RH/.adlc/scripts/adlc-cost.sh"
{ sed -n '1,5p' "$S/adlc-cache.sh"; echo '# adlc: host-owned'; sed -n '6,$p' "$S/adlc-cache.sh"; } > "$RH/.adlc/scripts/adlc-cache.sh"
rm "$RH/.adlc/scripts/adlc-triage.sh"
chmod -x "$RH/.adlc/scripts/adlc-fix-cap.sh"; echo '# x' >> "$RH/.adlc/scripts/adlc-fix-cap.sh"
echo 'echo own' > "$RH/.adlc/scripts/own-tool.sh"
cp "$RH/.adlc/scripts/adlc-metrics.sh" "$RF/metrics.keep"; cp "$RH/.adlc/scripts/adlc-cost.sh" "$RF/cost.keep"
BEFORE="$(tree)"
rf "$RH";                    check 0 "dry run on a host with local changes exits 0" $?
eq "changed" "an edited copy is changed" "$(status .adlc/scripts/adlc-verdict.sh)"
eq "host-owned (skipped)" "a copy marked on line 2 is host-owned" "$(status .adlc/scripts/adlc-metrics.sh)"
eq "host-owned (skipped)" "…and one marked on line 5, mid-comment" "$(status .adlc/scripts/adlc-cost.sh)"
eq "changed" "a marker on line 6 is not in the first five lines: the copy is changed" "$(status .adlc/scripts/adlc-cache.sh)"
eq "new" "a deleted copy is new" "$(status .adlc/scripts/adlc-triage.sh)"
eq "same" "an untouched copy is same" "$(status .adlc/scripts/adlc-doctor.sh)"
eq 0 "the host's own file is not a mapped target: not listed" "$(printf '%s\n' "$RFOUT" | grep -c 'own-tool')"
eq 3 "each changed file is followed by a unified diff, installed → plugin" "$(printf '%s\n' "$RFOUT" | grep -c '^--- \.adlc/scripts/adlc-[a-z-]*\.sh (installed)$')"
eq 1 "…showing the host's line as the one that would go" "$(printf '%s\n' "$RFOUT" | grep -c '^-# a local tweak$')"
eq 0 "…and no diff for a host-owned file" "$(printf '%s\n' "$RFOUT" | grep -c 'echo ours')"
eq "$BEFORE" "without --apply nothing is written (contents and exec bits as before)" "$(tree)"
rf --apply "$RH";            check 0 "--apply with host-owned files skipped still exits 0 (the list is the report)" $?
cmp -s "$RH/.adlc/scripts/adlc-verdict.sh" "$S/adlc-verdict.sh" && ok "the changed copy is now the plugin's" || bad "--apply must copy a changed file"
cmp -s "$RH/.adlc/scripts/adlc-cache.sh" "$S/adlc-cache.sh" && ok "…the late-marked one too" || bad "--apply must copy a file whose marker is past line 5"
[ -x "$RH/.adlc/scripts/adlc-triage.sh" ] && cmp -s "$RH/.adlc/scripts/adlc-triage.sh" "$S/adlc-triage.sh" && ok "the new copy is there, executable" || bad "--apply must copy a new file, executable"
[ -x "$RH/.adlc/scripts/adlc-fix-cap.sh" ] && ok "a script that had lost its exec bit has it back" || bad "--apply must leave a script executable"
[ -x "$RH/.adlc/scripts/adlc-verdict.sh" ] && ok "…and an overwritten script keeps it" || bad "--apply must keep the exec bit"
cmp -s "$RH/.adlc/scripts/adlc-metrics.sh" "$RF/metrics.keep" && cmp -s "$RH/.adlc/scripts/adlc-cost.sh" "$RF/cost.keep" && ok "the host-owned files are untouched, byte for byte" || bad "--apply must not touch a host-owned file"
[ ! -x "$RH/.adlc/scripts/adlc-metrics.sh" ] && ok "…their mode too" || bad "--apply must not chmod a host-owned file"
eq "echo own" "…and so is the host's own file" "$(cat "$RH/.adlc/scripts/own-tool.sh")"
eq "copied: 4 · unchanged: $((NSCRIPTS - 6 + 1)) · skipped: 2|skipped (left exactly as they are):|  .adlc/scripts/adlc-cost.sh — host-owned|  .adlc/scripts/adlc-metrics.sh — host-owned|" "the output ends with the counts and the list of what it skipped" "$(printf '%s\n' "$RFOUT" | tail -n 4 | tr '\n' '|')"
# a link at a target, or above it: nothing is written through it
rm "$RH/.adlc/scripts/adlc-pr-stage.sh"; echo outside > "$RF/outside.sh"; ln -s "$RF/outside.sh" "$RH/.adlc/scripts/adlc-pr-stage.sh"
rf --apply "$RH";            check 0 "a link at a target is skipped, not an error" $?
eq "not a plain file (skipped)" "…with its own status" "$(status .adlc/scripts/adlc-pr-stage.sh)"
eq "outside" "…and the file it points at is not written" "$(cat "$RF/outside.sh")"
[ -L "$RH/.adlc/scripts/adlc-pr-stage.sh" ] && ok "…nor is the link replaced" || bad "a link at a target must be left alone"
RH2="$RF/host2"; mkdir -p "$RH2" "$RF/elsewhere"; ln -s "$RF/elsewhere" "$RH2/.adlc"
rf --apply "$RH2";           check 0 "a link at .adlc: every target under it is skipped" $?
eq "" "…and nothing is written through the link" "$(ls -A "$RF/elsewhere")"
# files the wizard fills first: the filled result, one target
printf 'name: ADLC QA\non: push\nif: "someone"\n' > "$RF/qa.yml"
rf "$RH" "$RF/qa.yml" .github/workflows/adlc-qa.yml; check 0 "filled file: a dry run exits 0" $?
eq "new" "…a workflow the host does not have is new" "$(status .github/workflows/adlc-qa.yml)"
[ ! -e "$RH/.github" ] && ok "…and nothing is written" || bad "filled file: a dry run must write nothing"
rf --apply "$RH" "$RF/qa.yml" .github/workflows/adlc-qa.yml
cmp -s "$RF/qa.yml" "$RH/.github/workflows/adlc-qa.yml" && [ ! -x "$RH/.github/workflows/adlc-qa.yml" ] && ok "filled file: --apply copies it to its target, not executable" || bad "filled file: --apply must copy the workflow as a plain file"
printf 'name: ADLC QA\non: push\nif: "someone-else"\n' > "$RF/qa2.yml"
rf "$RH" "$RF/qa2.yml" .github/workflows/adlc-qa.yml
eq "changed" "…a filled result that differs from the installed workflow is changed" "$(status .github/workflows/adlc-qa.yml)"
eq 1 "…with the diff against the installed file" "$(printf '%s\n' "$RFOUT" | grep -c '^+if: "someone-else"$')"
{ echo '# adlc: host-owned'; cat "$RF/qa.yml"; } > "$RH/.github/workflows/adlc-qa.yml"; cp "$RH/.github/workflows/adlc-qa.yml" "$RF/qa.keep"
rf --apply "$RH" "$RF/qa2.yml" .github/workflows/adlc-qa.yml; check 0 "filled file: a host-owned workflow is skipped" $?
eq "host-owned (skipped)" "…with that status" "$(status .github/workflows/adlc-qa.yml)"
cmp -s "$RH/.github/workflows/adlc-qa.yml" "$RF/qa.keep" && ok "…and untouched" || bad "filled file: a host-owned workflow must not be written"
printf 'jobs:\n  a:\n    if: github.actor == '"'"'{{PRINCIPAL}}'"'"'\n    env:\n      T: ${{ github.token }}\n' > "$RF/unfilled.yml"
rf --apply "$RH" "$RF/unfilled.yml" .github/workflows/adlc-builder.yml; check 2 "filled file: one that still holds a {{PLACEHOLDER}} is refused" $?
[ ! -e "$RH/.github/workflows/adlc-builder.yml" ] && ok "…and not written" || bad "an unfilled file must not be written"
printf 'env:\n  T: ${{ github.token }}\n' > "$RF/expr.yml"
rf "$RH" "$RF/expr.yml" .github/workflows/adlc-builder.yml; check 0 "…a GitHub \${{ expression }} is not a placeholder" $?
printf -- '---\nname: adlc-builder\nmodel: opus\n---\nx\n' > "$RF/agent.md"
rf --apply "$RH" "$RF/agent.md" .claude/agents/adlc-builder.md; check 0 "filled file: an agent copy is a target" $?
rf --apply "$RH" "$RF/agent.md" ./.github/ISSUE_TEMPLATE/requirement.yml; check 0 "…and the issue template (a leading ./ is fine)" $?
for t in src/app.py .adlc/scripts/adlc-verdict.sh .github/workflows/ci.yml .github/workflows/adlc-x/../../../evil.yml .github/workflows/adlc-a/../adlc-b.yml ../adlc-x.yml .claude/agents/builder.md .claude/settings.json; do
  rf --apply "$RH" "$RF/qa.yml" "$t"; check 2 "filled file: '$t' is not a target this script writes" $?
done
rf --apply "$RH" "$RF/qa.yml" "$RH/.github/workflows/adlc-qa.yml"; check 2 "filled file: an absolute path is not a target (targets are relative to the host root)" $?
[ ! -e "$RH/src" ] && [ ! -e "$RF/evil.yml" ] && [ ! -e "$RH/.github/workflows/ci.yml" ] && [ ! -e "$RH/.github/workflows/adlc-b.yml" ] && ok "…and none of them was written" || bad "a refused target must not be written"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RF/hook"
rf --apply "$RH" "$RF/hook" .git/hooks/pre-commit; check 1 "filled file: the hook into a folder with no .git/hooks is an error" $?
[ ! -e "$RH/.git" ] && ok "…and no .git is made up" || bad "the script must not create .git"
mkdir -p "$RH/.git/hooks"
rf --apply "$RH" "$RF/hook" .git/hooks/pre-commit; check 0 "filled file: the hook, where .git/hooks exists" $?
[ -x "$RH/.git/hooks/pre-commit" ] && ok "…is installed executable" || bad "the hook must be executable"
# the plugin's own copy only: a copy of the script elsewhere has no templates beside it
mkdir -p "$RF/copy/.adlc/scripts"; cp "$R" "$RF/copy/.adlc/scripts/"
RFOUT=$(bash "$RF/copy/.adlc/scripts/adlc-refresh.sh" "$RH" 2>&1); check 1 "a copy of the script outside the plugin refuses to run (no templates beside it)" $?
# the wizard uses it, and says what was skipped
BS="$ROOT/skills/bootstrap/SKILL.md"
grep -q '${CLAUDE_PLUGIN_ROOT}/templates/scripts/adlc-refresh.sh "${CLAUDE_PROJECT_DIR}"' "$BS" && ok "bootstrap runs the refresh script from the plugin" || bad "bootstrap: step 8b must run \${CLAUDE_PLUGIN_ROOT}/templates/scripts/adlc-refresh.sh"
grep -q 'adlc: host-owned' "$BS" && ok "…names the host-owned marker" || bad "bootstrap: must name the host-owned marker"
grep -q -- '--apply' "$BS" && ok "…writes only with --apply, after showing the dry run" || bad "bootstrap: must run the dry run first, then --apply"
grep -q 'tell the user which files it skipped' "$BS" && ok "…and tells the user what was skipped" || bad "bootstrap: must tell the user which files the refresh skipped"
grep -q 'adlc-refresh.sh "${CLAUDE_PROJECT_DIR}" <scratch file> <target>' "$BS" && ok "…with the filled files (workflows, agent copies, the hook) going through the same script" || bad "bootstrap: filled files must go through adlc-refresh.sh"
grep -q 'copy `templates/scripts/\*.sh` to' "$BS" && bad "bootstrap must not copy templates/scripts/*.sh by hand any more" || ok "…and no longer copies templates/scripts/*.sh by hand"
for f in "$S"/*.sh; do grep -q "${f##*/}" "$ROOT/README.md" || bad "README layout tree does not list ${f##*/}"; done
grep -q 'adlc: host-owned' "$ROOT/README.md" && ok "README says how to keep a copy (the marker)" || bad "README: must name the host-owned marker"
# the doctor: a host-owned copy is listed on one line and is not a problem for differing
DH="$RF/dhost"; mkdir -p "$DH/.claude/skills/project-conventions" "$DH/.claude/skills/release-ops" "$DH/.claude/agents" "$DH/.github/workflows" "$DH/.adlc/scripts"
printf '{"permissions":{"deny":["Bash(gh pr merge:*)"]}}' > "$DH/.claude/settings.json"
echo x > "$DH/.claude/skills/project-conventions/SKILL.md"; echo x > "$DH/.claude/skills/release-ops/SKILL.md"
for a in product-analyst architect builder adversarial-reviewer qa-release-ops; do printf -- '---\nname: adlc-%s\nmodel: opus\n---\n\nx\n' "$a" > "$DH/.claude/agents/adlc-$a.md"; done
cp "$S/adlc-verdict.sh" "$DH/.adlc/scripts/"; printf '#!/usr/bin/env bash\n# adlc: host-owned\necho ours\n' > "$DH/.adlc/scripts/adlc-metrics.sh"
printf '# adlc: host-owned\njobs:\n  t:\n    steps:\n      - run: echo hi\n' > "$DH/.github/workflows/adlc-ci.yml"
ddoc() { DOUT=$(ADLC_DOCTOR_SKIP_LABELS=1 CLAUDE_PLUGIN_ROOT= ADLC_PLUGIN_ROOT= CLAUDE_CONFIG_DIR="$RF/none" bash "$S/adlc-doctor.sh" "$DH" 2>&1); }
ddoc;                        check 0 "doctor: host-owned copies that differ from the plugin's are not a problem" $?
eq "  · host-owned (a refresh skips these; keeping them current with the plugin is this repo's job): .adlc/scripts/adlc-metrics.sh .github/workflows/adlc-ci.yml" "…and are listed on one line" "$(printf '%s\n' "$DOUT" | grep 'host-owned')"
printf '# adlc: host-owned\njobs:\n  a:\n    steps:\n      - uses: anthropics/claude-code-action@v1\n        with:\n          prompt: go\n' > "$DH/.github/workflows/adlc-qa.yml"
ddoc;                        check 1 "doctor: a host-owned lane that cannot run its agent is still a problem" $?
eq 1 "…named as host-owned, since a refresh will not re-copy it" "$(printf '%s\n' "$DOUT" | grep -c 'adlc-qa.yml (host-owned: a refresh will not re-copy it')"
rm "$DH/.github/workflows/adlc-qa.yml" "$DH/.github/workflows/adlc-ci.yml" "$DH/.adlc/scripts/adlc-metrics.sh"
ddoc
eq 0 "doctor: with no host-owned copy the line is not printed" "$(printf '%s\n' "$DOUT" | grep -c 'host-owned')"
# scope-file lifecycle (issue 39): the RUNBOOK says what the code does
grep -q '^## Scope files' "$ROOT/templates/RUNBOOK.md.tmpl" && ok "RUNBOOK states the scope-file lifecycle" || bad "RUNBOOK: must say what becomes of .adlc/scope/<n>.txt"
SCT="$(mktemp -d)"; mkdir -p "$SCT/.adlc/scope"; printf 'src/\n' > "$SCT/.adlc/scope/12.txt"
( cd "$SCT" && printf '.adlc/scope/7.txt\n.adlc/scope/8.txt\n' | bash "$S/adlc-diff-scope.sh" build .adlc/scope/12.txt ) >/dev/null 2>&1; check 1 "…a lane PR cannot prune other issues' scope files (the diff-scope check refuses it)" $?
( cd "$SCT" && printf '.adlc/scope/7.txt\n.adlc/scope/8.txt\n' | bash "$S/adlc-diff-scope.sh" other ) >/dev/null 2>&1; check 0 "…a PR tied to no lane issue can (the check skips it)" $?
rm -rf "$RF" "$SCT"
echo "follow-up chains (issue 37; adlc-chains.sh, labels.sh and adlc-metrics.sh against a stub gh):"
# On one host 91 of 224 issue titles were follow-ups, in chains four to seven issues deep, each issue a pipeline
# run. A follow-up names its parent on a marker line (older ones in a phrase), adlc-chains.sh builds the chains
# from one issue list, and a chain three or more deep is put to the Principal as a decision; the label
# adlc:accepted-risk on a chain's root records it. The fixture holds every way an issue names its parent.
if command -v jq >/dev/null 2>&1; then
  CH="$(mktemp -d)"; mkdir -p "$CH/bin" "$CH/fx" "$CH/fx2" "$CH/fx3" "$CH/repo"
  cat > "$CH/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub gh: `issue list` serves $CH_FX/issues.json and `pr list` $CH_FX/prs.json (through the call's --jq when it
# has one, whole otherwise), `run list` $CH_FX/runs.json; CH_FAIL=issue|pr makes that call fail; every call is logged
echo "$*" >> "$CH_CALLS"
case "$1 $2" in
  "issue list") k=issue ;; "pr list") k=pr ;; "run list") k=run ;;
  "label create") echo "$3" >> "$CH_CALLS.labels"; exit 0 ;;
  "label list") exit 0 ;;   # no labels: adlc-metrics.sh then prints its change_failures zero and goes on
  *) exit 2 ;;
esac
[ "${CH_FAIL:-}" = "$k" ] && { echo "gh: HTTP 502" >&2; exit 1; }
f=.; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && f="$2"; shift; done
jq -r "$f" "$CH_FX/${k}s.json"
SH
  chmod +x "$CH/bin/gh"
  # <number> <title> <body> <state> [labels…] → one issue object, as `gh issue list --json` gives it
  chi() { jq -cn --argjson n "$1" --arg t "$2" --arg b "$3" --arg s "$4" --arg at "$CH_AT" '{number: $n, title: $t, body: $b, state: $s, createdAt: $at, labels: ($ARGS.positional | map({name: .}))}' --args "${@:5}"; }
  CH_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    chi 34  "Migration guard" "Forbid the statements." CLOSED
    chi 67  "Follow-up of #34: two more statements" "" CLOSED                          # a phrase in the title
    chi 68  "Guard: lock timeout" "$(printf 'From the QA of the guard PR.\nADLC-FOLLOW-UP: #34\n- [ ] one\n- [ ] two')" CLOSED adlc:follow-up   # the marker line
    chi 69  "Guard: comments" "Residuals of #34, batched." CLOSED                      # a phrase in the body only
    chi 85  "Residuals from QA of #67 (from PR #70)" "" CLOSED                         # the first phrase names the issue; the PR is not asked for
    chi 116 "Guard: quoted identifiers" "$(printf 'Same area as the follow-up of #34.\n**ADLC-FOLLOW-UP:** #85')" OPEN adlc:follow-up   # the marker wins over a phrase, bold or not
    chi 60  "Perf guard" "" CLOSED adlc:accepted-risk
    chi 88  "QA of #60: slow path" "" CLOSED
    chi 118 "Perf guard: cold start (from PR #90)" "" CLOSED                           # PR 90 closes #88
    chi 215 "Perf guard again" "follow-up to issue #118" OPEN
    chi 40  "Export" "" CLOSED
    chi 41  "Export: empty file" "ADLC-FOLLOW-UP: #40" OPEN adlc:follow-up
    chi 10  "A" "follow-up of #11" CLOSED                                              # A follows B follows A
    chi 11  "B" "follow-up of #10" CLOSED
    chi 5   "Names itself" "ADLC-FOLLOW-UP: #5" CLOSED
    chi 7   "A plain request" "Nothing about any other issue; see #34 for context." OPEN
    chi 300 "Follow-up of #999" "" OPEN                                                # no such issue, no such PR
    chi 301 "Tidy (from PR #91)" "" OPEN                                               # PR 91 closes nothing
    chi 400 "Login" "" CLOSED
    chi 401 "Login: lockout" "ADLC-FOLLOW-UP: #95" OPEN adlc:follow-up                 # QA wrote the PR's number: PR 95 fixes #400
  } | jq -s . > "$CH/fx/issues.json"
  jq -n '[{number: 90, body: "Closes #88\n\nThe slow path."}, {number: 91, body: "A tidy-up; see #34."}, {number: 95, body: "What changed.\n\nfixes: #400"}, {number: 70, body: "Closes #67"}]' > "$CH/fx/prs.json"
  # fx2: markers only, every number an issue → no pull request is needed; its one deep chain is decided
  { chi 1 "Root" "" CLOSED adlc:accepted-risk; chi 2 "r2" "ADLC-FOLLOW-UP: #1" CLOSED; chi 3 "r3" "ADLC-FOLLOW-UP: #2" OPEN; chi 4 "Alone" "" OPEN; } | jq -s . > "$CH/fx2/issues.json"
  echo '{"message":"Bad credentials"}' > "$CH/fx3/issues.json"
  chains() { # [ENV=val …] -- <args…> : runs the script; stdout → CH_OUT, stderr → $CH/err, the gh calls → $CH/calls
    local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    : > "$CH/calls"
    CH_OUT=$(env PATH="$CH/bin:$PATH" CH_FX="$CH/fx" CH_CALLS="$CH/calls" ${envs[@]+"${envs[@]}"} bash "$S/adlc-chains.sh" "$@" 2>"$CH/err"); CH_RC=$?
  }
  chains -- report; check 0 "report: exits 0" $CH_RC
  eq "depth=4  #34 → #67 → #85 → #116  (issues: 6, open: 1)" "report: the one undecided chain of depth 3 or more — marker links and phrase links (title, body, a bold marker over a phrase); a parent with three follow-ups is ONE chain: its longest path, every issue under the root counted" "$(printf '%s\n' "$CH_OUT" | grep '^depth=')"
  eq "decided  depth=4  #60 → #88 → #118 → #215  (issues: 4, open: 1)  root carries adlc:accepted-risk" "report: a chain whose root carries adlc:accepted-risk is listed apart as decided (one link resolved through the PR that closes the parent)" "$(printf '%s\n' "$CH_OUT" | grep '^decided')"
  eq 0 "report: a chain two deep is not flagged at the default depth" "$(printf '%s\n' "$CH_OUT" | grep -c '#40')"
  eq "issue list --state all --limit 1000 --json number,title,body,labels,state|pr list --state all --limit 1000 --json number,body|" "report: ONE issue list call (1000 issues by default), and one pr list call because a reference names a number that is not an issue" "$(tr '\n' '|' < "$CH/calls")"
  eq 4 "report: every reference that gave no parent is named on stderr" "$(grep -c 'no link made' "$CH/err")"
  eq 1 "…the newer issue of a pair that name each other" "$(grep -c '#10 names #11, which is not older than it' "$CH/err")"
  eq 1 "…the issue that names itself" "$(grep -c '#5 names #5' "$CH/err")"
  eq 1 "…a number that is no issue and no PR" "$(grep -c '#300 names #999, which is neither a listed issue nor a pull request whose body closes one' "$CH/err")"
  eq 1 "…a PR that closes nothing (a bare #34 in its body is not a closing reference)" "$(grep -c '#301 names #91' "$CH/err")"
  chains -- report 2; check 0 "report 2: exits 0 (two issues that name each other do not loop)" $CH_RC
  eq "depth=4  #34 → #67 → #85 → #116  (issues: 6, open: 1)|depth=2  #10 → #11  (issues: 2, open: 0)|depth=2  #40 → #41  (issues: 2, open: 1)|depth=2  #400 → #401  (issues: 2, open: 1)|" "report 2: deepest first, then by root; of the pair the older issue is the root; a marker that names the PR resolves to the issue the PR closes" "$(printf '%s\n' "$CH_OUT" | grep '^depth=' | tr '\n' '|')"
  chains -- root 85;  eq "0 root=#34 depth=4 open" "root: a middle issue → its chain's root, the chain's depth, open" "$CH_RC $CH_OUT"
  eq "" "…and says nothing about other issues' references" "$(cat "$CH/err")"
  chains -- root 34;  eq "0 root=#34 depth=4 open" "root: the root itself" "$CH_RC $CH_OUT"
  chains -- root 68;  eq "0 root=#34 depth=4 open" "root: an issue on a shorter branch reports the same chain" "$CH_RC $CH_OUT"
  chains -- root 215; eq "0 root=#60 depth=4 accepted-risk" "root: a chain the Principal decided → accepted-risk" "$CH_RC $CH_OUT"
  chains -- root 7;   eq "0 root=#7 depth=1 open" "root: an issue in no chain is its own root, depth 1 (a bare #N in its body is no link)" "$CH_RC $CH_OUT"
  chains -- root 11;  eq "0 root=#10 depth=2 open" "root: in a pair that name each other, the older one" "$CH_RC $CH_OUT"
  chains -- root 999; check 1 "root: a number that is not among the issues read exits 1" $CH_RC
  eq "" "…with nothing on stdout (never read as 'open')" "$CH_OUT"
  eq 1 "…and says so" "$(grep -c '#999 is not among the 20 issues read' "$CH/err")"
  chains -- root 90;  check 1 "root: a pull request's number exits 1 too" $CH_RC
  chains CH_FAIL=issue -- report; check 1 "a failed issue read exits 1" $CH_RC
  eq "" "…with nothing on stdout (never 'no chain')" "$CH_OUT"
  eq 1 "…and says so, after gh's own error" "$(grep -c 'could not list the issues' "$CH/err")"
  chains CH_FAIL=issue -- root 85; eq "1 " "…for root too: no line that could be read as 'open'" "$CH_RC $CH_OUT"
  chains CH_FAIL=pr -- report;     eq "1 " "a failed pull request read, when one is needed, exits 1 with nothing on stdout" "$CH_RC $CH_OUT"
  chains CH_FX="$CH/fx3" -- report; eq "1 " "an answer that is not a JSON list exits 1" "$CH_RC $CH_OUT"
  chains CH_FX="$CH/fx2" -- report; check 0 "markers only: exits 0" $CH_RC
  eq "issue list --state all --limit 1000 --json number,title,body,labels,state|" "…and makes no pr list call when every reference names an issue" "$(tr '\n' '|' < "$CH/calls")"
  eq 1 "…says there is no undecided chain when the only deep one is decided" "$(printf '%s\n' "$CH_OUT" | grep -c '^no undecided chain of depth >= 3$')"
  eq "decided  depth=3  #1 → #2 → #3  (issues: 3, open: 1)  root carries adlc:accepted-risk" "…and still lists the decided one" "$(printf '%s\n' "$CH_OUT" | grep '^decided')"
  eq "" "…with nothing on stderr" "$(cat "$CH/err")"
  chains ADLC_CHAINS_LIMIT=20 -- root 7; check 0 "ADLC_CHAINS_LIMIT: exits 0" $CH_RC
  eq 1 "…is the --limit of the read" "$(grep -c '^issue list --state all --limit 20 ' "$CH/calls")"
  eq 1 "…and a list that comes back full is reported: older issues may not have been read" "$(grep -c 'read 20 issues, the limit' "$CH/err")"
  for bad in "" "bogus" "report 1" "report x" "report 3 4" "root" "root abc" "root 12 13"; do
    chains -- $bad; check 2 "bad arguments are an error: adlc-chains.sh $bad" $CH_RC
    eq "" "…and no gh call is made" "$(cat "$CH/calls")"
  done
  chains ADLC_CHAINS_LIMIT=0 -- report; check 2 "a limit of 0 is an error" $CH_RC
  chains ADLC_CHAINS_LIMIT=all -- report; check 2 "a limit that is not a number is an error" $CH_RC
  # labels.sh creates the two labels the chains rest on (the description limit is checked in the labels.sh section)
  : > "$CH/calls.labels"
  env PATH="$CH/bin:$PATH" CH_FX="$CH/fx" CH_CALLS="$CH/calls" bash "$ROOT/templates/github/labels.sh" >/dev/null 2>&1; check 0 "labels.sh runs to the end against this stub" $?
  for l in adlc:follow-up adlc:accepted-risk; do
    eq 1 "labels.sh creates $l" "$(grep -cx "$l" "$CH/calls.labels")"
  done
  # adlc-metrics.sh: the share of the window's issues that carry adlc:follow-up (fx: 4 of 20, all opened just now; no merged PR)
  echo '[]' > "$CH/fx/prs.json"; echo '[]' > "$CH/fx/runs.json"
  OUT=$( cd "$CH/repo" && env PATH="$CH/bin:$PATH" CH_FX="$CH/fx" CH_CALLS="$CH/calls" bash "$S/adlc-metrics.sh" 30 2>/dev/null )
  eq "follow_ups_filed: 4 / 20 issues opened" "metrics: follow-ups against all issues opened in the window" "$(printf '%s\n' "$OUT" | grep '^follow_ups_filed:')"
  jq '.[0].createdAt = "2000-01-01T00:00:00Z" | .[2].createdAt = "2000-01-01T00:00:00Z"' "$CH/fx/issues.json" > "$CH/fx/i2" && mv "$CH/fx/i2" "$CH/fx/issues.json"
  OUT=$( cd "$CH/repo" && env PATH="$CH/bin:$PATH" CH_FX="$CH/fx" CH_CALLS="$CH/calls" bash "$S/adlc-metrics.sh" 30 2>/dev/null )
  eq "follow_ups_filed: 3 / 18 issues opened" "…an issue opened before the window counts on neither side" "$(printf '%s\n' "$OUT" | grep '^follow_ups_filed:')"
  rm -rf "$CH"
else
  echo "  · skipped the follow-up chain checks (no jq here)"
fi
# The prompts that file, look up and present: static, as for every other skill text.
QA="$ROOT/skills/role-qa-release-ops/SKILL.md"
for t in 'ONE follow-up issue per PR' 'labelled `adlc:follow-up`' '`ADLC-FOLLOW-UP: #<the issue this PR closes>`' '.adlc/scripts/adlc-chains.sh root <that issue>' '`accepted-risk`' 'file nothing' 'a Low stays a'; do
  grep -qF -- "$t" "$QA" && ok "QA prompt: $t" || bad "QA prompt must say: $t"
done
grep -F '| **Medium** |' "$ROOT/skills/security-gate/SKILL.md" | grep -F 'adlc:follow-up' | grep -qF 'adlc:accepted-risk' && ok "security-gate: the Medium row (where the follow-up rule lives) names both labels" || bad "security-gate: the Medium row must name adlc:follow-up and adlc:accepted-risk"
for f in retro cycle-retro; do
  for t in '.adlc/scripts/adlc-chains.sh report' '`adlc:accepted-risk`' 'redesign' '`decided`'; do
    grep -qF -- "$t" "$ROOT/skills/$f/SKILL.md" && ok "$f: $t" || bad "$f must say: $t"
  done
  grep -qiE 'decision(\*\*)? for the Principal' "$ROOT/skills/$f/SKILL.md" && ok "$f: a deep chain is a decision for the Principal" || bad "$f: must present a deep chain as a decision for the Principal"
done
# nothing here asks a role the guard limits to run the script: it calls `gh issue list` (and `gh pr list`), which the
# adversarial reviewer may not, and the guard cannot see inside a script
for f in role-adversarial-reviewer role-product-analyst role-architect role-builder code-review; do
  grep -q 'adlc-chains' "$ROOT/skills/$f/SKILL.md" && bad "$f: must not be told to run adlc-chains.sh" || ok "$f is not told to run adlc-chains.sh"
done
grep -q 'adlc-chains.sh' "$ROOT/README.md" && ok "README names adlc-chains.sh" || bad "README: the layout tree must name adlc-chains.sh"
grep -q "ADLC-FOLLOW-UP: #" "$ROOT/templates/github/labels.sh" && ok "the label's description names the marker the script reads" || bad "labels.sh: adlc:follow-up should name the marker"
echo "local autopilot + context budget (issue 36: the two skills' pins, and the autopilot's cap command on a real git history):"
# /adlc:autopilot is a prompt, so what can be pinned is its text: the scripts, markers and labels
# it shares with the Actions lanes, and the lines that keep the gates where they are. The one
# command it carries in full, the fast-lane cap, is run as written. Nothing here runs the
# orchestrator itself: that needs a model and a GitHub repository.
AP="$ROOT/skills/autopilot/SKILL.md"; CB="$ROOT/skills/context-budget/SKILL.md"; RD="$ROOT/README.md"
# A gate is pinned as the sentence that holds it, matched on the skill's text with its line breaks
# folded: a rewrap cannot hide one, and each sentence is one a mutation of that gate changes
# ("Both PASS" → "Either PASS", "⇒ stop" → "⇒ go on", a step dropped or moved).
apt="$(tr '\n' ' ' < "$AP" | tr -s ' ')"; cbt="$(tr '\n' ' ' < "$CB" | tr -s ' ')"
aps() { case "$apt" in *"$2"*) ok "$1" ;; *) bad "$1 — autopilot must say: $2" ;; esac; }        # <name> <sentence>
cbs() { case "$cbt" in *"$2"*) ok "$1" ;; *) bad "$1 — context-budget must say: $2" ;; esac; }
for k in autopilot context-budget; do
  f="$ROOT/skills/$k/SKILL.md"
  [ -f "$f" ] && ok "skills/$k/SKILL.md exists" || { bad "skills/$k/SKILL.md missing"; continue; }
  eq "$k" "$k: the skill's name" "$(fm "$f" | sed -n 's/^name: *//p')"
  fm "$f" | grep -q '^description: ' && ok "$k: has a description" || bad "$k: no description"
  grep -qE "^  $k/ +# " "$RD" && ok "README layout tree lists skills/$k/" || bad "README layout tree must list skills/$k/"
  eq "" "$k: says neither tested nor proven (it has not been run from the plugin)" "$(grep -niE 'tested|proven' "$f" || true)"
done
grep -q '^| `/adlc:autopilot <issue>` | ' "$RD" && ok "README commands table lists /adlc:autopilot <issue>" || bad "README commands table must list /adlc:autopilot <issue>"
grep '^| `/adlc:autopilot <issue>` | ' "$RD" | grep -q '`adlc:context-budget`' && ok "…and that row names the context-budget skill" || bad "README commands table: the autopilot row must name adlc:context-budget"
grep -q 'has not yet been run' "$RD" && ok "README says the local autopilot has not yet been run end to end from the plugin" || bad "README must say the local autopilot has not yet been run from the plugin"
grep -q 'has not yet been run from the plugin' "$ROOT/CHANGELOG.md" && ok "…and so does the CHANGELOG" || bad "CHANGELOG must say the autopilot has not yet been run from the plugin"
grep -q '/adlc:autopilot <issue>' "$ROOT/templates/RUNBOOK.md.tmpl" && ok "RUNBOOK points at /adlc:autopilot" || bad "RUNBOOK must point at /adlc:autopilot <issue>"
grep -q '/adlc:autopilot <issue>' "$ROOT/skills/bootstrap/SKILL.md" && ok "bootstrap's local recipe points at /adlc:autopilot" || bad "bootstrap must point at /adlc:autopilot <issue>"
# Gate 1 auto-approval is the Principal's opt-in: only a typed command may start the orchestrator.
# The budget is the opposite: subagents load it with the Skill tool, and no wrapper preloads it.
fm "$AP" | grep -qE '^disable-model-invocation: *true' && ok "autopilot: only a typed /adlc:autopilot starts it (disable-model-invocation)" || bad "autopilot: must set disable-model-invocation: true"
fm "$CB" | grep -qE '^disable-model-invocation: *true' && bad "context-budget: disable-model-invocation would stop a subagent's Skill load" || ok "context-budget: a subagent may load it"
eq "" "no agent wrapper preloads context-budget (it is opt-in)" "$(grep -l 'context-budget' "$ROOT"/agents/*.md "$ROOT"/templates/agents/*.tmpl 2>/dev/null || true)"
grep -q 'load `adlc:context-budget` first' "$AP" && ok "autopilot: every brief names adlc:context-budget" || bad "autopilot: the brief must name adlc:context-budget"
# the scripts it relies on: each one named, and every script either skill names is one the wizard copies
for sc in adlc-relabel.sh adlc-verdict.sh adlc-triage.sh adlc-fix-cap.sh adlc-run-log.sh; do
  grep -q "\.adlc/scripts/$sc" "$AP" && ok "autopilot names .adlc/scripts/$sc" || bad "autopilot must name .adlc/scripts/$sc"
done
for sc in $(grep -ohE 'adlc-[a-z-]+\.sh' "$AP" "$CB" | sort -u); do
  [ -f "$S/$sc" ] && ok "…$sc exists in templates/scripts/" || bad "a skill names $sc, which templates/scripts/ does not hold"
done
for wf in $(grep -ohE 'adlc-[a-z-]+\.yml' "$AP" | sort -u); do
  [ -f "$ROOT/templates/github/$wf" ] && ok "…$wf exists in templates/github/" || bad "autopilot names $wf, which templates/github/ does not hold"
done
# one subagent per role: this repo's copies, the names the RUNBOOK uses
for a in $ROLES; do grep -q "\`adlc-$a\`" "$AP" && ok "autopilot runs adlc-$a" || bad "autopilot must run the adlc-$a copy"; done
grep -q 'never run a role on its' "$AP" && ok "autopilot: no role runs on its own output" || bad "autopilot must say no role runs on its own output"
# markers, read the way the lanes read them
for m in 'ADLC-ADV: PASS|CHANGES' 'ADLC-ARCH:' 'ADLC-TRIAGE:' 'ADLC-BREAKDOWN:'; do grep -qF "$m" "$AP" && ok "autopilot names the $m marker" || bad "autopilot must name the $m marker"; done
tr='ADLC-TRIAGE:[[:space:]]*(FAST|FULL)'
grep -qF "$tr" "$AP" && grep -qF "$tr" "$ROOT/templates/github/adlc-intake.yml" && ok "autopilot reads the triage verdict with the intake lane's expression" || bad "autopilot and adlc-intake.yml must read ADLC-TRIAGE the same way"
grep -q 'adlc-verdict.sh ADLC-ADV' "$AP" && ok "…and the review verdicts through adlc-verdict.sh" || bad "autopilot must read the verdict with adlc-verdict.sh"
# A verdict is this round's or none (review finding 3): round 1 ADV CHANGES + ARCH PASS, round 2 the reviewer posts
# PASS and the Architect posts nothing. Read over every comment, adlc-verdict.sh says PASS twice, for the old head.
aps "the review counts the PR's comments before the reviewers run" "note \`n\`, the PR's comment count (\`gh pr view <pr> --json comments --jq '.comments | length'\`)"
aps "…and reads this round's comments only" "Read THIS round's comments only: \`bodies=\$(gh pr view <pr> --json comments --jq '.comments[<n>:][].body')\`"
aps "…where a reviewer with no verdict this round stops the run" "An empty answer ⇒ stop: that reviewer posted no verdict this round, and an older comment never stands in."
aps "…CHANGES from either reviewer returns the PR" "\`CHANGES\` from either ⇒ step 6."
aps "…and only two PASS verdicts go on" "Both \`PASS\` ⇒ step 7."
if command -v jq >/dev/null 2>&1; then
  stale='{"comments":[{"body":"One High.\nADLC-ADV: CHANGES"},{"body":"Conforms.\nADLC-ARCH: PASS"},{"body":"Fixed.\nADLC-ADV: PASS"}]}'
  thisround() { printf '%s' "$stale" | jq -r "$(printf '%s' "$apt" | sed -n "s/.*--jq '\(\.comments\[<n>:\]\[\]\.body\)'.*/\1/p" | sed "s/<n>/$1/")" | bash "$S/adlc-verdict.sh" "$2"; }
  eq "PASS PASS" "fixture: read over every comment, the stale ARCH PASS of round 1 stands" "$(thisround 0 ADLC-ADV) $(thisround 0 ADLC-ARCH)"
  eq "PASS:" "the skill's own expression, from this round's first comment on, gives the new ADV verdict and no ARCH verdict" "$(thisround 2 ADLC-ADV):$(thisround 2 ADLC-ARCH)"
else
  echo "  · skipped running the autopilot's this-round expression (needs jq)"
fi
grep -qF '`adlc-adversarial-reviewer` and, after it, `adlc-architect` (conformance duty)' "$AP" && ok "…adversarial first, then conformance (the review lane's order)" || bad "autopilot: the adversarial review must come before the conformance review"
# the gates
grep -q 'you never merge, deploy or run a migration' "$AP" && grep -q 'Gate 2' "$AP" && ok "autopilot: Gate 2 is never automated (no merge, deploy or migration)" || bad "autopilot must say Gate 2 / the merge is never automated"
grep -q 'only the Principal applies `stage:fast`' "$AP" && ok "autopilot: only the Principal applies stage:fast" || bad "autopilot must leave stage:fast to the Principal"
grep -q '`FULL` ⇒ `gh issue edit N --add-label adlc:autopilot`, `.adlc/scripts/adlc-relabel.sh N stage:design`' "$AP" && ok "autopilot: Gate 1 is auto-approved on a FULL verdict, with adlc:autopilot on the issue and the relabel script" || bad "autopilot: the Gate 1 auto-approval must be FULL-only, label adlc:autopilot, and relabel through the script"
grep -q '`FAST` ⇒ start nothing' "$AP" && ok "…and a FAST verdict starts nothing" || bad "autopilot: a FAST verdict must start nothing"
aps "autopilot: /security-review is on the never-automated list" "only the Principal applies \`stage:fast\`; and \`/security-review\`."
aps "…and in the report as the Principal's step" "what stays theirs before the merge — run \`/security-review\` on the branch"
eq 2 "…and nowhere else (no step runs it)" "$(grep -o '/security-review' "$AP" | wc -l | tr -d ' ')"
aps "autopilot: a triage comment with neither verdict stops the run" "no \`needs:human\`. Neither ⇒ stop."
grep -q "author is not the Principal" "$AP" && grep -q 'docs/adlc/CHARTER.md' "$AP" && ok "autopilot: the author gate reads the Principal's handle from the charter" || bad "autopilot: the author gate must read the handle from docs/adlc/CHARTER.md"
aps "…another issue author stops the run" "\`gh issue view N --json author,labels\`: another author ⇒ stop."
# the PR gate (review finding 1): the lanes run only on a PR the Principal or the bot opened; a stranger's PR that
# says `Closes #N` must not be the one the Builder and QA check out
aps "autopilot: the PR is found by its head branch" "is the one open PR whose head branch starts \`feat/N-\` (\`gh pr list --state open --json number,headRefName,author\`), never one found by its \`Closes #N\`."
aps "…and another PR author, or two candidates, stops the run" "Its author is not the Principal, or two match ⇒ stop."
aps "…which the stop list names" "the issue's or the PR's author is not the Principal"
# re-entry (review finding 9)
aps "autopilot: an issue at gate:deploy, or with no state label, has an entry" "\`gate:deploy\` 9 · none ⇒ say so and end."
aps "…a needs:human from an earlier run is taken off" "A \`needs:human\` from an earlier run: take it off"
aps "…and an open PR is re-reviewed whole, at stage:qa too, and not rebuilt" "\`stage:build\` and \`stage:qa\` enter at 5 and \`stage:fast\` at its cap, the review as a first round (the whole diff"
# a pending scope request is the Architect's to answer, not a stop (review finding 10)
aps "autopilot: a red check with an unanswered scope request goes to the review" "red with an unanswered \`ADLC-SCOPE-REQUEST:\` on the PR ⇒ step 5, where the Architect answers it"
grep -q 'ADLC-SCOPE-REQUEST: <path prefix>' "$ROOT/skills/role-builder/SKILL.md" && grep -q 'ADLC-SCOPE: GRANT <path prefix>' "$ROOT/skills/role-architect/SKILL.md" && ok "…the marker the Builder posts and the Architect's review answers" || bad "role-builder / role-architect lost the ADLC-SCOPE-REQUEST / ADLC-SCOPE markers the autopilot relies on"
grep -q '^\*\*Status:\*\* .*\*\*Principal:\*\* {{PRINCIPAL}}' "$ROOT/templates/charter.md.tmpl" && ok "…which the charter template still carries on its Principal: line" || bad "charter.md.tmpl lost the **Principal:** {{PRINCIPAL}} field the autopilot's author gate reads"
# stops and labels: every label it puts on something is one labels.sh creates
grep -q 'label `needs:human`' "$AP" && ok "autopilot: a stop labels needs:human" || bad "autopilot must label needs:human when it stops"
for l in needs:human adlc:autopilot adlc:changes-requested lane:fast; do
  grep -q "\`$l\`\|--add-label $l" "$AP" && grep -q "^create \"$l\"" "$ROOT/templates/github/labels.sh" && ok "…$l is a label labels.sh creates" || bad "autopilot names $l, which it or labels.sh lacks"
done
# state labels: through the relabel script only (the same two greps as the lanes and the RUNBOOK, issue 38)
eq "" "autopilot: moves state labels through adlc-relabel.sh, never a hand-spelled pair" "$(grep -nE -- '--(add|remove)-label `?(stage|gate):' "$AP" || true)"
eq "" "autopilot: no step tells anyone to \"add\" a state label" "$(grep -nE '\badds? `?(stage|gate):[a-z]+' "$AP" || true)"
eq "" "context-budget: nor does the budget" "$(grep -nE -- '--(add|remove)-label `?(stage|gate):|\badds? `?(stage|gate):[a-z]+' "$CB" || true)"
# the fix cycle
aps "autopilot: the cap is asked before each return to the Builder, and only GO returns it" "\`.adlc/scripts/adlc-fix-cap.sh --pr <pr>\`: only a printed \`GO\` sends the PR back"
aps "…a STOP, or no answer, stops the run" "\`STOP\`, or no answer (it could not read), ⇒ stop."
# Every return is counted and re-reviewed (review finding 2). A QA or red-check return leaves no CHANGES marker, so
# the label event is all the cap can count; and a fix that skipped step 5 would reach Gate 2 unreviewed.
aps "autopilot: every return to the Builder is labelled before the cap is asked" "EVERY return to the Builder — a \`CHANGES\` verdict, QA findings, a red check — goes through here. Label the PR \`adlc:changes-requested\` (that label event is what the cap counts for a QA or red-check return), then \`.adlc/scripts/adlc-fix-cap.sh --pr <pr>\`"
aps "…and every fix is reviewed again" "Then the checks, and ALWAYS step 5 again: no fix reaches QA or Gate 2 unreviewed."
aps "…QA's too" "Findings ⇒ step 6; QA runs again only once step 5 has passed again."
if command -v jq >/dev/null 2>&1; then
  QR="$(mktemp -d)"; rounds_stub "$QR"
  qcap() { ( cd "$QR" && env PATH="$QR/bin:$PATH" RD_DIR="$QR" bash "$S/adlc-fix-cap.sh" --pr "$1" 2>/dev/null ); }
  # two reviews asked for changes, then QA sent the PR back twice in comments that carry no verdict marker
  rounds_comments "$QR" 1 'ADLC-ADV: CHANGES' 'ADLC-ADV: CHANGES' 'ADLC-ADV: PASS' 'ADLC-ARCH: PASS' 'QA: S2-AC1 has no test.' 'QA: still none.'
  cp "$QR/fx/pr-1.json" "$QR/fx/pr-2.json"; rounds_labels "$QR" 2 4
  eq GO   "fixture: with no label on a QA return, the cap sees 2 rounds in 4 returns" "$(qcap 1)"
  eq STOP "labelled as the skill says, the fourth return is a STOP" "$(qcap 2)"
  rm -rf "$QR"
fi
grep -q -- '--pr' "$S/adlc-fix-cap.sh" && ok "…and adlc-fix-cap.sh has the --pr form" || bad "adlc-fix-cap.sh must keep the --pr form: the autopilot's cap call depends on it"
grep -q 'FIX DELTA' "$AP" && grep -q 'break the fixes, do not confirm them' "$AP" && ok "autopilot: round 2 is an adversarial pass over the fix delta" || bad "autopilot: round 2 must be a pass over the fix delta, to break the fixes"
# …and over the earlier findings (review finding 4): a finding the Builder skipped has no hunk in the delta
aps "…and a re-check of the earlier findings: one with no fix is CHANGES again" "and its own earlier findings: an earlier finding with no fix is \`CHANGES\` again"
cbs "context-budget: round 2 re-checks every earlier finding" "Round 2 and later reviews re-check every earlier finding (one with no fix is CHANGES again), then attack the fix delta"
eq "" "…and nowhere limits round 2 to the delta" "$(grep -n 'fix delta only\|only the findings you verify' "$CB" || true)"
grep -q 'each subject starting `adlc-fix:`' "$AP" && ok "autopilot: fix commits carry the adlc-fix: prefix, as the fix lane's do" || bad "autopilot: fix commits must start adlc-fix:"
grep -q 'run `adlc-architect` ONCE to amend the ADR' "$AP" && ok "autopilot: one ADR amendment pass" || bad "autopilot: the ADR amendment must be one pass"
[ "$(grep -n 'ONCE to amend' "$AP" | cut -d: -f1)" -lt "$(grep -n 'adlc-relabel.sh N stage:qa' "$AP" | cut -d: -f1)" ] 2>/dev/null && ok "…before the issue moves to stage:qa" || bad "autopilot: the amendment must come before stage:qa"
grep -q "does not re-run the reviewers'" "$AP" && ok "autopilot: QA trusts the recorded verdicts" || bad "autopilot: QA must not re-run the reviewers' reproductions"
aps "…and still runs its own security gate" "its own security gate still runs in full."
# the budget trims reading, never a check (review finding 5)
cbs "context-budget: the role skill wins, and no check is trimmed" "The budget trims reading and prose, never a check: where it and your role skill disagree, the role skill wins, and a check that skill or \`adlc:security-gate\` asks for is made in full."
cbs "context-budget: QA attempts every security-gate class" "It still attempts **every** \`adlc:security-gate\` class itself"
eq "" "…with no class left to what the reviews named" "$(grep -n 'classes the reviews did not name' "$CB" || true)"
# the fast lane (review findings 6 and 7): the cap before the checks, and never a gate:deploy without the review
aps "autopilot fast lane: the cap runs before the checks" "then label the PR \`lane:fast\`. Before the checks (an over-cap PR fails \`ADLC diff-scope\`), the cap on the REAL diff"
aps "…the checks and the adversarial review follow a FAST answer" "\`FAST\` ⇒ the checks as in step 4, then \`adlc-adversarial-reviewer\` only (there is no ADR), its \`ADLC-ADV\` read as in step 5: \`CHANGES\` ⇒ step 6, then the cap, the checks and the review again; \`PASS\` ⇒ you move the issue with \`.adlc/scripts/adlc-relabel.sh N gate:deploy\`"
eq 1 "…and that PASS is the fast lane's only way to gate:deploy" "$(grep -o 'adlc-relabel.sh N gate:deploy' "$AP" | wc -l | tr -d ' ')"
# the context budget
grep -q '## Context budget' "$CB" && grep -q 'project-conventions' "$CB" && ok "context-budget: a repo's own caps live under ## Context budget in project-conventions" || bad "context-budget must say where a repo overrides a cap"
grep -q 'adlc-run-log.sh' "$CB" && grep -q 'Do not record or report your own token use' "$CB" && ok "context-budget: tokens are measured (adlc-run-log.sh), never self-reported" || bad "context-budget must send token figures to adlc-run-log.sh"
eq "" "context-budget: no token ledger of its own, and no percentage promised" "$(grep -nE 'tokens\.jsonl|[0-9] ?%' "$CB" || true)"
for r in 'Analyst' 'Architect (design)' 'Builder' 'Adversarial reviewer' 'Architect (conformance)' 'QA'; do grep -qF "| $r |" "$CB" || bad "context-budget: the read table has no row for $r"; done
grep -q 'A cap never trims evidence' "$CB" && ok "context-budget: a cap never trims evidence (efficient-runs' exception)" || bad "context-budget must keep quoted evidence out of the caps"
# The cap: the autopilot's command takes the diff with the fast lane's flags, and is run here as
# written (its fenced block, with <base> and <branch> filled in) in a clone with an origin.
fl='git -c core.quotePath=false diff --numstat --no-renames --raw --ignore-submodules=none'
grep -qF -- "$fl" "$AP" && grep -qF -- "$fl" "$ROOT/templates/github/adlc-fast.yml" && ok "autopilot takes the fast-lane diff with adlc-fast.yml's flags" || bad "autopilot and adlc-fast.yml must take the diff the same way"
if command -v git >/dev/null 2>&1; then
  AC="$(mktemp -d)"
  agit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
  awk '/^```bash$/ {f=1; next} /^```$/ {f=0} f' "$AP" > "$AC/cap.tmpl"
  eq 3 "the cap command is the skill's one fenced block" "$(grep -c . "$AC/cap.tmpl")"
  {
    agit init -q "$AC/seed"; agit -C "$AC/seed" symbolic-ref HEAD refs/heads/main
    mkdir -p "$AC/seed/src"; echo 'x = 1' > "$AC/seed/src/a.py"; agit -C "$AC/seed" add -A; agit -C "$AC/seed" commit -q -m init
    agit -C "$AC/seed" checkout -q -b feat/1-small main; echo 'y = 2' >> "$AC/seed/src/a.py"; agit -C "$AC/seed" commit -q -am small
    agit -C "$AC/seed" checkout -q -b feat/2-auth main; mkdir -p "$AC/seed/auth"; echo 'k = 1' > "$AC/seed/auth/login.py"; agit -C "$AC/seed" add -A; agit -C "$AC/seed" commit -q -m auth
    agit -C "$AC/seed" checkout -q -b feat/3-empty main; agit -C "$AC/seed" commit -q --allow-empty -m nothing
    agit -C "$AC/seed" checkout -q main             # main moves on by more files than the cap allows
    for f in m1 m2 m3 m4 m5 m6; do echo x > "$AC/seed/src/$f.py"; done; agit -C "$AC/seed" add -A; agit -C "$AC/seed" commit -q -m 'main moves on'
    agit clone -q "$AC/seed" "$AC/work"; mkdir -p "$AC/work/.adlc/scripts"; cp "$S/adlc-triage.sh" "$AC/work/.adlc/scripts/"; chmod +x "$AC/work/.adlc/scripts/adlc-triage.sh"
  } >/dev/null 2>&1
  apcap() { # <base> <branch> → what the command prints
    sed -e "s|<base>|$1|g" -e "s|<branch>|$2|g" "$AC/cap.tmpl" > "$AC/cap.sh"
    ( cd "$AC/work" && env -u ADLC_FAST_MAX_FILES -u ADLC_FAST_MAX_LINES -u ADLC_FAST_DENY GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$AC/cap.sh" 2>/dev/null )
  }
  eq FAST "autopilot cap: a small change prints FAST, measured from the merge base (main has moved on by 6 files)" "$(apcap main feat/1-small)"
  eq FULL "autopilot cap: a sensitive path prints FULL" "$(apcap main feat/2-auth)"
  eq ""   "autopilot cap: an empty diff prints nothing (the skill stops; the script alone would say FAST)" "$(apcap main feat/3-empty)"
  eq ""   "autopilot cap: a base branch the clone does not have prints nothing" "$(apcap gone feat/1-small)"
  grep -q 'Nothing printed (the diff could not be taken, or is empty) ⇒ stop' "$AP" && ok "…and the skill reads nothing printed as a stop, never as fast" || bad "autopilot must stop when the cap command prints nothing"
  rm -rf "$AC"
else
  bad "autopilot cap command tests need git"
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
