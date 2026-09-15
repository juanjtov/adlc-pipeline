#!/usr/bin/env bash
# adlc doctor — validate that an ADLC host-repo setup is intact. Run from the repo root
# (or pass the root as $1). Non-zero exit if any problem is found.
# Checks: harness deny rules present · no leftover {{...}} placeholders in copied workflows ·
#         the project skills exist · the state-machine labels exist (when gh is available).
set -uo pipefail
root="${1:-.}"
probs=0
note() { echo "  ✗ $1"; probs=$((probs + 1)); }
ok()   { echo "  ✓ $1"; }
echo "adlc doctor — ${root}"

# 1) Harness deny rules (no push-to-main / no self-merge)
if grep -q 'gh pr merge' "${root}/.claude/settings.json" 2>/dev/null; then
  ok "deny rules present (.claude/settings.json)"
else
  note "no 'gh pr merge' deny rule in .claude/settings.json"
fi

# 2) No unfilled {{PLACEHOLDER}} left in copied workflows
if ls "${root}"/.github/workflows/adlc-*.yml >/dev/null 2>&1; then
  hits=$(grep -lE '\{\{[A-Z_]+\}\}' "${root}"/.github/workflows/adlc-*.yml 2>/dev/null || true)
  if [ -n "$hits" ]; then
    note "unfilled {{...}} placeholders in workflows:"; printf '      %s\n' $hits
  else
    ok "workflow placeholders filled"
  fi
else
  ok "no adlc workflows (local-recipe mode)"
fi

# 3) Project skills the agents load
for s in project-conventions release-ops; do
  if [ -f "${root}/.claude/skills/${s}/SKILL.md" ]; then ok "skill: ${s}"; else note "missing skill: .claude/skills/${s}/SKILL.md"; fi
done

# 4) Prompt-cache hygiene — the persistent prefix (CLAUDE.md + the skills the agents load)
#    is the cached part of every request. Prefix caching is a byte-exact match, so a per-run
#    value baked in here — a live timestamp, a CI run id, an unfilled placeholder — changes
#    the prefix on every run and re-processes everything after it at full price. Per-run
#    values belong in the task prompt (the volatile tail), never in a frozen context file.
ctx=()
for f in "${root}/CLAUDE.md" "${root}/.claude/CLAUDE.md"; do [ -f "$f" ] && ctx+=("$f"); done
while IFS= read -r f; do [ -n "$f" ] && ctx+=("$f"); done < <(ls "${root}"/.claude/skills/*/SKILL.md 2>/dev/null || true)
if [ "${#ctx[@]}" -gt 0 ]; then
  # High-signal, per-run invalidators only (a bare date like 2026-09-15 is allowed — the
  # ablation stamp is an intentional, rarely-changing value, not per-run).
  inv='\{\{[A-Z_]+\}\}|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:|\$\(date|`date|date \+%|GITHUB_RUN_ID|GITHUB_SHA|\$GITHUB_'
  hits=$(grep -lE "$inv" "${ctx[@]}" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    note "prompt-cache: per-run value in a frozen context file (breaks prefix caching):"
    printf '      %s\n' $hits
  else
    ok "prompt-cache: persistent prefix looks frozen"
  fi
fi

# 5) State-machine labels (only if gh is available and authenticated; set
#    ADLC_DOCTOR_SKIP_LABELS=1 to skip — used by the unit tests)
if [ -z "${ADLC_DOCTOR_SKIP_LABELS:-}" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  existing=$(gh label list --limit 200 2>/dev/null | awk '{print $1}')
  for l in stage:intake gate:stories stage:design stage:build stage:qa gate:deploy; do
    printf '%s\n' "$existing" | grep -qx "$l" || note "missing GitHub label: $l"
  done
else
  echo "  · skipped label check (gh not available/authenticated)"
fi

if [ "$probs" -eq 0 ]; then echo "OK — setup looks intact."; exit 0; else echo "${probs} problem(s) found."; exit 1; fi
