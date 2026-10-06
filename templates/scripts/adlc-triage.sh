#!/usr/bin/env bash
# Fast-lane eligibility cap — the deterministic backstop that makes skipping design SAFE.
# A change may take the fast lane (skip the Architect/ADR and Gate 1) ONLY if it stays small
# and touches nothing sensitive. Triage *judgment* (the `triage` skill) proposes the fast lane;
# THIS script enforces it against the real change, so a mis-triage — or a prompt-injected issue
# — can't smuggle a large or sensitive change through the shortened path.
#
# Single source of truth: run at intake on the estimated file list (advisory), in adlc-fast.yml
# on the real PR diff (it routes an over-cap PR to the full pipeline), and in adlc-diff-scope.yml
# on the same diff from the DEFAULT branch — the verdict a PR cannot edit. Human Gate 2 (merge) is
# unaffected either way.
#
# Usage:  adlc-triage.sh < changed-files
#   STDIN: one changed file per line. Optionally `git diff --numstat` form
#          (<added>\t<deleted>\t<path>) — then the line-count cap is enforced too; with bare
#          paths the line cap is skipped (advisory, file-count + sensitive-path only). Optionally,
#          alongside the numstat lines, `git diff --raw` lines (:<old mode> <new mode> <old sha>
#          <new sha> <status>\t<path>) — then a SUBMODULE change is caught too. A submodule is a
#          gitlink (mode 160000), which numstat shows as a one-line file however much code the
#          commit it points to brings in; the mode is the only thing that tells it from one. The
#          workflows take `git diff --numstat --raw` in ONE call (the modes describe the same diff
#          the counts do) with --ignore-submodules=none (a `.gitmodules` saying `ignore = all` in
#          the checkout would otherwise leave the entry out of the diff entirely).
#   STDOUT: `FAST` or `FULL`.   Exit 0 = fast-eligible.  Exit 1 = must take the full pipeline
#          (the reasons are printed on STDERR).
#
# Caps (env-overridable, so a repo can tune its own bar):
#   ADLC_FAST_MAX_FILES  (default 5)   — max changed files
#   ADLC_FAST_MAX_LINES  (default 40)  — max added+deleted lines (enforced only on numstat input)
#   ADLC_FAST_DENY (regex)             — sensitive paths that always force the full pipeline
set -uo pipefail
max_files="${ADLC_FAST_MAX_FILES:-5}"
max_lines="${ADLC_FAST_MAX_LINES:-40}"
# Default sensitive-path denylist: migrations, auth/authz, infra/deploy, CI, the ADLC harness
# config and its guard scripts (.adlc/scripts/), dependency manifests (.gitmodules among them: it
# names where each submodule comes from, and the branch `submodule update --remote` follows), and
# secrets. A change to any of these needs real design — no matter how few lines — because its
# blast radius isn't local.
deny="${ADLC_FAST_DENY:-(^|/)(migrations?|auth|authz|security|infra|terraform|deploy|helm|k8s|kubernetes)/|(^|/)\.github/|(^|/)\.claude/|(^|/)\.adlc/scripts/|(^|/)(Dockerfile|docker-compose\.ya?ml)$|(^|/)(\.gitmodules|package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|Pipfile|Pipfile\.lock|poetry\.lock|pyproject\.toml|go\.mod|go\.sum|Gemfile|Gemfile\.lock|Cargo\.toml|Cargo\.lock|composer\.json|composer\.lock|pom\.xml|build\.gradle|build\.gradle\.kts)$|(^|/)\.?env(\.|$)|(^|/)secrets?(\.|/)}"

tab=$(printf '\t')
files=0; lines=0; reasons=(); raw=0; numstat=0
# The issue's scope file (.adlc/scope/<issue>.txt) is the declaration the lane requires of every
# PR, not part of the change — it counts toward neither cap.
is_scope_file() { printf '%s\n' "$1" | grep -qE '^\.adlc/scope/[0-9]+\.txt$'; }
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # raw form?  :<old mode> <new mode> <old sha> <new sha> <status>\t<path> — the mode line of an
  # entry the numstat lines also list. A gitlink (mode 160000) on either side is a submodule
  # change — added, removed, bumped, or a file turned into one — and is never fast-eligible: as
  # with a binary, its content is not in this diff, and a bump can swap in any amount of code. A
  # mode line carries no counts and is no file of its own; the numstat line for the same path
  # does the counting.
  if printf '%s' "$line" | grep -qE "^:[0-7]{6} [0-7]{6} [0-9a-f]+ [0-9a-f]+ [A-Z][0-9]*${tab}"; then
    raw=$((raw + 1))
    old=$(printf '%s' "$line" | cut -d' ' -f1); new=$(printf '%s' "$line" | cut -d' ' -f2)
    f=$(printf '%s' "$line" | cut -f2-)
    case "$f" in \"*\") f="${f#\"}"; f="${f%\"}" ;; esac
    if [ "$old" = ":160000" ] || [ "$new" = "160000" ]; then reasons+=("submodule change: $f"); fi
    continue
  fi
  # numstat form?  <added>\t<deleted>\t<path> — detect on the literal TABs numstat always uses,
  # and split on tab (cut's default) so a path with SPACES stays intact. Splitting on whitespace
  # (awk default) truncated "my dir/.env" to "my" and let sensitive paths past the cap.
  a=0; d=0
  if printf '%s' "$line" | grep -qE "^[0-9-]+${tab}[0-9-]+${tab}"; then
    numstat=$((numstat + 1))
    a=$(printf '%s' "$line" | cut -f1)
    d=$(printf '%s' "$line" | cut -f2)
    f=$(printf '%s' "$line" | cut -f3-)
  else
    f="$line"
  fi
  # git C-quotes a path that holds a non-ASCII byte, a quote or a backslash ("auth/\303\251.py").
  # Judge the path inside the quotes: the leading quote would hide it from every anchor below.
  case "$f" in \"*\") f="${f#\"}"; f="${f%\"}" ;; esac
  # `old => new` is git's rename notation: not a path, and its counts are 0 however big the
  # file. Feed this script `git diff --numstat --no-renames`.
  case "$f" in *" => "*) reasons+=("rename notation (use --no-renames): $f") ;; esac
  is_scope_file "$f" && continue
  # binary files show as '-' in numstat — size is unknowable, so never fast-eligible
  if [ "$a" = "-" ] || [ "$d" = "-" ]; then reasons+=("binary change: $f"); fi
  [ "$a" = "-" ] && a=0
  [ "$d" = "-" ] && d=0
  lines=$((lines + a + d))
  files=$((files + 1))
  printf '%s\n' "$f" | grep -qE "$deny" && reasons+=("sensitive path: $f")
done

[ "$files" -gt "$max_files" ] && reasons+=("too many files: $files > $max_files")
[ "$lines" -gt "$max_lines" ] && reasons+=("too many lines: $lines > $max_lines")
# Mode lines alone measure nothing: no file was counted and no path judged. That is not how the
# workflows take the diff, and not a small change — not FAST.
[ "$raw" -gt 0 ] && [ "$numstat" -eq 0 ] && reasons+=("mode lines without numstat lines (take git diff --numstat --raw): nothing measured")

if [ "${#reasons[@]}" -gt 0 ]; then
  printf 'not fast-eligible: %s\n' "${reasons[@]}" >&2
  echo "FULL"
  exit 1
fi
echo "FAST"
exit 0
