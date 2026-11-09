---
name: autopilot
description: "The local orchestrator, /adlc:autopilot <issue>: from the Principal's own session, run the ADLC chain on ONE issue unattended, one subagent per role, until its PR waits at Gate 2 (QA-approved on the full lane, adversarially reviewed on the fast lane). Gate 1 is auto-approved for a FULL triage verdict only; nothing is merged or deployed. The local counterpart of the Actions lanes under the adlc:autopilot label. Only the Principal starts it."
argument-hint: "<issue number>"
disable-model-invocation: true
---

# Autopilot (local) — one issue → a reviewed PR waiting at Gate 2

You are the Principal's own session, driving the RUNBOOK stages on issue `N` (the argument; none
⇒ ask) as the Actions lanes do, with the same scripts. You orchestrate only: you write no story,
ADR, code, test or verdict. Run each role as a subagent, in order — this repo's copy,
`adlc-<role>` (the plugin's `adlc:<role>` where a copy is missing) — and never run a role on its
own output. A brief is the issue or PR number, the duty, the artefact paths and comment links,
and "load `adlc:context-budget` first"; it does not re-explain the pipeline. Spend is measured
(`.adlc/scripts/adlc-run-log.sh`); do not log tokens yourself.

**Never automated:** Gate 2 — you never merge, deploy or run a migration (the guard hook blocks
`gh pr merge` anyway); the lane choice — only the Principal applies `stage:fast`; and
`/security-review`. An issue's state label moves only through
`.adlc/scripts/adlc-relabel.sh <issue> <label>`.

**Stop** = label `needs:human` (the PR; the issue while there is no PR), comment why, report to
the Principal, run nothing more. Stop when: the issue's or the PR's author is not the Principal;
the Analyst did not reach `gate:stories`; a role left its artefact, its verdict or its label move
undone; a check is red and the fix is not the Builder's to make (a path outside the declared
scope that no `ADLC-SCOPE-REQUEST:` asks for, a destructive migration, a weakened check); the
cap does not say `GO` (step 6).

**The PR** of issue N is the one open PR whose head branch starts `feat/N-`
(`gh pr list --state open --json number,headRefName,author`), never one found by its
`Closes #N`. Its author is not the Principal, or two match ⇒ stop.

0. **Author gate.** The Principal's handle is on the `**Principal:**` line of
   `docs/adlc/CHARTER.md` (`/adlc-init` writes it); none there ⇒ ask, touch nothing.
   `gh issue view N --json author,labels`: another author ⇒ stop. An Actions agent lane in
   `.github/workflows/` (`adlc-design.yml`, `adlc-review.yml`, …) is started by your label moves
   too: say so and wait for the Principal's word. A `needs:human` from an earlier run: take it
   off (the Principal running you again is the answer). Then enter at the issue's state label:
   `stage:intake` 1 · `gate:stories` 2 · `stage:design` 3 · `stage:build` 4 · `stage:fast` the
   fast lane · `gate:deploy` 9 · none ⇒ say so and end. With the PR already open, `stage:build`
   and `stage:qa` enter at 5 and `stage:fast` at its cap, the review as a first round (the whole
   diff: what an earlier run reviewed is unknown).
1. **Analyst.** `adlc-product-analyst` on N. Not at `gate:stories` afterwards ⇒ stop (it asked
   questions: the Principal answers with `/adlc-intake N` and runs you again).
2. **Gate 1.** Read the last triage verdict as the intake lane does:
   `gh issue view N --json comments --jq '.comments[].body' | grep -oE 'ADLC-TRIAGE:[[:space:]]*(FAST|FULL)' | tail -1`.
   `FULL` ⇒ `gh issue edit N --add-label adlc:autopilot`, `.adlc/scripts/adlc-relabel.sh N stage:design`,
   comment `Gate 1 auto-approved under adlc:autopilot; the Principal reviews at Gate 2.`
   `FAST` ⇒ start nothing: comment that the lane is the Principal's to approve (`stage:fast`, or
   `stage:design` for the full pipeline), report, end the run; no `needs:human`. Neither ⇒ stop.
3. **Design.** `adlc-architect`, design duty, on N. Done when the ADR is under `docs/adr/`
   (uncommitted, in this checkout), the breakdown comment ends `ADLC-BREAKDOWN: <ADR path>`, and
   the Architect has moved the issue to `stage:build`.
4. **Build.** `adlc-builder` on N with the ADR path: it commits the ADR on `feat/<N>-<slug>`,
   lists the ADR's path beside the breakdown's prefixes in `.adlc/scope/<N>.txt`, and opens a PR
   whose body starts `Closes #N`. Then `gh pr checks <pr> --watch`, one blocking call (a repo
   with no checks: go on). Red and the Builder's to fix ⇒ step 6 with the failing log; red with
   an unanswered `ADLC-SCOPE-REQUEST:` on the PR ⇒ step 5, where the Architect answers it; the
   same check red after a fix for it ⇒ stop.
5. **Review.** `git fetch origin` (the reviewers' git is read-only) and note `n`, the PR's
   comment count (`gh pr view <pr> --json comments --jq '.comments | length'`). Then
   `adlc-adversarial-reviewer` and, after it, `adlc-architect` (conformance duty) on the PR. Each
   posts ONE PR comment whose last line is exactly `ADLC-ADV: PASS|CHANGES` / `ADLC-ARCH:
   PASS|CHANGES` — a comment, not `gh pr review`: all roles share your `gh` login, and nobody
   approves their own PR on GitHub. Read THIS round's comments only:
   `bodies=$(gh pr view <pr> --json comments --jq '.comments[<n>:][].body')`, then
   `printf '%s\n' "$bodies" | .adlc/scripts/adlc-verdict.sh ADLC-ADV` (and `ADLC-ARCH`). An empty
   answer ⇒ stop: that reviewer posted no verdict this round, and an older comment never stands
   in. `CHANGES` from either ⇒ step 6. Both `PASS` ⇒ step 7. From round 2 on, each reviewer gets
   the FIX DELTA (`git diff <the head it reviewed>..<the new head>`) and its own earlier findings:
   an earlier finding with no fix is `CHANGES` again; then break the fixes, do not confirm them.
6. **Fix.** EVERY return to the Builder — a `CHANGES` verdict, QA findings, a red check — goes
   through here. Label the PR `adlc:changes-requested` (that label event is what the cap counts
   for a QA or red-check return), then `.adlc/scripts/adlc-fix-cap.sh --pr <pr>`: only a printed
   `GO` sends the PR back; `STOP`, or no answer (it could not read), ⇒ stop. On `GO` take the
   label off and run `adlc-builder` on the same branch with ALL the findings (both comments,
   QA's, or the log): one commit series, each subject starting `adlc-fix:`, pushed to the branch
   by name. Then the checks, and ALWAYS step 5 again: no fix reaches QA or Gate 2 unreviewed. No
   polish pass: what a `PASS` leaves over is QA's.
7. **Amend, once.** If the PR declares a deviation or a review named drift from the ADR: check
   out the PR branch, run `adlc-architect` ONCE to amend the ADR with all of it (it writes under
   `docs/` and cannot commit), commit that one file yourself and
   `git push origin feat/<N>-<slug>`. Then `.adlc/scripts/adlc-relabel.sh N stage:qa`.
8. **QA.** `adlc-qa-release-ops` on the PR with links to the two verdict comments: the reviews
   have run, and QA trusts the recorded verdicts — it does not re-run the reviewers'
   reproductions; its own security gate still runs in full. Its verdict is a comment, not
   `gh pr review`. Clean ⇒ QA moves the issue to `gate:deploy` (`adlc-relabel.sh`) and posts the
   Proposed Action Card. Findings ⇒ step 6; QA runs again only once step 5 has passed again.
9. **Report** to the Principal: the PR, the Action Card, and what stays theirs before the merge
   — run `/security-review` on the branch, accept the ADR (`Proposed → Accepted`), then Gate 2
   as the RUNBOOK has it (the behind-the-base check, the merge, the deploy).

**Fast lane** (issue at `stage:fast`): `adlc-builder` on the change brief (no ADR;
`.adlc/scope/<N>.txt`; `Closes #N`), then label the PR `lane:fast`. Before the checks (an over-cap
PR fails `ADLC diff-scope`), the cap on the REAL diff, taken as `adlc-fast.yml` takes it:

```bash
git fetch origin && base=$(git merge-base refs/remotes/origin/<base> refs/remotes/origin/<branch>) &&
d=$(git -c core.quotePath=false diff --numstat --no-renames --raw --ignore-submodules=none "$base" refs/remotes/origin/<branch>) &&
[ -n "$d" ] && printf '%s\n' "$d" | .adlc/scripts/adlc-triage.sh
```

Nothing printed (the diff could not be taken, or is empty) ⇒ stop; never read that as fast.
`FULL` ⇒ comment the reasons it printed, take `lane:fast` off the PR,
`.adlc/scripts/adlc-relabel.sh N stage:design`, go on from step 3 (the Builder continues on this
branch and PR). `FAST` ⇒ the checks as in step 4, then `adlc-adversarial-reviewer` only (there is
no ADR), its `ADLC-ADV` read as in step 5: `CHANGES` ⇒ step 6, then the cap, the checks and the
review again; `PASS` ⇒ you move the issue with `.adlc/scripts/adlc-relabel.sh N gate:deploy`,
post the Proposed Action Card (format: `adlc:charter`) on the PR, and report (step 9).
