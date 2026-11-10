# Working on the plugin

For people changing ADLC itself. To use it in a repository, start at the [README](../README.md).

## Load your checkout

```bash
claude --plugin-dir /path/to/adlc-pipeline
```

That session runs your working tree, not a release: its skills, agents, commands and hooks.
`/reload-plugins` picks up an edit without restarting. The guard hook acts only in a repo that
adopted ADLC (see "What leaves your machine" in the README), so it stays out of the way in this
checkout.

## Run the tests

There are two suites, and CI (`.github/workflows/test.yml`) runs both on every push and pull
request.

| Command | What it covers | Needs |
|---|---|---|
| `bash tests/run.sh` | Every script under `templates/scripts/`, the guard hook, the workflow templates (their triggers, their agent wiring, several steps run as shipped against a stub `gh`), the pre-commit hook, the skills' and agents' wiring, and the docs checks below. Ends `== N passed, 0 failed ==`; exit 0 means all passed. | `bash`, `python3`, `git`, `jq`: without one of them the run fails. Without `sqlite3` the cycle-retro ledger checks are skipped and the run says so. |
| `python3 -m unittest discover -s mission-control/tests` | Mission Control: the store, the hook reporter, the GitHub reader, the server over a real local socket. | Python 3.9 or newer, standard library only. |

`tests/guard-cases.sh` is not run by itself. `tests/run.sh` sources it: it is the table of
commands the guard must allow (`A`) or deny (`D`), one line per case, for the main thread and
for each narrow role. A new shape of a merge or a push goes there.

CI runs the Mission Control suite twice: on the runner's Python, and on Python 3.9, because
Mission Control promises to run on the Python that ships with the macOS developer tools. The
job is pinned to `ubuntu-24.04` for that; the comment in the workflow says when to move it.

No test talks to GitHub. Scripts that call `gh` are run against a stub `gh` placed first on
`PATH`, which answers from fixture files and records its arguments; several tests assert on
how many calls a script made.

## What is pinned on purpose

Some checks in `tests/run.sh` fail when you change something that is correct to change. That
is the test doing its job: it makes the change visible in review. Change the pin in the same
commit, and say so in the pull request.

- **Each lane's agent and tool grant.** Which agent every workflow step runs as is pinned in
  the test. A role step's exact `--allowedTools` must equal the `lanes` entry of the role's
  contract (`contracts/<role>.json`), so widening a grant has to change the contract too
  (`contracts/README.md`, "Changing a contract"). The retro's two steps run no role: their
  grant is pinned in the test itself.
- **Each lane names its role skill first**, and the agents stay thin wrappers over the role
  skills, in the plugin's copies and in the vendored templates alike.
- **The labels** `labels.sh` creates, and the ones the doctor expects.
- **Wording that caused a bug once.** For example, no lane, RUNBOOK or autopilot skill may spell
  a raw `--add-label stage:…` pair; they call `adlc-relabel.sh`.
- **The reference page.** Every `ADLC_*` setting the code reads, every marker and every label
  must be in [docs/reference.md](reference.md). Add the row with the code.
- **The marketplace pin.** When the `ref` in `.claude-plugin/marketplace.json` is not
  `v<version>` of `plugin.json`, the run prints a note and still passes: that is the normal
  state between a release's two steps (CHANGELOG.md, "How a release is cut").

## Try a lane without GitHub

A real lane run needs a GitHub repo with both secrets. For most changes a dry run on your own
machine is enough: the same agent, the same grant, the same guard hook, with a fake `gh`.
It makes real model calls, so it costs a little. This recipe was last run on Claude Code
2.1.321; check the behaviour again on a newer version before relying on a detail.

1. **A scratch host repo** with a local bare repo as its `origin`:

   ```bash
   mkdir -p /tmp/adlc-dry/host && cd /tmp/adlc-dry/host && git init -q -b main
   mkdir -p .adlc/scripts docs && cp /path/to/adlc-pipeline/templates/scripts/*.sh .adlc/scripts/
   git add -A && git commit -q -m "scratch host" && git clone -q --bare . ../origin.git
   git remote add origin ../origin.git
   ```

   Seed the origin with `git clone --bare`, not a push: with the plugin loaded, the guard
   blocks a push to `main` from a folder that holds `.adlc/scripts/`.

2. **A fake `gh`**, first on `PATH`, that records what it was asked and prints an empty
   answer:

   ```bash
   mkdir -p /tmp/adlc-dry/bin && cat > /tmp/adlc-dry/bin/gh <<'EOF'
   #!/usr/bin/env bash
   printf '%s\n' "$*" >> /tmp/adlc-dry/gh-calls.log
   case "$*" in *--json*) echo '{}' ;; esac
   EOF
   chmod +x /tmp/adlc-dry/bin/gh
   ```

   Make it answer with fixture JSON for the reads your lane depends on (an issue body, a PR
   diff) when you want the agent to get further.

3. **Run the lane's agent step.** Open the template (say `templates/github/adlc-intake.yml`),
   copy its `claude_args` and its `prompt`, and replace each `${{ … }}` with a value:

   ```bash
   cd /tmp/adlc-dry/host
   GITHUB_ACTIONS=true PATH="/tmp/adlc-dry/bin:$PATH" claude -p "<the lane's prompt>" \
     --plugin-dir /path/to/adlc-pipeline \
     --setting-sources project,local --strict-mcp-config --no-session-persistence \
     --output-format stream-json --verbose \
     --agent adlc:product-analyst --permission-mode dontAsk \
     --allowedTools "<the lane's grant, copied from the template>" < /dev/null > /tmp/adlc-dry/stream.jsonl
   ```

   `GITHUB_ACTIONS=true` puts the guard hook in scope, as on a runner. `--setting-sources
   project,local` and `--strict-mcp-config` keep your own settings and connectors out of the
   run.

4. **Read the stream** (`/tmp/adlc-dry/stream.jsonl`, one JSON event per line). The first
   `system` event (`subtype: init`) lists the tools, agents and plugins the session loaded.
   Each tool call and its result follow. The final `result` event carries
   `permission_denials`: every call the grant or the guard refused. `/tmp/adlc-dry/gh-calls.log`
   holds every `gh` call that got through. A scratch host has no `project-conventions` or
   `release-ops` skill, so the agent's Skill calls for those two fail; that is expected.

`--model haiku` is enough to check permissions and hooks, which do not depend on the model. To
judge how an agent behaves on a prompt, run it on the model its agent file names.

A workflow's own `run:` steps (the cap, the handoff, the relabel) are plain shell: the tests
run several of them as shipped, and you can do the same against the fake `gh`.

## Keep the docs in step

| When this changes | Update |
|---|---|
| A script, skill, command or template is added or renamed | the layout tree in the README |
| An `ADLC_*` setting, a marker or a label | [docs/reference.md](reference.md) (a test fails until you do) |
| The pipeline's flow, a gate, a lane, a guard | [docs/adlc-pipeline-explained.md](adlc-pipeline-explained.md), and the strings in `docs/adlc-pipeline-diagram.py` |
| What a release contains, or whether hosts must refresh | `CHANGELOG.md`, under `## Unreleased` at the top (add the heading when the last release took it) |
| How Mission Control looks | `docs/mission-control-demo.png` (the `--demo` page at 1440×900, dark) and `python3 docs/readme-hero.py --capture` for the README picture |

Two of these need tools that are not in the repo. The diagram's HTML and PNG are built by
`docs/adlc-pipeline-diagram.py` with a drawing kit the maintainer keeps outside it: change the
strings in the script and say in the pull request that the picture needs a rebuild.
`docs/readme-hero.py` needs `playwright` and `pillow` (its header says how to install them).

Every sentence in these documents is a claim about the code. Before you open a pull request,
check each one you wrote against the code it describes; write "when it is on" and "may", not
"always", where that is the truth.

## Layout rules worth knowing

- **`templates/` is what the wizard copies into a host repo**, and is MIT-licensed; everything
  else is the plugin and is AGPL (README, "Licensing"). A file under `templates/` is frozen in
  a host until its next `/adlc-init` refresh, so a change there needs "Tooling refresh needed:
  yes" in the CHANGELOG.
- **Scripts fail closed.** A read that fails is an error, never a silent zero, GO or PASS.
- **Scripts run on macOS and Linux**: bash 3.2, BSD and GNU tools. Python is 3.9, standard
  library only.
- **Skills are prompts.** Each line is paid for on every run that loads it. Prefer a check in
  a script to a sentence in a skill.
