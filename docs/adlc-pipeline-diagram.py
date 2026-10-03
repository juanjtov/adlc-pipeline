#!/usr/bin/env python3
"""ADLC pipeline diagram — generator (icon-first house style; needs the diagram kit at
~/.claude/skills/diagram).

Run:  python3 docs/adlc-pipeline-diagram.py
      -> rewrites docs/adlc-pipeline-diagram.html and prints the artifact-body path
Then: python3 ~/.claude/skills/diagram/render.py docs/adlc-pipeline-diagram.html docs/adlc-pipeline-diagram.png

Draw the as-built truth: re-read agents/, skills/charter, skills/triage, skills/intake and
templates/github/*.yml before changing a flow.
"""
import sys, os
sys.path.insert(0, os.path.expanduser("~/.claude/skills/diagram"))
from diagram_kit import Canvas, GLYPHS

# glyphs this picture needs that the kit lacks
GLYPHS.update({
 "gate":   '<path d="M4 21V6M20 21V6"/><rect x="2" y="9" width="20" height="4.6" rx="1.2"/><path d="M7.6 9l-2.4 4.6M12.6 9l-2.4 4.6M17.6 9l-2.4 4.6"/>',
 "branch": '<circle cx="6" cy="5" r="2.2"/><circle cx="6" cy="19" r="2.2"/><circle cx="18" cy="7" r="2.2"/><path d="M6 7.2v9.6M18 9.2c0 5-6 4.6-11 8.1"/>',
 "gauge":  '<path d="M3.5 17.5a8.5 8.5 0 1 1 17 0"/><path d="M12 17.5l4.6-5.6"/><circle cx="12" cy="17.5" r="1.5" class="g-fill"/><path d="M6.3 11.3l1.3 1M12 8.2v1.7M17.7 11.3l-1.3 1"/>',
})

W, H = 1600, 1170
c = Canvas(W, H, "ADLC Pipeline",
    aria="ADLC pipeline: a GitHub issue goes to the Analyst, then Gate 1 where you approve the plan and pick the full or the fast lane. "
         "The full lane runs Architect, Builder, two reviewers and QA; the fast lane runs Builder, a size check and one reviewer. "
         "Both end at an Action card, and only you merge into main at Gate 2. Agents are blocked from merging or pushing.")
a, text, rect, flow, label, step, icon, node = c.a, c.text, c.rect, c.flow, c.label, c.step, c.icon, c.node

# ---------------------------------------------------------------- header + legend
text(60, 70, "ADLC PIPELINE", "title", size=44, weight=800)
text(60, 100, "How one request becomes a merged change · the adlc plugin for Claude Code, as built", "sub", size=15)
text(60, 122, "Agents move work up to a gate, never through it. A person approves the plan, or opts into autopilot, and always does the merge.", "sub2", size=12)

lx, ly = 1000, 40
text(lx, ly, "HOW TO READ", "eyebrow", size=10, weight=700)
for i, (cls, mk, s) in enumerate([
        ("fl-ind fl-thick", "arrow-ind", "handoff · the issue moves to the next stage"),
        ("fl-slate", "arrow-slate", "your decision · file, approve, pick a lane, merge"),
        ("fl-teal", "arrow-teal", "automation starts or installs something"),
        ("fl-amber", "arrow-amber", "scheduled · the weekly retro"),
        ("fl-grey", "arrow-grey", "watch only · raises an alert, edits nothing"),
        ("fl-red", "arrow-red", "blocked · deny rules and CI stop it")]):
    yy = ly + 17 + i * 17
    c.line(lx, yy, lx + 30, yy, cls, mk); text(lx + 40, yy + 3.5, s, "leg", size=10.5)
lx2 = 1330
icon("api", lx2 + 10, ly + 16, 16, "ic-l"); text(lx2 + 28, ly + 20, "agent · runs as Claude", "leg", size=10.5)
icon("gate", lx2 + 10, ly + 36, 16, "ic-s"); text(lx2 + 28, ly + 40, "you · a person decides", "leg", size=10.5)
icon("clock", lx2 + 10, ly + 56, 16, "ic-a", dashed=True); text(lx2 + 28, ly + 60, "dashed · optional, you switch it on", "leg", size=10.5)
step(lx2 + 10, ly + 76, 1, r=8); text(lx2 + 28, ly + 80, "the reading order, keyed below", "leg", size=10.5)
text(lx2, ly + 100, "hover any icon for the file behind it", "leg-i", size=10)

# ---------------------------------------------------------------- actor band
text(130, 182, "THE HUMAN", "eyebrow", anchor="middle", size=10, weight=700)
node("person", 130, 232, "You", "the Principal", size=52, cls="ic-s", tile="tile-s",
     title="You, the Principal: file requests, approve the plan at Gate 1, pick the lane, merge and deploy at Gate 2. charter skill, section 3.")

# engine cluster: what starts each agent
CX, CY, CW, CH = 290, 168, 850, 134
rect(CX, CY, CW, CH, "cluster", r=16)
icon("hex", 345, 226, 58, "ic-w", title="GitHub Actions running anthropics/claude-code-action: one workflow per lane, fired by label changes. templates/github/")
text(390, 206, "GITHUB ACTIONS", "clu-t", size=15, weight=800)
text(390, 224, "starts each agent when an issue's label changes", "clu-s", size=10)
text(390, 246, "ONE WORKFLOW PER LANE", "clu-e", size=8.5, weight=700)
lanes = [("intake", "adlc-intake.yml: runs the Analyst when a requirement is filed (auto-start, optional)"),
         ("design", "adlc-design.yml: runs the Architect on stage:design"),
         ("build", "adlc-builder.yml: runs the Builder on stage:build"),
         ("review", "adlc-review.yml: adversarial + architect review on every Builder PR; advances to stage:qa on two PASS verdicts"),
         ("fix", "adlc-fix.yml: sends a PR with changes requested back to the Builder; stops after 3 rounds and tags needs:human"),
         ("qa", "adlc-qa.yml: runs QA & Release-Ops on stage:qa"),
         ("fast", "adlc-fast.yml: fast lane: Builder, size cap on the real diff, adversarial + security review"),
         ("ci", "adlc-ci.yml: the project's tests, type-check and build on every PR"),
         ("scope", "adlc-diff-scope.yml: fails a PR that touches files outside its allowed scope"),
         ("tripwire", "adlc-main-tripwire.yml: alerts on any push to main that skipped a PR"),
         ("retro", "adlc-retro.yml: weekly retro, opens a proposal PR (optional)")]
for i, (n, tip) in enumerate(lanes):
    cx = 404 + i * 50
    sched = n == "retro"
    icon("clock" if sched else "bolt", cx, 268, 18, "ic-a" if sched else "ic-w", dashed=sched or n == "intake", title=tip)
    text(cx, 291, n, "clu-y lab-m", anchor="middle", size=8)
a(f'<line x1="955" y1="{CY+18}" x2="955" y2="{CY+CH-18}" stroke="#3A4A78" stroke-width="1"/>')
text(980, 200, "OR BY HAND", "clu-e", size=8.5, weight=700)
icon("terminal", 1000, 242, 38, "ic-w", title="Local recipe: you run each agent yourself in Claude Code, following the generated RUNBOOK.md. The recommended way to start.")
text(1028, 238, "Claude Code", "clu-x", size=12.5, weight=700)
text(1028, 254, "you run each lane", "clu-y", size=9.5)
text(1028, 267, "from the runbook", "clu-y", size=9.5)

# setup wizard
node("toolbox", 1300, 232, "Setup wizard", "/adlc-init · run once", size=44, cls="ic-l", tile="tile-l",
     title="/adlc-init (bootstrap skill): detects a new or existing project, asks a short questionnaire, writes project-conventions, release-ops, charter, RUNBOOK, first ADR, .claude/settings.json deny rules, labels and (optionally) the workflows. Never commits.")
flow("M1266,232 C1220,232 1190,232 1144,232", "fl-teal", "arrow-teal")
label(1205, 214, "installs lanes + rules", "lbl-t", size=9)

# cluster -> pipeline
flow("M715,302 C715,312 715,318 715,330", "fl-teal", "arrow-teal")
label(800, 316, "starts each agent", "lbl-t", size=9)

# ---------------------------------------------------------------- zones
ZY, ZH = 334, 686
PX, PW = 230, 962
MX, MW = 1270, 270
BX = 1231
rect(PX, ZY, PW, ZH, "zone-l", r=18)
icon("people", PX + 40, ZY + 30, 30, "ic-l")
text(PX + 64, ZY + 36, "THE PIPELINE", "zone-title l", size=20, weight=800)
text(PX + 248, ZY + 36, "agents do the work, on branches and pull requests", "zone-sub l", size=14)
text(PX + 24, ZY + 58, "a stage: label means an agent is working · a gate: label means it waits for you", "zone-rule", size=10.5)

rect(MX, ZY, MW, ZH, "zone-n", r=18)
icon("branch", MX + 38, ZY + 30, 30, "ic-n")
text(MX + 62, ZY + 36, "MAIN", "zone-title n", size=20, weight=800)
text(MX + 126, ZY + 36, "code of record", "zone-sub n", size=13)
text(MX + 24, ZY + 58, "reached only through Gate 2", "zone-rule", size=10.5)

a(f'<line x1="{BX}" y1="{ZY-6}" x2="{BX}" y2="{ZY+ZH+6}" class="membrane"/>')
a(f'<text transform="translate({BX-8},{ZY+520}) rotate(-90)" class="membrane-t" text-anchor="middle" style="font-size:9.5px;letter-spacing:.18em;font-weight:700">GATE 2 · ONLY A PERSON MERGES</text>')

# ---------------------------------------------------------------- the request (outside the zones)
node("inbox", 130, 610, "Request", "a GitHub issue", size=50, cls="ic-n", tile="tile-n",
     title="A GitHub issue describing the problem and outcome. Issues are the execution source of truth; labels track the stage. File it with the Requirement issue template.")
node("chat", 130, 430, "Intake", "idea · PRD · ticket", size=44, cls="ic-l", tile="tile-l",
     title="/adlc-intake (intake skill): starts from a rough idea, a PRD-lite, a full PRD (sliced), an existing GitHub issue, a bug, or a Notion / Linear ticket fetched through its connector. It interviews you only for what is missing, shows the exact issue, and files it with stage:intake after you confirm. Already clear? File the Requirement issue form or label your own issue.")
flow("M130,312 C130,340 130,370 130,396", "fl-slate", "arrow-slate")
label(130, 354, "you bring it", "lbl-s", size=9)
flow("M130,500 C130,522 130,548 130,570", "fl-slate", "arrow-slate")
label(130, 534, "filed on your yes", "lbl-s", size=9)
step(98, 578, 1)

# ---------------------------------------------------------------- shared start: Analyst + Gate 1
RY = 610
node("doc", 330, RY, "Analyst", "stories + lane advice", size=50, cls="ic-l", tile="tile-l",
     title="Product Analyst (agents/product-analyst.md): asks numbered questions if the request is unclear; otherwise writes stories with Given/When/Then acceptance criteria (full) or a one-check change brief (fast), and ends with ADLC-TRIAGE: FAST or FULL. Writes only issue comments and labels.")
step(298, 578, 2)
flow("M166,610 C210,610 250,610 292,610", "fl-ind fl-thick", "arrow-ind")
label(214, 592, "stage:intake", "lbl-i", size=9)

node("gate", 470, RY, "Gate 1", "approve, pick lane", size=50, cls="ic-s", tile="tile-s",
     title="Gate 1 (gate:stories): you accept or return the stories, then apply stage:design (full lane) or stage:fast (fast lane). Optional autopilot can approve into the full lane only; the fast lane always waits for a person. You can also put a fresh issue on stage:fast yourself; the Analyst then never runs.")
step(438, 578, 3)
flow("M367,610 C390,610 410,610 432,610", "fl-ind fl-thick", "arrow-ind")
label(400, 634, "gate:stories", "lbl-i", size=9)
# optional autopilot: approves Gate 1 for you, into the full lane only
node("bolt", 420, 476, "Autopilot", "optional · full lane only", size=26, cls="ic-l", tile=None, dashed=True, label_size=11,
     title="adlc:autopilot label on an issue: adlc-intake.yml approves Gate 1 for you when the Analyst's verdict is FULL. A FAST verdict still waits for you. Gate 2 is never automated.")
a('<path d="M420,524 C420,552 472,546 478,572" class="fl-teal" style="stroke-dasharray:5 4" marker-end="url(#arrow-teal)"/>')
label(447, 547, "can approve", "lbl-t", size=9)

# ---------------------------------------------------------------- full lane (row A)
AY = 490
text(566, 428, "FULL LANE · NEW BEHAVIOR", "eyebrow", size=9.5, weight=700)
node("layers", 620, AY, "Architect", "design + files", size=50, cls="ic-l", tile="tile-l",
     title="Architect (agents/architect.md): writes docs/adr/NNNN-*.md and a task breakdown where every task declares the exact files it may touch (its diff scope), plus a blast-radius check. Writes only under docs/.")
step(586, 458, 4)
node("api", 770, AY, "Builder", "code + tests, a PR", size=50, cls="ic-l", tile="tile-l",
     title="Builder (agents/builder.md): implements on feat/<issue>-<slug>, a test per acceptance criterion (SN-ACN ids), runs the project's pass/fail command, opens a PR. Never merges, never pushes to main.")
step(736, 458, 5)
node("eye", 920, AY, "Two reviewers", "break it · match design", size=50, cls="ic-l", tile="tile-l",
     title="Adversarial Reviewer (agents/adversarial-reviewer.md): fresh context, sees only the diff, tries to break it, ends with ADLC-ADV: PASS or CHANGES. Then the Architect checks the PR against the design: ADLC-ARCH: PASS or CHANGES.")
step(886, 458, 6)
node("check", 1070, AY, "QA", "tests + security", size=50, cls="ic-l", tile="tile-l",
     title="QA & Release-Ops (agents/qa-release-ops.md): runs the full battery, writes missing tests (test folders only), runs the security gate, then adds gate:deploy and posts a Proposed Action Card. Never merges or deploys.")
step(1036, 458, 7)

# Gate 1 -> lanes (your decision)
flow("M505,602 C560,595 548,490 582,490", "fl-slate", "arrow-slate")
label(546, 559, "full lane", "lbl-s", size=9)
flow("M505,618 C560,625 548,730 582,730", "fl-slate", "arrow-slate")
label(551, 677, "fast lane", "lbl-s", size=9)

flow("M656,490 C685,490 705,490 732,490", "fl-ind fl-thick", "arrow-ind")
label(694, 512, "ADR + tasks", "lbl-i", size=9)
flow("M806,490 C835,490 855,490 882,490", "fl-ind fl-thick", "arrow-ind")
label(844, 512, "opens a PR", "lbl-i", size=9)
flow("M956,490 C985,490 1005,490 1032,490", "fl-ind fl-thick", "arrow-ind")
label(994, 512, "both pass", "lbl-i", size=9)
# fix loop
flow("M920,454 C920,404 770,404 770,452", "fl-ind", "arrow-ind")
label(845, 412, "changes · fix, review again", "lbl-i", size=9)

# ---------------------------------------------------------------- fast lane (row B)
BY = 730
text(600, 676, "FAST LANE · SMALL FIXES", "eyebrow", size=9.5, weight=700)
node("api", 620, BY, "Builder", "small change + test", size=50, cls="ic-l", tile="tile-l",
     title="Builder on the fast lane (adlc-fast.yml): works from the change brief, no ADR; writes the scope to .adlc/scope.txt, adds a test for S1-AC1, opens a PR labelled lane:fast.")
node("gauge", 790, BY, "Size check", "small, nothing sensitive", size=50, cls="ic-l2", tile="plate",
     title="adlc-triage.sh re-checks the real diff: default max 5 files and 40 changed lines, and no migrations, auth, infra, CI, .github/.claude, dependency manifests or secrets. Over the cap, the change goes to the full lane.")
node("eye", 960, BY, "Reviewer", "break it + security", size=50, cls="ic-l", tile="tile-l",
     title="Adversarial Reviewer on the fast lane: diff + change brief only, walks every security-gate attack class, ends with ADLC-ADV: PASS or CHANGES.")
flow("M656,730 C690,730 720,730 752,730", "fl-ind", "arrow-ind")
label(705, 752, "opens a PR", "lbl-i", size=9)
flow("M826,730 C860,730 890,730 922,730", "fl-ind", "arrow-ind")
label(875, 752, "under the cap", "lbl-i", size=9)
# fix loop, fast lane
flow("M960,806 C960,848 620,848 620,812", "fl-ind", "arrow-ind")
label(790, 838, "changes · fix again", "lbl-i", size=9)
# bounce to the full lane
flow("M790,694 C790,612 700,582 652,518", "fl-ind", "arrow-ind")
label(739, 600, "too big → full lane", "lbl-i", size=9)
# blocked: no agent or autopilot chooses the fast lane
flow("M330,690 C330,760 470,782 560,766", "fl-red", "arrow-red")
c.nogo(411, 760)
label(411, 790, "no agent or autopilot picks it", "lbl-r", size=9)

# ---------------------------------------------------------------- both lanes end at the Action card
node("contract", 1135, RY, "Action card", "risk, proof, undo", size=50, cls="ic-l", tile="tile-l",
     title="Proposed Action Card (charter skill): action, risk, evidence, migrations none/additive/DESTRUCTIVE, rollback step. Posted with gate:deploy; awaits your approval.")
flow("M1106,490 C1135,490 1135,530 1135,572", "fl-ind fl-thick", "arrow-ind")
label(1135, 532, "all green", "lbl-i", size=9)
flow("M996,730 C1060,730 1070,610 1097,610", "fl-ind", "arrow-ind")
label(1041, 704, "pass · skips QA", "lbl-i", size=9)

# ---------------------------------------------------------------- crossing the membrane
node("branch", 1340, RY, "main", "merged code", size=50, cls="ic-n", tile="tile-n",
     title="The main branch. Agents cannot merge or push here: gh pr merge and pushes to main are deny-listed in .claude/settings.json; public repos add branch protection.")
flow("M1171,610 C1210,610 1260,610 1302,610", "fl-slate fl-thick", "arrow-slate")
label(1231, 590, "Gate 2 · you merge", "lbl-s", size=9.5)
step(1231, 632, 8)
node("cloud", 1470, RY, "Deploy", "you, after merging", size=46, cls="ic-s", tile="tile-s",
     title="Deploy and any database migration run only after Gate 2, by you. Destructive migrations are a hard stop for every agent.")
flow("M1376,610 C1396,610 1414,610 1434,610", "fl-slate", "arrow-slate")
# blocked: agents merging or pushing
flow("M1070,454 C1070,436 1086,428 1110,428 C1200,428 1300,428 1318,428 C1336,428 1340,444 1340,572", "fl-red", "arrow-red")
c.nogo(BX, 428)
label(1118, 428, "agents can't merge or push", "lbl-r", size=9)
# tripwire
node("flag", 1405, 800, "Tripwire", "alerts on a direct push", size=36, cls="ic-l2", tile="plate",
     title="adlc-main-tripwire.yml + adlc-tripwire-check.sh: on every push to main, fails and files a bug if a commit arrived without a merged PR. The free-plan stand-in for branch protection on private repos.")
flow("M1362,640 C1385,680 1405,720 1405,772", "fl-grey", "arrow-grey")
label(1392, 704, "watches pushes", "lbl-g", size=9)

# ---------------------------------------------------------------- safety nets + learning loop (bottom of the pipeline zone)
SY = 870
rect(250, SY, 560, 128, "legacy-strip", r=12)
text(266, SY + 20, "SAFETY NETS · PLAIN SCRIPTS, UNIT-TESTED, SAME IN CI AND ON YOUR MACHINE", "eyebrow", size=9, weight=700)
nets = [("lock", "Deny rules", "no merge, no push", "templates/settings.deny.json: gh pr merge, pushes to main and force-pushes are denied for every agent."),
        ("folder", "Scope check", "allowed files only", "adlc-diff-scope.sh: design PRs may touch docs/ only, QA PRs test folders only, build PRs the declared scope."),
        ("json", "Verdict reader", "reads PASS/CHANGES", "adlc-verdict.sh: parses the reviewers' ADLC-ADV / ADLC-ARCH lines; control never trusts GitHub review state."),
        ("sync", "Fix cap", "then a person", "adlc-fix-cap.sh: counts adlc-fix: commits; after 3 rounds the PR is tagged needs:human."),
        ("terminal", "Pre-commit", "same check, locally", "templates/hooks/pre-commit: runs the scope check before each local commit."),
        ("gear", "Doctor", "checks the setup", "adlc-doctor.sh: fails a setup with missing deny rules, unfilled placeholders, missing skills or labels.")]
for i, (g, t, s, tip) in enumerate(nets):
    cx = 302 + i * 92
    icon(g, cx, SY + 56, 28, "ic-l2", title=tip)
    text(cx, SY + 90, t, "lab", anchor="middle", size=10.5, weight=700)
    text(cx, SY + 103, s, "lab-s", anchor="middle", size=8.5)

rect(830, SY, 342, 128, "legacy-strip", r=12)
text(846, SY + 20, "LEARNING LOOP · OPTIONAL", "eyebrow", size=9, weight=700)
loop = [(880, "doc", "Findings", "logged by every review", "Every review and QA finding is written as an ADLC-FINDING line in the PR comment; adlc-log-findings.sh builds .adlc/metrics/findings.jsonl from them."),
        (1000, "clock", "Retro", "weekly, or /adlc:retro", "retro skill + adlc-retro.yml (Mondays by default): ranks recurring mistakes."),
        (1120, "docout", "Fix PR", "tests first, then checks", "A propose-only PR: a regression test first, then a CI check, then a convention. It goes through both gates like any change.")]
for x, g, t, s, tip in loop:
    icon(g, x, SY + 56, 30, "ic-a", dashed=True, tile="tile-a", title=tip)
    text(x, SY + 92, t, "lab", anchor="middle", size=10.5, weight=700)
    text(x, SY + 105, s, "lab-s", anchor="middle", size=8.5)
flow(f"M904,{SY+56} C924,{SY+56} 950,{SY+56} 974,{SY+56}", "fl-amber", "arrow-amber")
flow(f"M1026,{SY+56} C1046,{SY+56} 1070,{SY+56} 1094,{SY+56}", "fl-amber", "arrow-amber")

# ---------------------------------------------------------------- reading order
FY = 1064
c.line(60, FY - 22, W - 60, FY - 22, "col-rule")
text(60, FY, "THE READING ORDER", "eyebrow", size=10, weight=700)
items = [(1, "inbox", "Request", "Bring an idea, a PRD or a ticket. /adlc-intake turns it into one clear GitHub issue."),
         (2, "doc", "Analyst", "Writes stories with pass/fail checks and recommends a lane."),
         (3, "gate", "Gate 1", "You approve the plan and pick the lane. Optional autopilot can approve the full lane."),
         (4, "layers", "Architect", "Writes the design record and the files each task may touch."),
         (5, "api", "Builder", "Writes code plus a test per check on a branch, then opens a PR."),
         (6, "eye", "Two reviewers", "One tries to break it, one checks the design. Changes loop back."),
         (7, "check", "QA", "Runs every test and a security pass, then drafts the Action card."),
         (8, "person", "Gate 2", "You read the card, then merge and deploy. No agent can.")]
cw = (W - 120) / len(items)
for i, (n, g, t, s) in enumerate(items):
    x = 60 + i * cw
    step(x + 11, FY + 24, n); icon(g, x + 38, FY + 24, 20, "ic-s")
    text(x + 56, FY + 28, t, "loop-t", size=12.5, weight=800)
    words, ls, cur = s.split(), [], ""
    for wd in words:
        if len(cur) + len(wd) + 1 > 31: ls.append(cur); cur = wd
        else: cur = (cur + " " + wd).strip()
    ls.append(cur)
    c.lines(x, FY + 50, ls, "loop-s", size=10, lh=13)

import shutil, tempfile
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(tempfile.gettempdir(), "adlc-pipeline-diagram")
body, standalone = c.write(os.path.join(out, "adlc-pipeline.html"),
        caption="Drawn from the plugin as built: agents/, skills/charter, skills/triage, skills/intake, templates/github/*.yml and templates/scripts/. "
                "The fast-lane size cap and the fix-loop limit are defaults a project can change; hover the icons for the values and files. "
                "Without GitHub Actions, you start each lane by hand in Claude Code and the gates are the same.")

# page contract: dark blocks also switch native scrollbars to dark
for f in (body, standalone):
    t = open(f).read()
    t = t.replace(':root:not([data-theme="light"]){ ', ':root:not([data-theme="light"]){ color-scheme:dark; ', 1)
    t = t.replace(':root[data-theme="dark"]{ ', ':root[data-theme="dark"]{ color-scheme:dark; ', 1)
    open(f, "w").write(t)
shutil.copyfile(standalone, os.path.join(here, "adlc-pipeline-diagram.html"))
print("wrote", os.path.join(here, "adlc-pipeline-diagram.html"))
print("artifact body:", body)
