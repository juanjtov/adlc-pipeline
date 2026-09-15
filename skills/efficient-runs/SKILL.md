---
name: efficient-runs
description: How to keep a long agent run cheap and fast — cost grows with the number of steps, not the size of any one result. Load for the Builder and QA/Ops, or any agent doing multi-step shell work.
---

# Efficient runs

Every tool call re-sends the whole session so far, so cost grows with the **number** of
steps you take, not the size of any one result. A step late in a long run costs several
times a step early in it. Fewer, denser steps are cheaper and faster.

- **Set the working directory once.** `cd` into your branch/worktree in your first Bash
  call, then issue bare commands — the shell's cwd persists between calls. Don't prefix
  every command with `cd <path> && …`.
- **Never poll in a loop.** Wait on CI with one blocking call
  (`gh run watch <run-id> --exit-status`), not repeated `sleep`/`until`/`while` checks —
  each iteration is a full step.
- **Batch independent shell work** into one call (`&&` / `;`).
- **Read a file once.** Keep what you read; don't re-open an unchanged file.
- **Don't page huge output into the session** when you need only part of it — redirect to a
  file and read back the slice you need.

**Exception — evidence you must quote:** test summary lines, failing assertions, and
security findings are always pasted verbatim from the real run, never summarized from
memory and never trimmed to fit.

## Keep the prefix frozen (prompt caching)

The harness caches the request prefix — the tool set, the skills you load, and `CLAUDE.md`
— and re-serves it at a fraction of the input price on every later step of the run. That
cache is a byte-exact prefix match, so a single changing byte early in it re-processes
everything after at full price. To keep the discount:

- **Don't bake per-run values into files the agents load as context** (`CLAUDE.md`, the
  project skills). A live timestamp, a run/commit id, or an unfilled `{{PLACEHOLDER}}` in
  the frozen prefix defeats caching for the whole run. Per-run specifics — the issue body,
  the PR diff, the failing output — belong in the task prompt, not in a persistent file.
  `adlc-doctor.sh` fails the setup if it finds one, so this is enforced, not just advised.
- **Don't switch model or tool set mid-run** — both sit at the front of the prefix; changing
  either rebuilds the cache from scratch. Each role already has a fixed model and `tools:`.
- **Verify it, don't assume it.** With telemetry on, `adlc-cache.sh` reports cache-read %
  per agent; a lane reading 0 from cache means a silent invalidator crept into the prefix.
