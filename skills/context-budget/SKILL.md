---
name: context-budget
description: "Opt-in context budget for the ADLC roles — what each role reads, how much it writes, how many rounds, when to stop. Every gate stays; each check is done once. The agent wrappers do not preload it: /adlc:autopilot names it in each subagent's brief, and a repo may add adlc:context-budget to a wrapper's skills: list. A repo's own caps go under '## Context budget' in its project-conventions skill."
---

# Context budget — read less, write less, do each check once

Cost grows with **artifact size × rounds**. Every gate stays. Each check is done **once**, by the
role that owns it; a later role trusts the recorded verdict and checks only the delta. The caps
below are defaults: where this repo's `project-conventions` skill has a `## Context budget`
section (its own caps, or token targets per stage), that section wins.

## Read only what your role needs

| Role | Read | Do not read |
|---|---|---|
| Analyst | the issue, the PRD sections it cites, `project-conventions` | other issues' stories, ADRs |
| Architect (design) | the stories and ACs, the seams `project-conventions` names, the interface sections of the ADRs your blast radius names | the PRD beyond the cited sections, PR threads |
| Builder | the ADR, the task breakdown, the code you touch | the Analyst's comment beyond the AC ids you trace, the PRD, other ADRs |
| Adversarial reviewer | the diff, the ADR's decisions, the ACs | earlier review threads (round 2: only the findings you verify) |
| Architect (conformance) | `.adlc/scope/<issue>.txt` against the breakdown's declared scope, the ADR's section list, `gh pr diff --name-only`; then **every** migration, new module, auth or config file, and at most 5 others | the rest of the diff line by line |
| QA | the AC list, the two verdict comments, the changed files | the reviewers' reproduction threads, the PRD |

## Write within these caps

A cap never trims evidence: a test summary line, a failing assertion and a finding are quoted
whole (`adlc:efficient-runs`). Cut prose.

- **Stories:** ≤ 8 stories, ≤ 6 ACs each, one line per AC; ≤ 12 KB. Over ⇒ ask for the issue to
  be split at intake. Never merge or drop ACs to fit: the AC list is QA's coverage matrix.
- **ADR:** ≤ 300 lines. Decisions, interfaces, migrations by file, the task list with scopes;
  cite AC ids, never restate them. Over ⇒ split by domain into linked ADRs; never thin the
  decisions.
- **Task breakdown comment:** ≤ 8 KB; each task's diff scope as path prefixes.
- **Review comment:** ≤ 60 lines — the findings (severity · class · file:line · failing input →
  result · fix), one `ADLC-FINDING:` line per finding, a structured-disagreement note of ≤ 5
  lines, the verdict line last. Reproduce a High or Critical candidate, and any `tenant-leak` or
  `authz-gap` candidate whatever its severity; judge other Medium and Low ones by reading.
- **Round 2 review:** ≤ 40 lines, over the fix delta only.
- **QA comment:** ≤ 80 lines — coverage table, result lines, security delta, Action Card.
- **PR body:** ≤ 6 KB — `Closes #N`, a story → tests table, result lines, deviations.
- **Report to whoever invoked you:** ≤ 150 words plus the verdict line and links. The comment on
  GitHub is the record; do not repeat it.

## Rounds

- Run the full battery **once** before pushing, not per file.
- A Builder fix round applies **all** findings of both reviews in one commit series. No polish
  pass after a PASS: what it leaves over is QA's.
- Round 2 and later reviews are an adversarial pass over the fix delta: break the fixes, do not
  confirm them.
- The ADR is amended in **one** pass, by the Architect, after the last review PASS and before the
  issue moves to `stage:qa`: every declared deviation and all review drift together.
- QA trusts the recorded review verdicts and does **not** re-run the reviewers' reproductions. It
  always attacks tenant/scope isolation and auth on every new table or endpoint
  (`adlc:security-gate`), then the classes the reviews did not name, then AC coverage and the
  battery. Left over by a PASS: Medium-or-worse security ⇒ QA returns the PR; anything else ⇒ a
  follow-up listed on the Action Card.
- Stop when your verdict or artefact is posted. Do not summarise the repo, the PRD or the process.

## Tokens are measured, never self-reported

Do not record or report your own token use, and keep no token ledger in the repo.
`.adlc/scripts/adlc-run-log.sh` builds the run ledger (tokens, cost and seconds per agent run)
from Mission Control's store or the OTel collector, where one of the two is on, and
`/adlc:cycle-retro` ranks it.
