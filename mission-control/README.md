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
`http://localhost:4319`. Options: `--repo owner/name`, `--port N`, `--home DIR`.

Requirements: Python 3.9 or newer (the one that ships with macOS developer tools is enough),
`gh` signed in, `git`, `curl`. Nothing to install: no packages, no Docker, no build step.

## Where the data comes from

| On the page | Source | How fresh |
|---|---|---|
| Where each request is, gates waiting on you, verdicts, merges | GitHub, read with your `gh` login (one GraphQL call) | every 15 s |
| What each agent is doing, step by step | The plugin's hooks (`hooks/hooks.json` -> `hook.sh`) | at once |
| Tokens, cache use, cost, latency | Claude Code telemetry sent straight here (OTLP over HTTP/JSON) | about 2 s |
| System prompt, tool grants | The agent files in `agents/` | on load |

Telemetry is opt-in. Merge the `env` block of `templates/settings.mission-control.json` into
the repo's `.claude/settings.local.json` and start a new Claude Code session. Without it the
page still shows the line and every step; the token and cost figures stay empty.

## What it can and cannot see

- **Agents on this machine only.** An agent on a GitHub-hosted runner cannot reach
  `localhost`, so for those runs the page shows the GitHub state (labels, pull request,
  verdicts) and nothing about steps or tokens.
- **Only pipeline agents.** `hook.sh` forwards an event only when it comes from one of the
  five ADLC agents, and only while Mission Control is running. Other sessions are never sent.
- **A run is tied to its request by number.** The issue or pull-request number is read from
  the task prompt ("issue #142", "PR #156") or the branch name (`feat/142-...`). A run with no
  number still shows at its station, without a request.
- **Capture window.** Steps and tokens are recorded only while Mission Control is running.
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

The server listens on `127.0.0.1` only, refuses requests that carry another site's `Origin`,
and keeps its database in `~/.adlc/mission-control/` (override with `ADLC_MC_HOME`). While it
runs it leaves a `server.json` there so the hook knows where to send; it removes the file on exit.
