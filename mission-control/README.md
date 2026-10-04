# ADLC Mission Control

A live view of the pipeline for one repo, on your own machine. It shows the line as a row of
stations (one per agent, plus the two human gates), every request as a crate moving between
them, and for each station: what the agent is doing right now, what went in, what came out,
and what it cost.

It is **read-only**. It never changes a label, posts a comment or merges. Phase 1 observes;
acting on gates from the page is a later phase.

## Run it

```bash
adlc-mission-control --open            # in the repo you want to watch
adlc-mission-control --demo --open     # made-up data, no GitHub needed
```

Inside Claude Code, `/adlc-mission-control` does the same. The page is at
`http://localhost:4319`. Options: `--repo owner/name`, `--port N`.

Requirements: Python 3.9 or newer (the one that ships with macOS developer tools is enough),
`gh` signed in, `git`, `curl`. Nothing to install: no packages, no Docker, no build step.

## Where the data comes from

| On the page | Source | How fresh |
|---|---|---|
| Where each request is, gates waiting on you, verdicts, merges | GitHub, read with your `gh` login (one GraphQL call) | every 15 s while the page is open |
| What each agent is doing, step by step | The plugin's hooks (`hooks/hooks.json` -> `hook.sh`) | at once |
| Tokens, cache use, cost, latency | Claude Code telemetry sent straight here (OTLP over HTTP/JSON) | about 2 s |
| System prompt, tool grants | The agent files in `agents/` | on load |

Telemetry is opt-in. Merge the `env` block of `templates/settings.mission-control.json` into
the repo's `.claude/settings.local.json` and start a new Claude Code session. Without it the
page still shows the line and every step; the token and cost figures stay empty. Keep the
`OTEL_LOG_TOOL_DETAILS=1` line of that block: without it Claude Code calls every plugin agent
`custom`, and the replies of an agent started as a subagent cannot be placed on its run.

## What it can and cannot see

- **Agents on this machine only.** An agent on a GitHub-hosted runner cannot reach
  `localhost`. The lanes in `templates/github/` run there, so for those runs the page shows the
  GitHub state (labels, pull request, verdicts) and nothing about steps or tokens. A request
  with no run on this machine is shown as "at" its station, not as queued or idle: the page
  cannot tell whether its agent is at work elsewhere.
- **Only pipeline agents.** `hook.sh` forwards an event only when it names one of this plugin's
  five agents (`adlc:builder` and so on), and only while Mission Control is running. That is an
  agent's own events, and the call a session makes to hand work to one. Nothing else is sent.
- **What is kept.** For each run: its task prompt and its final message, and for each tool call
  a one-line label, the file an edit touched, and the skill a Skill call loaded. What a tool
  returned is not kept. It all stays in one SQLite file on this machine.
- **A run is tied to its request by number.** The issue or pull-request number is read from
  the task prompt ("issue #142", "PR #156"). When the prompt names none, the branch name
  (`feat/142-...`) is used. A run with no number still shows at its station, without a request.
- **A pull request is tied to its issue** by a closing reference in the same repo ("Closes
  #142"), or else by its branch name. That is the rule `adlc-diff-scope.yml` uses.
- **Capture window.** Steps and tokens are recorded only while Mission Control is running.
- **GitHub is read only while a page is open.** One read costs about 5 of the 5,000 points of
  your hourly GraphQL budget, so an open page uses about 1,200 an hour per repo. With no page
  open nothing is read. A read returns the open issues that carry a pipeline label (up to 60),
  the 25 closed issues and 15 closed pull requests updated last, and up to 40 open pull requests.
- **Sizes marked `~` are estimates** from file sizes (about four characters a token). The
  remainder of a request (tool definitions, the environment block, the conversation so far)
  is measured, but its text is not exported by Claude Code, so it cannot be shown.
- **Epics are GitHub milestones.** The work list groups requests by milestone.

## How it is built

```
server.py        HTTP server: the page, /api/state, /api/events (Server-Sent Events), /hooks, /v1/logs
mc/pipeline.py   the line: slots, labels, agents, verdict markers
mc/store.py      SQLite (runs, steps, model replies, and a mirror of what was read from GitHub)
mc/ingest.py     hook events -> runs and steps; telemetry -> model replies
mc/github.py     the GitHub reader and its poller
mc/state.py      builds the one document the page renders
hook.sh          forwards a hook event when Mission Control is running; silent otherwise
web/             the page: plain JavaScript and CSS; demo.js is the simulator behind --demo
tests/           python3 -m unittest discover -s mission-control/tests
```

The server listens on `127.0.0.1` only. It refuses any request that carries another site's
`Origin`, and any request to its data from another site's page, so a web page you visit can
neither read the state nor post events.

The database and a small marker file, `server.json`, live in `~/.adlc/mission-control/`. Set
`ADLC_MC_HOME` to move both; `hook.sh` reads the same variable, so set it for Claude Code too.
The marker tells the hook which port to send to. One copy runs per folder: a second one points
you at the first. The marker is removed when Mission Control stops (Ctrl+C, a closed terminal,
or `kill`). If the process is killed outright the marker stays; the hook then finds nothing
listening and stays silent, and the next start replaces it. `--demo` writes no marker and keeps
nothing, so agents never report to made-up data.
