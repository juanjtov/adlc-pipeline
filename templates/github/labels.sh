#!/usr/bin/env bash
# Create the ADLC label state machine in the current GitHub repo.
# Idempotent: re-running updates color/description instead of erroring.
# Requires: gh authenticated against this repo (gh auth status).
set -euo pipefail

create() { # name color description
  gh label create "$1" --color "$2" --description "$3" --force >/dev/null
  echo "  ✓ $1"
}

echo "Creating ADLC labels…"
# Stage labels (an agent is working)
create "stage:intake"  "0E8A16" "Agent 1 — Product Analyst: requirement → stories + ACs"
create "stage:design"  "1D76DB" "Agent 2 — Architect: ADR + task breakdown + blast radius"
create "stage:build"   "5319E7" "Agent 3 — Builder: code + unit tests → PR"
create "stage:qa"      "B60205" "Agent 4 — QA/Release-Ops: tests + security gate"
# Gate labels (work stops for the Principal)
create "gate:stories"  "FBCA04" "GATE 1 — Principal: story approval"
create "gate:deploy"   "FBCA04" "GATE 2 — Principal: merge · deploy · migration"
# Pipeline control
create "adlc:auto"     "C5DEF5" "Auto-run the Analyst on this issue (auto-start; you still approve Gate 1)"
create "adlc:autopilot" "5319E7" "Full autopilot: also auto-approve Gate 1 — only Gate 2 (merge/deploy) is human"
create "bug"           "D73A4A" "Defect filed by Ops — lands at stage:intake with telemetry"
create "adlc:changes-requested" "FBCA04" "A review flagged the PR — the fix loop returns it to the Builder"
create "needs:human"   "E99695" "Fix loop capped out (3 rounds) — a human must step in on this PR"

echo "Done. State machine:"
echo "  stage:intake → gate:stories → stage:design → stage:build → stage:qa → gate:deploy"
