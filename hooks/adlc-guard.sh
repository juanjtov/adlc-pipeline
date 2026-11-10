#!/usr/bin/env bash
# ADLC guard launcher — the PreToolUse hooks the plugin ships (hooks/hooks.json): one on Bash,
# one on the tools that write a file (Edit, Write, MultiEdit, NotebookEdit).
# Decides scope cheaply, then hands the hook input (JSON on STDIN) to adlc_guard.py, which
# blocks merges, pushes to a protected branch, force-pushes, out-of-role gh/git commands and
# label moves, and a file write outside the paths a role's contract (contracts/) allows.
#
# In scope  = a GitHub Actions run (the lanes), or a repo that adopted ADLC: a marker that only
#             /adlc-init writes — .adlc/scripts/, .adlc/VERSION or docs/adlc/CHARTER.md — at or
#             above the project dir or the session's current dir (above, so a session started in
#             a subdirectory of an adopted repo stays guarded). A bare .adlc/ directory is NOT a
#             marker: Mission Control keeps its state in ~/.adlc/mission-control, and through
#             0.3.0 that put every repo under the home directory in scope. Anywhere else this is
#             a no-op, so enabling the plugin user-wide never touches an unrelated repo.
# Exit 2 blocks the tool call; exit 0 defers to the normal permission flow. Claude Code treats
# every other exit code as a non-blocking error and runs the command anyway, so in scope this
# fails CLOSED: no python3, or a python3 that cannot run the guard, blocks the call (a Bash
# command or a file write alike).
set -u
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here="."

adopted() { # adopted <dir> — is <dir>, or a directory above it, an ADLC repo?
  local d="$1"
  while [ -n "$d" ]; do
    if [ -d "$d/.adlc/scripts" ] || [ -f "$d/.adlc/VERSION" ] || [ -f "$d/docs/adlc/CHARTER.md" ]; then return 0; fi
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
  done
  return 1
}

if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  adopted "${CLAUDE_PROJECT_DIR:-}" || adopted "$PWD" || exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ADLC guard: python3 not found — blocking this tool call so the guard can't be skipped. Install python3." >&2
  exit 2
fi
python3 "$here/adlc_guard.py"
rc=$?
[ "$rc" = 0 ] && exit 0
[ "$rc" = 2 ] || echo "ADLC guard: the guard itself failed (python3 exit $rc) — blocking this tool call so the guard can't be skipped." >&2
exit 2
