#!/usr/bin/env bash
# Unit tests for the ADLC guardrail scripts. Plain bash; the guard hook also needs python3 + git.
# Run: bash tests/run.sh   (exit 0 = all pass). These verify the deterministic guardrails
# themselves — the same scripts CI and the local pre-commit hook call — plus the plugin's guard
# hook. The static checks cover what can't be run here for real: the workflow templates (their
# triggers, their agent wiring, and the intake, diff-scope and design-handoff steps against a
# stub gh), the pre-commit hook, and labels.sh.
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
grep -q -- 'git diff --numstat --no-renames' "$ROOT/templates/github/adlc-fast.yml" && ok "adlc-fast.yml takes the cap's diff with --no-renames" || bad "adlc-fast.yml: the cap's diff must use --no-renames"
# Both workflows take that diff with the modes (--raw) and with every submodule entry in it
# (--ignore-submodules=none: a `.gitmodules` saying `ignore = all` in the checkout — the PR's in
# adlc-fast.yml, the default branch's in adlc-diff-scope.yml — would otherwise leave it out).
grep -qF -- 'git diff --numstat --no-renames --raw --ignore-submodules=none "$base"' "$ROOT/templates/github/adlc-fast.yml" && ok "…with the modes, and every submodule entry" || bad "adlc-fast.yml: the cap's diff must take --raw --ignore-submodules=none"
grep -qF -- 'diff --numstat --no-renames --raw --ignore-submodules=none "$base" refs/remotes/pr/head' "$ROOT/templates/github/adlc-diff-scope.yml" && ok "adlc-diff-scope.yml: its copy of the cap's diff takes the same flags" || bad "adlc-diff-scope.yml: the cap's diff must take --no-renames --raw --ignore-submodules=none"

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
# a lane that calls the action with no plugin and no tools starts, and its agent can do nothing
doctor() { ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; }
lane()   { printf "$@" > "$FIX/.github/workflows/adlc-x.yml"; }
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
# the merge gate — asked of a stub gh that answers each lookup from a file (no file = that call fails)
mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$DFX/calls"
case "$*" in
  "auth status"*) exit 0 ;;
  "label list"*)  printf '%s\n' stage:intake gate:stories stage:design stage:build stage:qa gate:deploy; exit 0 ;;
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
  GATE=$(DFX="$FIX/fx" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" 2>&1)
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
gate true 1 none; rm "$FIX/fx/default"
DFX="$FIX/fx" PATH="$FIX/bin:$PATH" bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1; check 1 "gate: an unreadable default branch is flagged" $?
lane 'jobs:\n  t:\n    steps:\n      - run: echo hi\n'   # no lane runs an agent: nothing to gate
gate false - none;           check 0 "gate: not checked when no lane runs an agent" $?
eq 0 "…no lookup is made" "$(grep -c '^api ' "$FIX/fx/calls" 2>/dev/null || true)"
lane "${J}${WIRED}"; rm -rf "$FIX/fx"; mkdir -p "$FIX/fx"
DFX="$FIX/fx" PATH="$FIX/bin:$PATH" ADLC_DOCTOR_SKIP_LABELS=1 bash "$S/adlc-doctor.sh" "$FIX" >/dev/null 2>&1
eq "" "ADLC_DOCTOR_SKIP_LABELS=1 keeps the doctor off gh entirely" "$(cat "$FIX/fx/calls" 2>/dev/null)"
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
# every lane PR to "no stage" and skipped. Run it as shipped, in what the job really works in: a
# checkout of the BASE branch, with the PR reachable only as data (the API and refs/pull/N/head).
WF="$ROOT/templates/github/adlc-diff-scope.yml"
grep -q '^  pull_request_target:' "$WF" && ok "runs on pull_request_target (workflow and scripts from the base branch)" || bad "adlc-diff-scope.yml must run on pull_request_target"
grep -qE '^[[:space:]]+ref:' "$WF" && bad "adlc-diff-scope.yml must never check out the PR head" || ok "…and never checks out the PR head"
# every event that can change the verdict: a push, the Builder's lane:fast label, a body edit or retarget
grep -q '^    timeout-minutes:' "$WF" && ok "…with a time limit (the scope file and the diff are the PR's to size)" || bad "adlc-diff-scope.yml: the job needs timeout-minutes"
grep -q 'types: \[opened, synchronize, reopened, labeled, unlabeled, edited\]' "$WF" && ok "…on every event that can change the verdict" || bad "adlc-diff-scope.yml: types must be opened, synchronize, reopened, labeled, unlabeled, edited"
grep -qE '^    if:' "$WF" && bad "adlc-diff-scope.yml: the job must have no if: — a skipped job would replace a failed verdict with a pass" || ok "…with no job condition (a skipped job would replace a failed verdict with a pass)"
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
  "api "*"/contents/.adlc/scope/"*"?ref=refs/pull/7/head"*"application/vnd.github.raw"*)
                                      k="scope-$(printf '%s\n' "$*" | sed -n 's|.*/scope/\([0-9][0-9]*\)\.txt.*|\1|p')" ;;
  "api "*"/issues/"*)                 k="issue-$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p')" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 2 ;;
esac
[ -e "$FX/fail-$k" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
[ -e "$FX/$k" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$FX/$k"
SH
chmod +x "$DS/bin/gh"
# dsfx <PR labels> <closing reference> <issue> <its labels | - (no such issue)> <the PR's scope file | -> <changed files>
dsfx() {
  rm -rf "$DS/fx" "$DS/repo/.adlc/scope"; mkdir -p "$DS/fx"
  printf '%b' "$1" > "$DS/fx/pr-labels"; printf '%b' "$2" > "$DS/fx/closing"; printf '%b' "$6" > "$DS/fx/files"; echo 3 > "$DS/fx/nfiles"
  [ "$4" = - ] || printf '%b' "$4" > "$DS/fx/issue-$3"
  [ "$5" = - ] || printf '%b' "$5" > "$DS/fx/scope-$3"
}
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
printf 'stage:build\n' > "$DS/fx/issue-13"; printf 'src/billing/\n' > "$DS/fx/scope-13"
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
printf 'stage:qa\n' > "$DS/fx/issue-20"; printf 'src/api/\n' > "$DS/fx/scope-20"
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
for k in pr-labels files closing issue-12 nfiles scope-12; do   # an API error must never read as "nothing to check"
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
dsfx '' '12\n' 12 'stage:build\n' 'src/api/\n' 'src/api/x.py\n'; : > "$DS/fx/fail-scope-12"
out=$(dsout)
case "$out" in *"HTTP 502"*) case "$out" in *"no scope file"*) bad "an API error must not be reported as a missing scope file" ;; *) ok "an API error on the scope file is reported as that, not as a missing scope file" ;; esac ;; *) bad "an API error on the scope file must be reported" ;; esac
dsfx '' '12\n' 12 'stage:design\n' - 'src/api/x.py\n'; : > "$DS/fx/fail-scope-12"
dsrun; check 0 "a PR with no lane stage never asks for a scope file" $?
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
   "$(cd "$DS/repo" && dg fetch -q origin refs/pull/7/head && dg diff --numstat --no-renames refs/remotes/origin/main FETCH_HEAD 2>/dev/null)"
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
git -C "$DS/remote.git" update-ref -d refs/pull/7/head
fastfx '' 'src/a.py\n';                    dsrun; [ $? -ne 0 ] && ok "fast lane: a PR head that cannot be fetched fails the check" || bad "fast lane: an unfetchable PR head must fail the check"
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
                case "$*" in *"--json comments"*) cat "$HO_COMMENTS" ;; *) exit 2 ;; esac ;;
  "issue comment"|"issue edit") shift; echo "$*" >> "$HO_CALLS" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$HO/bin/gh"
  hgit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
  hgit init -q --bare "$HO/origin.git"; hgit -C "$HO/origin.git" symbolic-ref HEAD refs/heads/main
  hgit init -q "$HO/seed"; hgit -C "$HO/seed" symbolic-ref HEAD refs/heads/main
  mkdir -p "$HO/seed/.adlc/scripts" "$HO/seed/docs/adr" "$HO/seed/src/api"
  cp "$S/adlc-diff-scope.sh" "$HO/seed/.adlc/scripts/"
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
  eq ".adlc/scope/7.txt|.adlc/scripts/adlc-diff-scope.sh|docs/adr/0001-adopt.md|docs/adr/0002-login.md|docs/adr/template.md|docs/guide.md|src/api/a.py|" \
     "the design branch holds the docs and the scope file, not the stray file" "$(otree adlc/design-7)"
  eq "docs/adr/0002-login.md|docs/guide.md|" "the scope file lists exactly the design files it committed" "$(oscope 7)"
  eq "adlc-design <adlc-design@users.noreply.github.com>" "the commit is the design lane's" "$(hgit -C "$HO/origin.git" log -1 --format='%an <%ae>' adlc/design-7 2>/dev/null)"
  eq "comment 7 --body 📐 Design handed|edit 7 --remove-label stage:design --add-label stage:build|" "the issue advances, after the push" "$(hcalls)"
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
eq "adlc:product-analyst=Skill,Bash(gh issue view:*),Bash(gh issue comment:*),Bash(gh issue edit:*),Bash(gh issue list:*),Bash(gh label list:*),Bash(gh search:*),Bash(.adlc/scripts/adlc-triage.sh:*);" \
   "intake: the Analyst, named gh commands, no edit tools" "$(grants adlc-intake.yml)"
eq "adlc:architect=Edit(docs/**),Skill,Bash(gh issue view:*),Bash(gh issue comment:*),Bash(gh issue list:*),Bash(gh pr view:*),Bash(gh pr list:*),Bash(gh pr diff:*),$GITRO;" \
   "design: the Architect, edits under docs/ only, no commit/push/label" "$(grants adlc-design.yml)"
eq "adlc:adversarial-reviewer=$REVIEW;adlc:architect=$REVIEW;" "review: both reviewers read and comment only" "$(grants adlc-review.yml)"
eq "adlc:builder=$FULL;adlc:adversarial-reviewer=$REVIEW;"      "fast: the Builder builds, the reviewer reads and comments" "$(grants adlc-fast.yml)"
eq "adlc:builder=$FULL;"         "builder: the Builder"  "$(grants adlc-builder.yml)"
eq "adlc:builder=$FULL;"         "fix: the Builder"      "$(grants adlc-fix.yml)"
eq "adlc:qa-release-ops=$FULL;"  "qa: QA"                "$(grants adlc-qa.yml)"
eq "-=$FULL;"                    "retro: the /adlc:retro skill, no agent" "$(grants adlc-retro.yml)"
for f in "$T"/adlc-*.yml; do   # no template this table does not know about
  case "$(basename "$f")" in adlc-intake.yml|adlc-design.yml|adlc-review.yml|adlc-fast.yml|adlc-builder.yml|adlc-fix.yml|adlc-qa.yml|adlc-retro.yml) ;;
    *) eq "" "$(basename "$f"): runs no agent (or add it to the grants table)" "$(grants "$(basename "$f")")" ;; esac
done
for a in $(grep -hoE -- '--agent adlc:[a-z-]+' "$T"/adlc-*.yml | sed 's/.*adlc://' | sort -u); do
  [ -f "$ROOT/agents/$a.md" ] && ok "lane agent exists: $a" || bad "lane names a missing agent: $a"
done
# `tools:` takes tool NAMES. A command specifier there is ignored and grants the whole tool.
for f in "$ROOT"/agents/*.md; do
  case "$(grep -m1 '^tools:' "$f")" in
    *"("*) bad "$(basename "$f"): tools: has a command specifier" ;;
    *Skill*) ok "$(basename "$f"): tools: are plain names, Skill included" ;;
    *) bad "$(basename "$f"): tools: lacks Skill (the agent could not load its skills)" ;;
  esac
done

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
  # scope: a no-op outside CI unless the repo adopted ADLC; fails CLOSED without python3.
  # Run from a directory that is NOT an ADLC repo, with the CI marker unset, so the result
  # does not depend on where (or under which runner) this suite itself runs.
  M="$(hook_json - "$GR/feat" 'gh pr merge 5')"
  mkdir -p "$GR/adopted/.adlc" "$GR/adopted/sub/dir" "$GR/chartered/docs/adlc" "$GR/plain" "$GR/fakepy" "$GR/plug in/hooks"; : > "$GR/chartered/docs/adlc/CHARTER.md"
  local_hook() { # <project dir | -> [ENV=val …] — the launcher as a local session runs it, from $GR/plain
    local proj="$1"; shift
    if [ "$proj" = - ]; then ( cd "$GR/plain" && printf '%s' "$M" | env -u GITHUB_ACTIONS -u CLAUDE_PROJECT_DIR "$@" bash "$H" ) >/dev/null 2>&1
    else ( cd "$GR/plain" && printf '%s' "$M" | env -u GITHUB_ACTIONS CLAUDE_PROJECT_DIR="$proj" "$@" bash "$H" ) >/dev/null 2>&1; fi
  }
  local_hook "$GR/plain";            check 0 "no-op in a repo that has not adopted ADLC" $?
  local_hook -;                      check 0 "…also with no project dir at all" $?
  local_hook "$GR/adopted";          check 2 "active locally when .adlc/ exists" $?
  local_hook "$GR/adopted/sub/dir";  check 2 "active from a subdirectory of an ADLC repo" $?
  local_hook "$GR/chartered";        check 2 "active locally when docs/adlc/CHARTER.md exists" $?
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

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
