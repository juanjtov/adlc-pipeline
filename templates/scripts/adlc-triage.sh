#!/usr/bin/env bash
# Fast-lane eligibility cap — the deterministic backstop that makes skipping design SAFE.
# A change may take the fast lane (skip the Architect/ADR and Gate 1) ONLY if it stays small
# and touches nothing sensitive. Triage *judgment* (the `triage` skill) proposes the fast lane;
# THIS script enforces it against the real change, so a mis-triage — or a prompt-injected issue
# — can't smuggle a large or sensitive change through the shortened path.
#
# Single source of truth: run at intake on the estimated file list (advisory) AND in
# adlc-fast.yml on the real PR diff (blocking). Human Gate 2 (merge) is unaffected either way.
#
# Usage:  adlc-triage.sh < changed-files
#   STDIN: one changed file per line. Optionally `git diff --numstat` form
#          (<added>\t<deleted>\t<path>) — then the line-count cap is enforced too; with bare
#          paths the line cap is skipped (advisory, file-count + sensitive-path only).
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
# config, dependency manifests, and secrets. A change to any of these needs real design — no
# matter how few lines — because its blast radius isn't local.
deny="${ADLC_FAST_DENY:-(^|/)(migrations?|auth|authz|security|infra|terraform|deploy|helm|k8s|kubernetes)/|(^|/)\.github/|(^|/)\.claude/|(^|/)(Dockerfile|docker-compose\.ya?ml)$|(^|/)(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|Pipfile|Pipfile\.lock|poetry\.lock|pyproject\.toml|go\.mod|go\.sum|Gemfile|Gemfile\.lock|Cargo\.toml|Cargo\.lock|composer\.json|composer\.lock|pom\.xml|build\.gradle|build\.gradle\.kts)$|(^|/)\.?env(\.|$)|(^|/)secrets?(\.|/)}"

tab=$(printf '\t')
files=0; lines=0; reasons=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # numstat form?  <added>\t<deleted>\t<path> — detect on the literal TABs numstat always uses,
  # and split on tab (cut's default) so a path with SPACES stays intact. Splitting on whitespace
  # (awk default) truncated "my dir/.env" to "my" and let sensitive paths past the cap.
  if printf '%s' "$line" | grep -qE "^[0-9-]+${tab}[0-9-]+${tab}"; then
    a=$(printf '%s' "$line" | cut -f1)
    d=$(printf '%s' "$line" | cut -f2)
    f=$(printf '%s' "$line" | cut -f3-)
    # binary files show as '-' in numstat — size is unknowable, so never fast-eligible
    if [ "$a" = "-" ] || [ "$d" = "-" ]; then reasons+=("binary change: $f"); fi
    [ "$a" = "-" ] && a=0
    [ "$d" = "-" ] && d=0
    lines=$((lines + a + d))
  else
    f="$line"
  fi
  files=$((files + 1))
  printf '%s\n' "$f" | grep -qE "$deny" && reasons+=("sensitive path: $f")
done

[ "$files" -gt "$max_files" ] && reasons+=("too many files: $files > $max_files")
[ "$lines" -gt "$max_lines" ] && reasons+=("too many lines: $lines > $max_lines")

if [ "${#reasons[@]}" -gt 0 ]; then
  printf 'not fast-eligible: %s\n' "${reasons[@]}" >&2
  echo "FULL"
  exit 1
fi
echo "FAST"
exit 0
