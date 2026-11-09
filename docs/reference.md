# Reference: settings, markers and labels

Three kinds of names are part of the plugin's interface: the environment variables its code
reads, the marker lines agents and scripts write for other code to parse, and the GitHub labels.
Each has one table here. `tests/run.sh` fails when a name the code uses has no row on this page,
and when a row names something the code no longer uses, so add or remove the row in the same
change as the code.

Paths are given as they are in this repository. In a repo that adopted ADLC the scripts are the
copies under `.adlc/scripts/` and the workflows the copies under `.github/workflows/`.

## Settings

### Environment variables

"User setting" means you may set it. The others are set by a workflow, by the wizard or by the
tests, and are listed so that every `ADLC_*` name has an explanation.

| Variable | What it does | Default | Read by | Kind |
|---|---|---|---|---|
| `ADLC_TEST_DIRS` | The test directories QA may write, as a regex alternation anchored at the start of the path, each directory ending in `/` (`tests/\|backend/tests/`). The scope check allows these paths in the `qa` and `build+qa` stages. | `tests/` | `templates/scripts/adlc-diff-scope.sh`. `templates/github/adlc-diff-scope.yml` sets it (the wizard fills the value), and so does `templates/hooks/pre-commit` when it is not already set. | User setting |
| `ADLC_FAST_MAX_FILES` | The most files a fast-lane change may touch. A scope file (`.adlc/scope/<issue>.txt`) is not counted. | `5` | `templates/scripts/adlc-triage.sh` | User setting. To change it for the lanes, set it in the `env` of the cap step in `adlc-fast.yml` and of the step in `adlc-diff-scope.yml` (the same value in both). |
| `ADLC_FAST_MAX_LINES` | The most added plus deleted lines a fast-lane change may have. Counted only when the script is given `git diff --numstat` lines; with a plain list of paths there is no line count. | `40` | `templates/scripts/adlc-triage.sh` | User setting, set as above |
| `ADLC_FAST_DENY` | An extended regex of paths that are never fast-eligible. Setting it replaces the built-in list; it does not add to it. The submodule rule and the binary-file rule are separate and stay on. | Built in: directories named `migration(s)`, `auth`, `authz`, `security`, `infra`, `terraform`, `deploy`, `helm`, `k8s` or `kubernetes`; anything under `.github/`, `.claude/` or `.adlc/scripts/`; `Dockerfile` and `docker-compose.yml` / `.yaml`; dependency manifests and lock files, `.gitmodules` among them; files named `env` or `.env`, with or without a suffix; a `secret` or `secrets` file or directory. The exact regex is in the script. | `templates/scripts/adlc-triage.sh` | User setting, set as above |
| `ADLC_SETUP_STEPS` | A case-insensitive extended regex matched against the name of the first failed step of a red CI run. Only red runs on a merged pull request's branch are looked at. A match makes the run `infra_failed`: it is left out of `iterations_to_green` and does not make its pull request `failed_first`. Setting it replaces the built-in regex. | Built in, a heuristic on step names: the runner's own set-up and post-run steps, checkout, installs, setup actions, caches, registry logins, provisioning, and an ephemeral database or branch. The exact regex is in the script. | `templates/scripts/adlc-metrics.sh` | User setting |
| `ADLC_CHAINS_LIMIT` | How many issues, newest first, the follow-up chain report reads in its one `gh issue list` call, and how many pull requests when it needs them. A value that is not a whole number above 0 is an error (exit 2). When the list comes back full, the script says on stderr that a chain may be cut short. | `1000` | `templates/scripts/adlc-chains.sh` | User setting |
| `ADLC_MC_HOME` | The folder that holds Mission Control's database (`mc.sqlite`) and its marker file (`server.json`). The hook that reports to Mission Control finds the port through that marker, so the variable has to be set for the Claude Code sessions too, not only for the server. | `~/.adlc/mission-control` | `mission-control/mc/ingest.py` (the server), `mission-control/hook.sh` | User setting |
| `ADLC_MC_PORT` | The port Mission Control listens on when `--port` is not given. | `4319` | `mission-control/server.py` | User setting |
| `ADLC_MC_DB` | The path of Mission Control's SQLite file, for the run ledger's `mc` source. The script does not read `ADLC_MC_HOME`: if you moved the folder with it, set this too. | `$HOME/.adlc/mission-control/mc.sqlite` | `templates/scripts/adlc-run-log.sh` | User setting |
| `ADLC_REPO` | This repository as `owner/name`, for the run ledger's rows and for choosing this repo's runs in Mission Control's store. | Taken from `git remote get-url origin` | `templates/scripts/adlc-run-log.sh` | User setting, for a checkout whose `origin` is missing or is not the GitHub repo |
| `ADLC_PROTECTED_BRANCHES` | More branch names the guard hook treats as protected, comma- or space-separated: a push to one is blocked like a push to `main`. | Empty. `main`, `master` and the repository's default branch are always protected. | `hooks/adlc_guard.py`, from the environment of the Claude Code session | User setting |
| `ADLC_PLUGIN_REPO` | The repository the retro and the cycle retro file a plugin-scope suggestion into, as `owner/name`. | `juanjtov/adlc-pipeline` | The `gh issue create` command in `skills/retro/SKILL.md`; `skills/cycle-retro/SKILL.md` files the same way | User setting |
| `ADLC_PLUGIN_ROOT` | Where the doctor looks first for the plugin's `plugin.json`, to compare the plugin's version with `.adlc/VERSION`. After it the doctor tries `CLAUDE_PLUGIN_ROOT`, then the install path Claude Code recorded. | Unset | `templates/scripts/adlc-doctor.sh` | Set by the wizard when it runs the doctor (`skills/bootstrap/SKILL.md`), and by the tests |
| `ADLC_TRIPWIRE_BRANCH` | The branch name used in the text of a tripwire alert. | `main` | `templates/scripts/adlc-tripwire-alert.sh` | Set by `templates/github/adlc-main-tripwire.yml` to the pushed branch; not a user setting |
| `ADLC_DOCTOR_SKIP_LABELS` | Any non-empty value makes the doctor skip every check that calls `gh`: the labels, the double-label check, whether Actions is blocked, and the merge gate. | Unset | `templates/scripts/adlc-doctor.sh` | A switch for the tests |

### Repository secrets

The Actions lanes need both. Nothing in a local session reads either.

| Secret | What it is | Read by |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | The token `claude setup-token` prints, from a Claude subscription. It lets the runner's Claude Code sign in. | Every agent step in `templates/github/` (the action's `claude_code_oauth_token` input) |
| `ADLC_DISPATCH_TOKEN` | A personal access token or a GitHub App token. A label change made with a workflow's default token does not start another workflow, so the lanes use this one for the changes that hand work on, and the Builder's pull requests are opened under its identity. | Every agent step (the action's `github_token` input), and the workflow steps that move a label or post a comment in `adlc-intake.yml`, `adlc-design.yml`, `adlc-review.yml`, `adlc-fix.yml` and `adlc-fast.yml` (as `GH_TOKEN`). `adlc-diff-scope.yml`, `adlc-main-tripwire.yml` and `adlc-ci.yml` use neither secret. |

### Settings the plugin writes that are not its own

These are Claude Code's settings. The plugin ships a template for each group and the wizard, or
you, merges it into the repo's settings file.

| Setting | Value in the template | Template | Where it goes |
|---|---|---|---|
| `promptCacheTtl`, `subagentPromptCacheTtl` | `"1h"` each | `templates/settings.cache.json` (its `_comment` states the trade-off) | `.claude/settings.json`; the wizard merges the two keys and keeps a value already there |
| `permissions.deny` | Nine prefix rules against `gh pr merge` (and the merge call through `gh api`), a push to `main` and a force-push | `templates/settings.deny.json` | `.claude/settings.json`; the wizard merges them |
| `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_LOGS_EXPORTER`, `OTEL_EXPORTER_OTLP_PROTOCOL` (`http/json`), `OTEL_EXPORTER_OTLP_ENDPOINT` (`http://localhost:4319`), `OTEL_LOGS_EXPORT_INTERVAL`, `OTEL_LOG_TOOL_DETAILS` | The `env` block that sends tokens, cost and duration to Mission Control | `templates/settings.mission-control.json` | `.claude/settings.local.json` (or `settings.json`); opt-in, `/adlc-mission-control` offers it |
| `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER`, `OTEL_EXPORTER_OTLP_PROTOCOL` (`grpc`), `OTEL_EXPORTER_OTLP_ENDPOINT` (`http://localhost:4317`), `OTEL_RESOURCE_ATTRIBUTES` | The `env` block that sends the same data to an OpenTelemetry collector | `templates/settings.telemetry.json` (a collector ships in `telemetry/`) | `.claude/settings.json`; opt-in |

The two telemetry templates set the same keys, so a repo uses one or the other.

## Markers

A marker is a line of text that one part of the pipeline writes and another parses. No reader
checks who wrote a marker: each takes it from the comments of the issue or pull request, or from
an issue's body, whoever posted them. Three markers decide what a lane does next. The rest are a
record that a script or a person reads later.

| Marker, in its exact form | Written by | Read by | What it decides |
|---|---|---|---|
| `ADLC-TRIAGE: FAST \| <why>` or `ADLC-TRIAGE: FULL \| <why>` | The Product Analyst, as the last line of its triage comment on the issue | The Gate 1 handoff step of `templates/github/adlc-intake.yml`, which takes the last `ADLC-TRIAGE:` followed by `FAST` or `FULL` in the issue's comments; `/adlc:autopilot`, with the same search; Mission Control, to show the verdict | **Gates, under autopilot only.** With `adlc:autopilot` on the issue, once the Analyst has moved it to `gate:stories`, the intake lane leaves it there when the last verdict is `FAST` and moves it to `stage:design` otherwise, a missing verdict included. `/adlc:autopilot` is told to stop when there is neither word. Without autopilot it is a recommendation you read at Gate 1. |
| `ADLC-BREAKDOWN: <ADR path>` | The Architect, as the last line of its task-breakdown comment on the issue | The handoff step of `templates/github/adlc-design.yml`: it looks for a comment line that holds `ADLC-BREAKDOWN:` and the file name of an ADR this run added or changed under `docs/adr/` | **Gates, in the design lane.** Without that line, or without an ADR file, the step fails, says so on the issue and leaves it at `stage:design`. In a local session no script reads it. |
| `ADLC-ADV: PASS` or `ADLC-ADV: CHANGES` | The Adversarial Reviewer, as the last line of its pull-request comment | `templates/scripts/adlc-verdict.sh`, called by `adlc-review.yml`, `adlc-fast.yml` and `/adlc:autopilot`: it takes the last line in the pull request's comments that carries the marker; `*`, `_`, a backtick or spaces may sit between the colon and the word, and `PASSED` or lower case is no verdict. Also `adlc-rounds.sh` (fix rounds), `adlc-metrics.sh` (first-pass acceptance) and Mission Control. | **Gates.** Anything but `PASS`, an unreadable line included, is not a pass. In the review lane the issue moves to `stage:qa` only when this and `ADLC-ARCH` both read `PASS`; in the fast lane a `PASS` moves it to `gate:deploy`. Otherwise the pull request is labelled `adlc:changes-requested`. |
| `ADLC-ARCH: PASS` or `ADLC-ARCH: CHANGES` | The Architect, as the last line of its design-conformance comment on the pull request. A verdict given only as a GitHub review is not read. | `adlc-verdict.sh` (called by `adlc-review.yml` and `/adlc:autopilot`), `adlc-rounds.sh`, `adlc-metrics.sh`, Mission Control | **Gates**, with `ADLC-ADV`, as above. The fast lane has no Architect review and does not read it. |
| `ADLC-FINDING: <severity> \| <class> \| <file>` | The Adversarial Reviewer and QA, one line per finding in their pull-request comment. The class comes from the closed list in the `edd-spec` skill. | `templates/scripts/adlc-log-findings.sh`, when the retro builds `.adlc/metrics/findings.jsonl`: the marker must start the line (list, quote, heading, bold or code markup aside) and carry all three fields. Mission Control shows the lines. | Record only. A finding blocks nothing by itself; the verdict line does. |
| `ADLC-CI: PASS head <sha>` or `ADLC-CI: FAIL head <sha>` | `templates/scripts/adlc-local-ci.sh`, as the last line of the one pull-request comment it posts; `<sha>` is the full commit id it ran on | `adlc-metrics.sh`, which counts each such comment on a merged pull request as one CI run; QA, whose prompt takes it as the battery result only when the commit is the pull request's current head | Record only. Anyone who can comment can write it, and nothing checks that the battery ran. |
| `ADLC-FOLLOW-UP: #<parent issue>` | QA, as a line in the body of the follow-up issue it files for a pull request's residuals | `templates/scripts/adlc-chains.sh`, to tell which issue a follow-up follows | Record only. It feeds the chain report; it blocks no issue from being filed. |
| `ADLC-SCOPE-REQUEST: <path prefix> \| <reason>` | The Builder, in a pull-request comment, when the work needs a path outside its scope file | The Architect, in its next review (its prompt tells it to answer every open request). No script reads it. | Record only. |
| `ADLC-SCOPE: GRANT <path prefix>` or `ADLC-SCOPE: DENY <path prefix>` | The Architect, one line per request in its review comment | The Builder, who on a grant adds that line to the scope file (its prompt). No script reads it. | Record only. The scope check enforces the scope file and reads no marker. |
| `ADLC-TRIPWIRE: direct <commit ids, sorted>` or `ADLC-TRIPWIRE: forced <before> <after>` | `templates/scripts/adlc-tripwire-alert.sh`, as the last line of the alert issue's body | The same script, before it files: it files no second alert while an open alert issue carries the same line | Duplicate check only. |
| `adlc-fix:` at the start of a commit subject | The Builder, on the commits of a fix round (the fix lane's prompt and `/adlc:autopilot` ask for it) | Mission Control, to place the moment a round went back to review; the older form of `templates/scripts/adlc-fix-cap.sh` that reads commit subjects on stdin (it takes `adlc-fix(<scope>):` too), which no shipped workflow calls | Record only. The fix-loop cap counts reviews (`adlc-rounds.sh`), not commits. |
| `adlc: host-owned` within the first five lines of an installed copy (in a comment: `# adlc: host-owned`) | You, in a script, workflow, agent copy or hook you want to keep as your own | `templates/scripts/adlc-refresh.sh`, which skips the file and lists it; `templates/scripts/adlc-doctor.sh`, which lists it | **Gates the refresh** of that one file: it is never overwritten. |

`templates/scripts/adlc-outputs.sh` holds the forms of the four required markers (`ADLC-TRIAGE`,
`ADLC-BREAKDOWN`, `ADLC-ARCH`, `ADLC-ADV`) as a table rendered from `contracts/`, and checks a
comment text against it. No lane calls it yet: each lane reads its marker in its own step, as the
table above says.

## Labels

`templates/github/labels.sh` creates the first seventeen. The last one, `adlc:plugin-suggestion`,
is not created by anything in the plugin: the retro files with it into another repository, the
one `ADLC_PLUGIN_REPO` names.

**What enforces who applies a label.** Nothing in a label says who may apply it, so the rules
below are held by three things, where each is on:

- **The guard hook**, for a session running as the Analyst, the Architect or the Adversarial
  Reviewer: it blocks `gh issue edit --add-label <label>` and `adlc-relabel.sh <issue> <label>`
  unless the label is on the role's list in its contract (`contracts/<role>.json`). The Analyst's
  list is `gate:stories`, the Architect's is `stage:build`, the reviewer's is empty. A label that
  is computed rather than written out is blocked too. The same contracts give those three roles no
  `gh pr edit`, so they cannot label a pull request. Not checked: a label being taken off; the
  Builder and QA, whose contracts set no label list, so their rule is their prompt; your own
  session, `/adlc:autopilot` included; and the workflows.
- **Each lane's tool grant**, in the Actions lanes: the Architect's and the reviewer's steps are
  granted no command that edits labels. The Analyst's step is granted `gh issue edit` and
  `adlc-relabel.sh`, so there its limit is the guard's.
- **The author allowlist** in each lane workflow: a label starts a lane only on an issue or pull
  request opened by an account on the list the wizard filled.

A `stage:` or `gate:` label is the issue's state, and an issue should carry one at a time.
`templates/scripts/adlc-relabel.sh` puts one on and takes every other `stage:`/`gate:` label off
in one call; the lanes and the role prompts move issues with it. A label you apply by hand does
not take the old one off. The doctor lists every open issue or pull request that carries two.

| Label | On | What it means | Who applies it |
|---|---|---|---|
| `stage:intake` | Issue | A request waiting for, or with, the Product Analyst. With `adlc:auto` also on the issue, `adlc-intake.yml` starts the Analyst. | You, by hand or through `/adlc-intake` or the Requirement issue form. QA's prompt has it file follow-ups and bugs with it. |
| `gate:stories` | Issue | Gate 1: the stories, or a change brief, wait for your approval and your choice of lane. | The Analyst (the one label the guard lets it add). |
| `stage:design` | Issue | The Architect's design stage. `adlc-design.yml` starts on it. | You, at Gate 1. For you, on a `FULL` verdict: the intake lane's handoff step under `adlc:autopilot`, and `/adlc:autopilot`. The fast lane's workflow (and `/adlc:autopilot`) when a fast-lane change fails the cap. No agent role: the guard blocks three of them, and the Builder's and QA's prompts forbid it. |
| `stage:build` | Issue | The Builder's stage. `adlc-builder.yml` starts on it. | The Architect in a local session (the one label the guard lets it add); in the design lane, the workflow's handoff step. |
| `stage:qa` | Issue | Both reviews passed; QA's stage. `adlc-qa.yml` starts on it. | The review lane's workflow step, from the two verdict markers. In the local recipe, you; under `/adlc:autopilot`, that session. |
| `gate:deploy` | Issue | Gate 2: a Proposed Action Card is posted and the merge waits for you. | QA, after a clean verdict (its prompt; the guard sets QA no label list). In the fast lane, the workflow's step after a `PASS`; in the local recipe's fast lane, you or `/adlc:autopilot`. |
| `stage:fast` | Issue | The fast lane, approved by a person. `adlc-fast.yml` starts the Builder on it. | You, only. No workflow adds it, autopilot never does, and the guard blocks the Analyst, the Architect and the reviewer from adding it. |
| `adlc:auto` | Issue | Run the Analyst automatically while the issue is at `stage:intake`. The intake lane takes it off when the Analyst stops to ask questions; adding it back runs the Analyst again. | You, the Requirement issue form, or `/adlc-intake` when you ask for it. |
| `adlc:autopilot` | Issue | Gate 1 is approved for you when the triage verdict is `FULL`. In the Actions lanes it has to be on the issue before the Analyst starts and still be there afterwards. | You, or the Requirement issue form when the wizard set it up for full autopilot. `/adlc:autopilot` adds it as the record of an approval it made. The guard blocks the Analyst from adding it. |
| `bug` | Issue | A defect, however it was reported. It enters at `stage:intake` like any request. | `/adlc-intake` for a bug you report; QA/Ops for a defect it found after a deploy. |
| `adlc:change-failure` | Issue | A defect QA/Ops traced to a deploy, beside `bug`. `adlc-metrics.sh` counts issues that carry it as `change_failures`. | QA/Ops (its prompt). The doctor reports a repo that lacks the label. |
| `adlc:tripwire` | Issue | A tripwire alert: a direct push or a force-push reached the default branch. | `adlc-tripwire-alert.sh`, run by `adlc-main-tripwire.yml`. If the repo lacks the label the alert is filed without it. |
| `adlc:changes-requested` | Pull request | A review asked for changes. `adlc-fix.yml` starts on it and takes it off before the Builder runs. The fix-round count reads how many times it was put on. | The review lane's and the fast lane's workflow steps, on a verdict that is not `PASS`; `/adlc:autopilot`. Put on by hand it starts the fix loop and is counted the same way. |
| `needs:human` | Pull request (under `/adlc:autopilot`, the issue while there is no pull request) | The automation stopped and a person has to take over. Nothing starts on it. | `adlc-fix.yml` when the fix-loop cap says `STOP`; you, in the local recipe, on the same answer; `/adlc:autopilot` at every stop. |
| `adlc:follow-up` | Issue | The one follow-up issue QA filed for a pull request's residuals. `adlc-metrics.sh` counts these as `follow_ups_filed`. | QA (its prompt). |
| `adlc:accepted-risk` | Issue, the root of a follow-up chain | You accepted the chain's residual risk. `adlc-chains.sh` lists the chain as decided, and QA's prompt has it file no more follow-ups in it. Only the label on the chain's root counts. | You. |
| `lane:fast` | Pull request | A fast-lane pull request. `adlc-fast.yml` runs its cap and review on it, `adlc-review.yml` leaves it alone, and the scope check applies the fast-lane cap. | The Builder in the fast lane (its lane prompt); `/adlc:autopilot`. The fast lane's workflow takes it off when the change fails the cap. |
| `adlc:plugin-suggestion` | Issue, in the plugin's repository | A lesson a retro judged general enough for the plugin itself. | The session running `/adlc:retro` or `/adlc:cycle-retro` (the skills' instruction). |
