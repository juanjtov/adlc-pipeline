#!/usr/bin/env bash
# Local CI: run the repo's test battery on this machine, on the PR's head commit, and post ONE PR
# comment with the results and a marker line. For a repo whose checks did not run on GitHub:
# Actions is blocked (adlc-doctor.sh says when), or CI is not on Actions at all. One host in that
# state posted free-form "Local CI on head X" prose that no reader could parse; this is the
# recipe, and the marker is what QA and adlc-metrics.sh read.
#
# Usage:  adlc-local-ci.sh <pr> [--dry-run] [commands-file]     (default .adlc/local-ci.txt)
#
# The commands file is the host's own (the plugin ships none; a PR that changes the default one is
# never fast-lane eligible, see adlc-triage.sh). One check per line:
#     <name>: <command>
#   The name is what comes before the FIRST colon: letters, digits, space, `.`, `_`, `-`. The
#   command is the rest of the line, so it may hold colons itself (`db: psql postgres://…`). Blank
#   lines and lines that start with `#` are skipped. Any other line is an error, and so is a file
#   with no check: nothing runs then.
#   Each command is one line, run with `bash -c` from the repo's root, with no stdin; its output
#   goes to this script's stderr. A failed check does not stop the ones after it. There is no
#   per-command timeout (bash 3.2 and BSD userland have none to offer): put one in the command if
#   it needs one.
#
# Refuses to run (exit 2, nothing posted) unless the working tree is clean (`git status
# --porcelain --untracked-files=normal` prints nothing: untracked files count whatever the repo's
# status.showUntrackedFiles says, so commit the commands file or keep it outside the repo) and
# HEAD is the PR's head commit (`gh pr view <pr> --json headRefOid`), so the SHA in the marker is
# the commit that was checked out when the battery ran. Both are checked again after the battery:
# a check that moved HEAD, rewrote a tracked file or left an untracked one (a formatter that
# fixes, a code generator, a snapshot update) means exit 2 and no comment, because the checks
# after it ran on something that is not that commit. Ignored files do not count: build output
# belongs in .gitignore, and a formatter runs in its check mode here.
#
# The comment (`gh pr comment`, one call; --dry-run prints it instead) is a small table (check,
# result, exit code, seconds) whose LAST line is the marker:
#     ADLC-CI: PASS head <full sha>        every check exited 0
#     ADLC-CI: FAIL head <full sha>        at least one did not
# Exit 0 on PASS, 1 on FAIL; 2 on bad arguments, a missing or malformed commands file, a dirty
# tree, the wrong head, or a gh call that failed (when the post fails the comment is printed on
# stdout so the result is not lost).
#
# The marker is a RECORD, not a gate. Anyone who can comment on the PR can write that line, and
# nothing checks that the battery really ran. A reader takes it only for the PR's current head.
set -euo pipefail
pr=""; dry=""; file=""
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    -*) echo "adlc-local-ci: unknown option '${a}'" >&2; exit 2 ;;
    *) if [ -z "$pr" ]; then pr="$a"; elif [ -z "$file" ]; then file="$a"; else echo "adlc-local-ci: too many arguments" >&2; exit 2; fi ;;
  esac
done
case "$pr" in ''|*[!0-9]*) echo "usage: adlc-local-ci.sh <pr> [--dry-run] [commands-file]   (the PR must be a number, got '${pr}')" >&2; exit 2 ;; esac
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "adlc-local-ci: not inside a git checkout" >&2; exit 2; }
file="${file:-${root}/.adlc/local-ci.txt}"
[ -f "$file" ] || { echo "adlc-local-ci: no commands file at ${file} (one '<name>: <command>' per line)" >&2; exit 2; }

# Read the whole file before anything runs: a malformed line is an error, not a skipped check.
names=(); cmds=(); ln=0
while IFS= read -r line || [ -n "$line" ]; do
  ln=$((ln + 1))
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in *:*) ;; *) echo "adlc-local-ci: ${file} line ${ln}: no '<name>: <command>'" >&2; exit 2 ;; esac
  name="$(printf '%s' "${line%%:*}" | sed -E 's/[[:space:]]+$//')"
  cmd="$(printf '%s' "${line#*:}" | sed -E 's/^[[:space:]]+//')"
  case "$name" in ''|*[!A-Za-z0-9._\ -]*) echo "adlc-local-ci: ${file} line ${ln}: the name before the first colon must be letters, digits, space, '.', '_' or '-', got '${name}'" >&2; exit 2 ;; esac
  [ -n "$cmd" ] || { echo "adlc-local-ci: ${file} line ${ln}: '${name}' has no command" >&2; exit 2; }
  names+=("$name"); cmds+=("$cmd")
done < "$file"
[ "${#names[@]}" -gt 0 ] || { echo "adlc-local-ci: ${file} names no check" >&2; exit 2; }

# --untracked-files=normal: a repo with status.showUntrackedFiles=no would otherwise hide them
tree() { git -C "$root" status --porcelain --untracked-files=normal; }
dirty="$(tree)" || { echo "adlc-local-ci: git status failed" >&2; exit 2; }
[ -z "$dirty" ] || { echo "adlc-local-ci: the working tree is not clean (untracked files count); commit or stash first, so the marker names the code that was tested" >&2; exit 2; }
head="$(git -C "$root" rev-parse HEAD)" || { echo "adlc-local-ci: cannot read HEAD" >&2; exit 2; }
want="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)" || { echo "adlc-local-ci: could not read the head commit of PR #${pr}" >&2; exit 2; }
[ "$head" = "$want" ] || { echo "adlc-local-ci: HEAD is ${head}, PR #${pr}'s head is ${want:-unknown}; check out the PR's head first" >&2; exit 2; }

rows=""; verdict=PASS; i=0
while [ "$i" -lt "${#names[@]}" ]; do
  echo "== ${names[$i]}: ${cmds[$i]}" >&2
  t0=$(date +%s); rc=0
  ( cd "$root" && bash -c "${cmds[$i]}" ) </dev/null 1>&2 || rc=$?
  t1=$(date +%s)
  if [ "$rc" -eq 0 ]; then res=pass; else res=FAIL; verdict=FAIL; fi
  echo "== ${names[$i]}: ${res} (exit ${rc}, $((t1 - t0)) s)" >&2
  rows="${rows}| ${names[$i]} | ${res} | ${rc} | $((t1 - t0)) |
"
  i=$((i + 1))
done
after="$(git -C "$root" rev-parse HEAD)" || after=""
[ "$after" = "$head" ] || { echo "adlc-local-ci: HEAD moved during the battery (${head} → ${after:-unknown}); nothing posted" >&2; exit 2; }
dirty="$(tree)" || { echo "adlc-local-ci: git status failed after the battery; nothing posted" >&2; exit 2; }
[ -z "$dirty" ] || { echo "adlc-local-ci: the battery changed the working tree, so the checks after that did not run on ${head}; nothing posted. Make the checks read-only (a formatter in check mode) and put build output in .gitignore:" >&2
                     printf '%s\n' "$dirty" | head -10 >&2; exit 2; }

body="Local CI on \`${head}\`, run on a local machine by \`adlc-local-ci.sh\`, not by GitHub Actions. A record, not a gate.

| check | result | exit | seconds |
|---|---|---|---|
${rows}
ADLC-CI: ${verdict} head ${head}"
if [ -n "$dry" ]; then
  printf '%s\n' "$body"
elif ! gh pr comment "$pr" --body "$body" >/dev/null; then
  echo "adlc-local-ci: gh pr comment failed for PR #${pr}; nothing was posted. The comment:" >&2
  printf '%s\n' "$body"
  exit 2
else
  echo "adlc-local-ci: posted ADLC-CI: ${verdict} head ${head} on PR #${pr}" >&2
fi
[ "$verdict" = PASS ]
