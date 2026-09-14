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
