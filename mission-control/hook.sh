#!/usr/bin/env bash
# Forwards a Claude Code hook event to ADLC Mission Control, if it is running on this machine.
#
# Wired in by hooks/hooks.json, so it runs on every hook event of every session where the plugin
# is enabled. It must therefore be fast, silent, and unable to affect the tool call:
#   - Mission Control not running  -> exit at once, nothing is read or sent.
#   - the event is not from a pipeline agent -> nothing is sent.
#   - any failure -> still exit 0 with no output.
home="${ADLC_MC_HOME:-$HOME/.adlc/mission-control}"
[ -f "$home/server.json" ] || exit 0
port="$(sed -n 's/.*"port": *\([0-9][0-9]*\).*/\1/p' "$home/server.json" 2>/dev/null | head -1)"
[ -n "$port" ] || exit 0

input="$(cat)"
case "$input" in
  # Pipeline agents carry agent_type; a parent handing work to one carries subagent_type; SessionEnd closes its runs.
  *'"agent_type"'*|*'"subagent_type"'*|*'"SessionEnd"'*) ;;
  *) exit 0 ;;
esac

printf '%s' "$input" | curl -s -m 2 -o /dev/null -X POST -H 'Content-Type: application/json' \
  --data-binary @- "http://127.0.0.1:$port/hooks" 2>/dev/null || true
exit 0
