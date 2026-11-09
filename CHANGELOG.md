# Changelog

Newest first. Each release says whether a **tooling refresh** is needed. A refresh means
running `/adlc-init` again in your repo: it re-copies the workflows, `.adlc/scripts/*.sh`,
the local hook and the project agents (`.claude/agents/adlc-<role>.md`) from the plugin,
because those are frozen copies that only change on a refresh. Your repo's `.adlc/VERSION`
says which release its copies came from, and `.adlc/scripts/adlc-doctor.sh` tells you when
it differs from the installed plugin.

## Unreleased (on `main` after 0.3.1)

Tooling refresh needed: **yes** — `adlc-relabel.sh` is new and the lanes call it; the
`adlc-log-findings.sh` copy gains the backtick-wrapped marker, the per-comment time, the
skipped-line report and the closed class list below, the `adlc-cycle.sh` copy the verdict-based
round count and the next-label end of a stage interval, the `adlc-doctor.sh` copy the Actions
check, and the `adlc-metrics.sh` copy the `infra_failed` line; `adlc-adr-check.sh` is new,
`docs/adr/template.md` gains `## Scope` and `## Guarantees` (the wizard shows the difference and
asks before it replaces yours), the RUNBOOK's Stage 4 names the check, and the wizard merges the
new `settings.cache.json` into `.claude/settings.json`. From issue 34: `adlc-ci-budget.sh` and
`adlc-local-ci.sh` are new; the `adlc-cycle.sh` copy gains the `blocked=` figure, the
`adlc-metrics.sh` copy the `blocked` and `local_ci` lines, the `adlc-run-log.sh` copy the
`outcome` field, the `adlc-doctor.sh` copy a pointer to the local CI script, and the RUNBOOK
template the local CI recipe. From issues 39 and 21: `adlc-tripwire-alert.sh` is new and the
refreshed `adlc-main-tripwire.yml` calls it (with the `adlc-tripwire-check.sh` copy's new `range`
mode); the `adlc-doctor.sh` copy gains the two new labels and the host-owned line, the
`adlc-metrics.sh` copy the `change_failures` count, and the RUNBOOK template the scope-file
section. Re-run `templates/github/labels.sh` as well: it creates `adlc:change-failure` and
`adlc:tripwire`. The refresh itself now runs through `adlc-refresh.sh`, from the plugin. The
security-gate, code-review and efficient-runs skills, the retro and cycle-retro recipes, the role
prompts and the guard hook live in the plugin, which every session loads from the installed
plugin, so those parts need no refresh.

- **A refresh no longer overwrites what a host changed; the tripwire alerts on a force-push
  and files an alert once** (issue 39). The refresh copied `templates/scripts/*.sh` over the
  host's copies with no comparison and no way to keep a file: one host held its upgrade back
  because the refresh "would offer to undo" its local fixes. New `adlc-refresh.sh [--apply]
  <host-root>`, which the wizard runs from the plugin: one line per file (`same`, `new`,
  `changed` with a unified diff, `host-owned (skipped)`), nothing written without `--apply`,
  and with it only the new and changed files are copied, never one whose first five lines
  contain `adlc: host-owned`; the output ends with what it skipped. A host with local changes
  marks those files before it applies a refresh (the dry run's diffs show which they are). Workflows, agent copies and
  the pre-commit hook are filled before they are copied, so the wizard fills a scratch file and
  hands it to the same script (`<host-root> <filled-file> <target>`, a fixed list of targets, a
  leftover `{{PLACEHOLDER}}` refused): the comparison and the marker are the script's, the
  filling is still the wizard's. The doctor lists host-owned copies on one line (it never
  compared a copy with the plugin's, so differing was not a defect there). The tripwire: a force-push to the branch
  (`github.event.forced`) now fails the run and files an alert, without walking a
  `BEFORE..AFTER` range that a rewrite may leave invalid; the alert moves into
  `adlc-tripwire-alert.sh`, which ends the body with `ADLC-TRIPWIRE: direct <sorted ids>` (or
  `forced <before> <after>`) and files nothing while an open `adlc:tripwire` issue carries the
  same line (one host got the same four commits twice, a minute apart). A failed listing files
  anyway; a repo without the label gets the alert unlabelled. The RUNBOOK template now says what
  becomes of `.adlc/scope/<n>.txt`: they stay as the record; after the merge
  `adlc-adr-check.sh` still compares one with the Scope of each ADR naming its issue, and a
  later PR tied to the same issue is held to it; pruning is the Principal's, outside the lanes
  (the diff-scope check refuses a lane PR that touches another issue's scope file), and turns
  that ADR comparison off.
  Not done: the script does not fill placeholders itself, `.adlc/VERSION` is restamped also when
  files were skipped, an alert closed and then re-triggered is filed again, two tripwire runs
  that list the open alerts at the same moment can still both file, and a force-push's commits
  are not checked one by one. The duplicate check trusts the line wherever it is: an open
  alert issue whose body already holds the exact key line holds back a new alert for that set
  of commits (the run still fails).

- **`bug` means any defect; the change-failure metric counts `adlc:change-failure`** (issue
  21). Four parts used `bug` and meant different things: `labels.sh` described it as an
  Ops-filed defect, `adlc-metrics.sh` counted it as the change-failure signal, intake adds it to
  every bug a person reports, and the tripwire filed its alerts with it, so reported bugs and
  tripwire alerts raised the change-failure number. Now `bug` is any defect, however reported;
  the new label `adlc:change-failure` marks a defect Ops traced to a deploy (the QA/Ops prompt
  and the `release-ops` template file such a defect with both), and `adlc-metrics.sh` counts
  issues that carry it, printed as `change_failures` (was `bugs_filed`). The tripwire files
  under the new `adlc:tripwire` label: a direct push is a process breach, not a defect.
  `labels.sh` creates both, and the doctor reports a repo that lacks `adlc:change-failure`, or
  `adlc:tripwire` where the tripwire is installed. **For a host:**
  re-run `labels.sh`; `bug` issues Ops filed before this change are no longer counted unless
  you add `adlc:change-failure` to them; until the label exists the metric prints
  `change_failures: 0` with a note saying why; a `release-ops` skill generated earlier keeps its
  old sentence until you edit it (the role prompt, loaded from the plugin, already has the new
  one). One `gh label list` call more per metrics run.

- **Actions minutes are sized before the battery is copied, a blocked run is not a failed
  one, and local CI leaves one marker** (issue 34, the rest of it). The bootstrap offered
  Actions on a private repo with one sentence about minutes: on one host a battery of 17 to 23
  job-minutes ran 4.6 times per merged PR, used about 8,000 minutes in a month against 2,000,
  and when the account was blocked the host ran the battery by hand and posted free-form
  "Local CI on head X" comments, while the cycle report's `failed=97/222` could not tell the
  dead runs from the real failures. Three changes. (1) New `adlc-ci-budget.sh <minutes/run> <runs/PR>
  <PRs/month> [included]` prints the monthly estimate and `FITS` or `OVER` (exit 0 / 1; decimals
  allowed in the first two); the wizard runs it for a private repo that will run CI on Actions
  and, on `OVER`, proposes `paths` filters, then the heavy jobs only at `stage:qa` or on a
  label, then CI off Actions. It is an estimate of the CI battery alone: the agent lanes'
  minutes come on top, and the CI template has no ready-made switch for the second proposal.
  (2) New `adlc-local-ci.sh <pr> [--dry-run] [commands-file]` runs the host's own list
  (`.adlc/local-ci.txt`, one `<name>: <command>` per line) from the repo root, refuses unless
  the tree is clean and HEAD is the PR's head commit, and posts one PR comment whose last line
  is `ADLC-CI: PASS head <sha>` or `ADLC-CI: FAIL head <sha>`. QA's prompt counts it as the
  battery result only for the PR's current head, `adlc-metrics.sh` counts each such comment on
  a merged PR as one CI run (from the comments it already fetched; a `local_ci:` line says how
  many), and the doctor's blocked note names the script. The marker is a record, not a gate:
  anyone who can comment can write it, and nothing checks that the battery ran. No per-command
  timeout. (3) A run that concluded `failure` within 60 s of its creation with no step run (the
  doctor's rule, per run) is `blocked`: `adlc-run-log.sh actions` rows carry `outcome`
  (GitHub's `conclusion` stays beside it), `adlc-cycle.sh report` prints `blocked=` beside
  `failed=` and leaves those runs out of `failed=` and `avg_sec`, and `adlc-metrics.sh` leaves
  them out of `iterations_to_green` / `failed_first` and prints a `blocked:` line when there is
  one. One `gh run view` call per run that failed within 60 s in the run ledger; none added in
  `adlc-metrics.sh`, which already looked up each red run. A run that cannot be read stays a
  failure. Any other reason GitHub fails a run before its first step reads as `blocked` too.

- **The wizard sets the prompt-cache lifetime to 1 hour** (issue 57). On one host 321 of 8,491
  pipeline calls in 30 days came more than 5 minutes after the previous call of the same run,
  93% of them behind a blocking wait on a test suite, a lock or a CI run; they read 7% of their
  prompt from cache against 97.7% for calls under 2 minutes apart, and were 38% of the spend.
  New `templates/settings.cache.json` holds `promptCacheTtl` and `subagentPromptCacheTtl`, both
  `"1h"`, and the wizard merges the two keys into `.claude/settings.json` with the deny rules,
  keeping a value already there and saying in one line what they do; removing them undoes it.
  The trade-off is in the file: a 1-hour cache write is billed at a higher rate than a 5-minute
  one (2× base input against 1.25× when the issue was written), so a repo whose runs never
  wait longer than 5 minutes pays more with the keys than without. `efficient-runs` gains one
  rule: a blocking call that outlasts the cache lifetime re-prices the next turn at full input,
  so wait in the background or keep each wait under it. Not checked: that every Claude Code
  version reads the two keys from a project's settings file (the issue reports 2.1.318 or
  newer), and what the Actions lanes do with them. The doctor does not look for the keys: a
  repo that took them out on purpose would be told about it on every run.

- **An ADR states its scope and what pins each guarantee, and `adlc-adr-check.sh` holds it to
  both** (issue 55). The template had Context / Decision / Alternatives / Consequences only, so
  a Decision could promise more than the tests deliver and nothing failed when the promise
  rotted: one host logged an ADR claim stronger than the guard it described, stale text and a
  wrong citation in two ADRs, and an ADR amended with no conformance check, in ten days. The
  template gains `**Issue:** #N` in its header, `## Scope` (a fenced block of path prefixes,
  the lines of `.adlc/scope/<issue>.txt`) and `## Guarantees` (a table: claim → the
  `path::node` of the test that pins it, or `unenforced — <reason>`). New
  `adlc-adr-check.sh [adr-dir]` reports every problem, one line each, and exits 1: a missing
  section, a Scope with no block, a row that is neither form, a path that does not exist, a
  node that is not in that file as a whole word, an `unenforced` with no reason, and, where
  the ADR names its issue and the scope file exists, any difference between the two (`docs/`
  lines of the scope file aside: the design lane puts the files it commits there). An ADR
  with neither section is skipped and listed, so ADRs written before this template keep
  passing with no cut-off to maintain; the cost is that a new ADR with both left out is
  skipped too, which the Architect's review is told to treat as a finding. The Builder runs
  the script before opening the PR, the Architect in its conformance review, and QA with the
  battery; in the Actions review lane the Architect has no grant for it and reads the two
  sections instead. Not done: no workflow runs it (`adlc-diff-scope.yml` never checks out the
  PR head, and `adlc-ci.yml` has no guards job), the design lane does not write the scope file
  from the ADR's Scope, and the node check is a word search, not a test collector.

- **A security-gate attack class for text classifiers over LLM output** (issue 54). On one
  host a chat agent gated writes on regex and word-list predicates over model text; five PRs in
  ten days each wrote a fresh detector, and each fell to input shapes an earlier review had
  already found, about 28 findings in all. `security-gate` gains §7: when a diff adds or
  changes a regex or word list whose input is model text and whose result gates a write, a
  retry or a user-visible claim, probe it in each of the project's languages with an emoji or
  check mark as status, em-dash and comma joins, a claim in a parenthetical, a claim and a
  question in one sentence, an idiom with no verb, negation, markup and curly quotes, and a
  positive control it must reject, and run it against the project's shared phrasing corpus if
  one exists. `code-review` points at that list rather than repeating it. Findings use the
  closed class list (`missing-edge-case`, `logic-contradiction`); there is no new class.

- **One state per issue: `adlc-relabel.sh`, and the cycle clock ends a stage at the next
  label** (issue 38, the rest of it; PR 46 added the doctor check). Every lane and role prompt
  spelled out its own label pair, and the pairs drifted: QA's said "add `gate:deploy`" and
  nothing took `stage:qa` off, so on one host 25 issues ended wearing `stage:qa` + `gate:deploy`
  and six more `stage:fast` + `gate:deploy`, two states each for the cycle clock, Mission
  Control's station view and any lane keyed on the older label. New `adlc-relabel.sh <issue>
  <stage:…|gate:…>` reads the issue's labels and, in one `gh issue edit`, removes every other
  `stage:`/`gate:` label and adds the new one; the intake, design, review and fast lanes, the
  RUNBOOK's fast lane and QA step, and the Analyst, Architect and QA prompts (role skills and
  lane prompts alike) call it instead of a pair, and the doctor's fix line names it. The guard hook judges the script as the `gh issue edit` it is,
  so the adversarial reviewer, which may not move labels, may not run it either. `adlc-cycle.sh`
  now ends a label's dwell when the next `stage:`/`gate:` label is put on, not only when the old
  one is removed, so an issue left with two labels no longer reads as a stage that ran to its
  close; a label superseded that way is the state again from the moment the newer one is taken
  off (a Gate 2 rejection), and a close is never counted past the issue's close.

- **The doctor and Mission Control say when GitHub has stopped running the workflows** (issue
  34, the detection half). When a private repo's included Actions minutes or its spending limit
  run out, GitHub still creates a run for every trigger and fails it
  within seconds with no step executed, for every workflow at once, the tripwire that watches
  the default branch included; the checks on a PR just read red. One host ran that way for
  three days (about 180 dead runs, eight PRs merged with every check red) before anyone looked.
  `adlc-doctor.sh` (gh-backed section, repos with adlc workflows only) reads the last ten
  completed runs, skipped and cancelled ones left out (a lane whose job-level `if:` did not
  match concludes `skipped` before a runner is asked for, so it says nothing either way): when
  at least three remain, all failed within 60 s of being created, and the latest ran no step,
  it reports Actions as blocked and says the tripwire is not watching; steps that ran mean a
  failing workflow, not a block, and a run it cannot read is reported as possibly blocked.
  Actions turned off for the repo creates no run at all, so neither reader sees that. Mission Control reads the same signal over REST about every two minutes
  while a page is open and shows a banner. Not in this change, still on the issue: the
  bootstrap's minutes sizing step, a local-CI marker recipe, and a `blocked` run outcome in
  `adlc-run-log.sh`.

- **The finding class is a closed list** (issue 28). Reviewers named classes freely, so the
  retro, which ranks by class × frequency, saw one failure under five names as five small
  classes: on one host 144 findings carried 53 class names (78 four days later), 30 of them
  used once, and the ADR/code drift pattern was visible only after merging names by hand. The
  `edd-spec` skill now holds a table of thirteen classes with a one-line meaning each
  (`test-gap` and `doc-drift` are new; `other` only with a note), and the review skills name
  the list where the reviewer writes the marker. `adlc-log-findings.sh` lower-cases the class,
  turns `_` and spaces into `-`, writes a known synonym as its canonical name (`logic-bug` →
  `logic-contradiction`, `test-coverage` → `test-gap`, `spec-drift` → `contract-violation`,
  `docs` → `doc-drift`, …), and reports once per run on stderr a name outside the list, which
  it logs as written rather than forcing it to `other`. `adlc-log-findings.sh classes` prints
  the list; the retro's Step 1 ranks on the canonical class and lists the names outside the
  list apart. Rows already in a ledger are not rewritten: rebuild the ledger (the recipe does).

- **`adlc-metrics.sh` sets CI runs that died in a setup step apart from red test runs**
  (issue 56). `iterations_to_green` and `failed_first` counted every failed run of a merged
  PR's branch; on one host five of eighteen first-run reds had died creating an ephemeral
  database, before any test ran, and the retro read a provisioning problem as a test-quality
  one. For each red run on a merged PR's branch the script now asks `gh run view --json jobs`
  for the first failed step across the run's failed jobs (a fail-fast matrix lists cancelled
  legs too; they have no failed step and are passed over); a step whose name matches
  `ADLC_SETUP_STEPS` (a case-insensitive regex; the default is a heuristic on step names,
  anchored at the start where a word is common in test steps too: the runner's own "Set up
  job", checkout, installs, setup actions, caches, registry logins, provisioning, and an
  ephemeral database or branch anywhere in the name) makes the run `infra_failed`, which leaves
  the iterations count and does not make its PR `failed_first`. A host whose test step starts
  with one of those words sets its own regex. A new `infra_failed: N / M` line reports them against every CI run of those
  PRs, so the cycle-retro sees the provisioning reds and the retro the test reds. A run whose
  jobs cannot be read, or none of whose failed jobs names a failed step, stays a plain failure. Green
  runs are never looked up; one call more per red run.

- **The cycle ledger counts fix rounds from CHANGES review verdicts too** (issue 58).
  `adlc-cycle.sh` counted a round as an `adlc:changes-requested` label event on the issue's PR.
  Only the Actions review lane applies that label; a repo that runs the pipeline by hand, with
  subagents from a Principal's session, never does, and on such a host `cycle.jsonl` read 0
  rounds for all 55 issues of a month while 7 of its 35 merged PRs drew a CHANGES verdict. A
  PR's rounds are now the larger of its label events and its `ADLC-ADV: CHANGES` /
  `ADLC-ARCH: CHANGES` verdict comments counted per marker (a comment's last marker is its
  verdict, as `adlc-metrics.sh` reads it); the larger, not the sum, because the lane puts the
  label on the same verdict. The cycle-retro skill calls the figure an estimate that usually
  reads low: a round closed as PASS-with-findings leaves no marker, and two rounds asked for by
  different reviewers read as one. One `gh pr view` call more per linked PR.

- **The finding ledger no longer drops a third of the findings** (issue 27). Measured on a host
  with 144 markers in its PR threads, the materialized ledger held 94. Three causes, all fixed:
  `adlc-log-findings.sh` skipped a marker wrapped in code markup
  (`` `ADLC-FINDING: Medium | tenant-leak | app/tenancy.py` ``), 20 findings on that host; the
  retro's recipe read `gh pr view --json comments` only, so findings posted as a GitHub review
  body never reached the ledger, 29 more; and every row carried the time of the rebuild, so a
  `since` window could not be applied to the ledger. The script now takes the marker after code
  markup too (prose after the closing backtick stays out of the file field), takes the comment's
  own time as an optional third argument, and reports on stderr every line it still could not
  read that carries `ADLC-FINDING:` and three `|`-separated fields, so a marker placed where the
  script does not look is a visible skip. The recipe in the `retro` skill reads comments and review bodies, stamps each
  row with its comment's time, and lists 500 PRs instead of 50: on a repo past 50 PRs the older
  ones fell off the end without a word (349 markers, 220 read, on the same host).

- **One Mission Control shows every adopted repo on the machine, and says so** (issue 52).
  It always could: the hook sends each event with its working directory, the server maps that
  to a repo, and the page's repo menu switches between them. But a repo reached the menu only
  once a pipeline agent had run in it, and a second `adlc-mission-control` in another repo
  answered "already running, stop it first", with `--open` landing on the first repo's line.
  Now the hook script also forwards a session starting; when the session's folder is an
  adopted repo (the guard's own rule: `.adlc/scripts/`, `.adlc/VERSION` or
  `docs/adlc/CHARTER.md` at or above it) the server puts that repo on the menu, and keeps
  nothing from any other session, not even its path. The checkout the session is in must hold
  the marker itself (a clone sitting inside an adopted repo's folder does not count), and only
  a session that starts while Mission Control is running is seen. A second start prints the running copy's
  address on the repo it was run from (`?repo=owner/name`) and `--open` opens that; a repo the
  copy has not heard of is named, not linked, since the page would show another repo's line.
  The documented way to run a copy per repo (`ADLC_MC_HOME` and `--port` for each) stays, with
  its limit now written down: a repo's runs land in the per-repo copy only from sessions that
  have that `ADLC_MC_HOME` set; the rest go to the default folder's copy. `--demo` still
  writes nothing; the guard and the server's Host and Origin checks are untouched.

## 0.3.1

Covers everything on `main` after the v0.3.0 tag (`a8ddd97`) up to and including this release
commit, cut on 2026-10-21: pull request 42 (the 0.3.0 marketplace pin) and pull requests 43
to 49, the last of them merged as `c1a9683` on 2026-10-21. The reason to ship it now is the
guard fix below: on a machine that had opened Mission Control, 0.3.0's guard blocks merges and
pushes to `main` in every repository under the home directory.

Tooling refresh needed: **yes** — the RUNBOOK copy gains the Gate 2 check below, the
`adlc-doctor.sh` copy the double-label check, the fast-lane workflow's Action Card a `Base:`
line, and `.adlc/LICENSE` arrives (the MIT notice for the copies). Until then the copies keep
working as they did. The guard fix below needs no refresh of its own: it ships in the
plugin's hook, which every session loads from the installed plugin, not from a copy in your repo.

- **The guard hook no longer treats every repo under your home directory as adopted.** It
  decided scope by looking for any `.adlc/` directory at or above the project, and Mission
  Control keeps its state in `~/.adlc/mission-control`: on a machine that had opened Mission
  Control once, the guard blocked merges and pushes to `main` in every repository under the
  home directory, adopted or not. It now looks for a marker only `/adlc-init` writes —
  `.adlc/scripts/`, `.adlc/VERSION` or `docs/adlc/CHARTER.md` — still at or above the project,
  so a session started in a subdirectory of an adopted repo stays guarded, and the Actions
  lanes stay always in scope. A repo set up by hand with a bare `.adlc/` folder and no charter
  is no longer in scope; the wizard has written the charter since the first release. A repo
  that was guarded only through an `.adlc/` directory above it needs one of the three markers,
  or the deny rules from `templates/settings.deny.json` in its `.claude/settings.json`, to stay
  guarded; this plugin's own checkout, which has no marker, now carries those deny rules.
- **Gate 2 checks the PR is not behind its base before the merge** (issue 40). Two PRs that
  were each green on their own head made `main` red once both were in: the second was
  behind, and a private Free-plan repo cannot require branches to be up to date. The
  RUNBOOK's Gate 2 now asks the compare API how many base commits the PR lacks
  (`gh api "repos/{owner}/{repo}/compare/<base>...<head>" --jq .behind_by`) first; on
  anything but 0 the base is merged into the PR branch and the checks must go green on the
  new head before the merge. (`mergeStateStatus` is not read: it says `BEHIND` only where the
  up-to-date rule is on.) The Action Card format (`release-ops` skill, and the fast lane's
  card) gains a `Base:` line naming the base-branch commit the QA battery ran against, so the
  gap is visible when the base has moved. The RUNBOOK's fast lane now moves the issue
  from `stage:fast` to `gate:deploy` in one `gh issue edit`, as the fast-lane workflow does.
- **The doctor lists open issues and PRs carrying two state-machine labels** (issue 38). In
  its gh-backed section, `adlc-doctor.sh` now flags every open issue or PR with more than one
  `stage:`/`gate:` label, prints each with its labels, and says how to fix it (keep the label
  it reached last; `gh issue edit <n> --remove-label <label>`, `gh pr edit` for a PR). A
  listing that fails is reported as incomplete, not read as clean. Note: under the current
  QA role an approved issue carries `stage:qa` + `gate:deploy` until it closes, so the doctor
  reports it while the PR waits at Gate 2 — the relabel script proposed in issue 38 is what
  removes that pair at the source.
- **Licensed.** Everything outside `templates/` is under the AGPL v3 (`LICENSE-AGPL`);
  everything under `templates/` — the files `/adlc-init` copies into a repo — is under the MIT
  license (`LICENSE-MIT`). `/adlc-init` now copies that notice to `.adlc/LICENSE` beside the
  scripts, so the copies carry it as MIT requires. The README's Licensing section draws the
  line, and `plugin.json` declares `AGPL-3.0-only AND MIT`.
- **Docs.** The README's new "What leaves your machine" section says what Claude Code, `gh`
  and the Actions lanes send out and what stays local, and names the three guard markers and
  where they may sit. `tests/run.sh` prints a note, not a failure, when the marketplace `ref`
  is not `v<version>` of `plugin.json`: the release recipe tags before it moves the ref, so the
  release PR's own CI runs one tag behind by design.

## 0.3.0

Tooling refresh needed: **yes** — `/adlc-init` now writes this repo's copies of the five
agents and a RUNBOOK that invokes them; until then the RUNBOOK copy in your repo still names
the plugin's agents, which keep working. The lane workflows also changed: each prompt now
names the role skill (`adlc:role-<role>`) to load first. A lane copy from 0.2.0 keeps
working, since its prompt already loads the role's skills and the plugin's agents list that
skill first.

Covers everything on `main` after the 0.2.0 tag (`c6dbcd7`) up to and including this release
commit: pull requests 31 to 33, the last of them merged as `516ee27` on 2026-10-20.

- **The model per agent is yours.** Each role prompt is now a plugin skill
  (`adlc:role-<role>`) and the plugin's agents are thin wrappers that preload it with the
  role's other skills. `/adlc-init` writes the same wrappers into your repo as
  `.claude/agents/adlc-<role>.md`, asking which model each one runs on (defaults: `opus` for
  the Analyst, the Architect and QA/Ops; `fable` for the Builder and the reviewer); the
  RUNBOOK invokes those copies, and `/adlc-model` prints the five models or changes one. The
  Actions lanes still run the plugin's `adlc:<role>` agents with the plugin's defaults. A
  copy reports to hooks as `adlc-<role>`, so the guard hook, Mission Control and the run
  ledger treat it as the role, like `adlc:<role>`. The doctor checks the five copies exist
  and each has a model.
- **Docs.** The README's At a glance chart is now a hero image that shows the pipeline and
  Mission Control, in place of the Mermaid flowchart; `docs/readme-hero.py` regenerates it.

## 0.2.0

Tooling refresh needed: **yes** for a repo set up before this release (its copies predate
the lane wiring, the trusted guards and the fixes below, and it has no `.adlc/VERSION`).
**No** for a repo set up with this release.

This is the first tagged release. `plugin.json` has said `0.2.0` since 2026-10-03, so a
machine that installed before this tag has a cache entry under the same version string, and
`claude plugin update` may report it as already current. Such a machine should uninstall and
reinstall `adlc@adlc-pipeline` (untested here). The next release avoids this by bumping the
version. It covers everything on `main` up to 2026-10-16.

- **Lanes run as their agents.** Each Actions lane installs the plugin, runs as its named
  agent (`--agent adlc:<role>`) and gets only that lane's tools. `tests/run.sh` pins every
  lane's agent and tool grant. The plugin's guard hook blocks merge, push-to-main and
  force-push, and now also a `gh` alias definition or `git -c alias.…`, which could hide one.
- **Diff guards run from the default branch.** The diff-scope workflow (the scope check and
  the fast-lane cap check) runs on `pull_request_target`, so its workflow and scripts are the
  default branch's and a pull request cannot edit the check that judges it. The scope file is
  read as a git blob and a link at the scope folder is refused.
- **Fast lane.** Trivial changes can skip design and Gate 1. The cap fails closed, a
  submodule change (and `.gitmodules`) is never fast-eligible, and a human approves the
  lane.
- **Fix loop.** The cap counts only the pull request's own fix rounds.
- **Intake.** `/adlc-intake` is one front door for an idea, a PRD, an issue, a bug or a
  ticket from another tracker. It files a sharpened `stage:intake` issue only on a yes.
- **Mission Control.** `/adlc-mission-control` opens a local, live view of the pipeline
  (stations, requests, tokens, cost). It reads GitHub through your `gh` login.
- **Doctor.** Checks that every agent step installs the plugin and grants tools, that the
  scripts the lanes call are installed, and, when `gh` can ask, that the default branch has
  a merge gate (an approving review, or at least the tripwire). It runs `gh` inside the
  repo named by its argument. New: it compares `.adlc/VERSION` with the plugin's version.
- **Metrics.** `first_pass_approved` counts pull requests with no CHANGES verdict comment,
  reading a comment's last marker as `adlc-verdict.sh` does.
- **Guard fixes ported from a host repo.** Nine scripts hardened in a real repo are back in
  the templates: a failed lookup no longer reads as "nothing to check" (tripwire, fix cap,
  verdict, diff-scope), and the tripwire workflow has the `pull-requests: read` it needs on
  a private repo.
- **Cycle retro.** A `cycle-retro` skill reads a run ledger (`adlc-run-log.sh`: tokens, cost and
  latency per agent run, from Mission Control, OpenTelemetry or Actions data) and per-issue
  cycle times from the label timeline (`adlc-cycle.sh`), then proposes changes in one pull
  request. It never merges.
- **Docs.** README has an At a glance section, a version badge and a commands table;
  `docs/` has a plain-language explainer and a one-page diagram.
- **Release process.** Releases are git tags. `main` is development. The marketplace entry
  is pinned to the release tag, so installs and the Actions runner get the tagged release,
  not whatever is on `main`.

## How a release is cut

1. On `main`, bump `version` in `.claude-plugin/plugin.json`. Only the release commit
   changes it: Claude Code keys its cache on that string, so users see an update only
   when it changes.
2. Add the entry above, with its "Tooling refresh needed" line. A refresh is needed when
   the release changes anything under `templates/` that `/adlc-init` copies into a repo.
3. Commit, then tag the commit `vX.Y.Z` and push the tag.
4. In `.claude-plugin/marketplace.json`, move the `adlc` entry's `ref` to the new tag and
   push. Run `claude plugin validate .` first.
5. Users get it with `claude plugin update adlc@adlc-pipeline`. Lanes get it on their next
   run.

Rollback: move the marketplace `ref` back to the previous tag and push. Claude Code has no
rollback command, and how an already-updated machine reacts to an older version string is
not verified here, so test it before relying on it.

Plugin development does not need a release: run `claude --plugin-dir <checkout>`.
