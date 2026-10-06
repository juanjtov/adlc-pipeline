#!/usr/bin/env bash
# Forwards a Claude Code hook event to ADLC Mission Control, if it is running on this machine.
#
# Wired in by hooks/hooks.json, so it runs on every hook event of every session where the plugin
# is enabled. It must therefore be fast, silent, and unable to affect the tool call:
#   - Mission Control not running  -> exit at once, nothing is read or sent.
#   - the event does not name one of the five pipeline agents -> nothing is sent.
#   - any failure -> still exit 0 with no output.
home="${ADLC_MC_HOME:-$HOME/.adlc/mission-control}"
[ -f "$home/server.json" ] || exit 0
port="$(sed -n 's/.*"port": *\([0-9][0-9]*\).*/\1/p' "$home/server.json" 2>/dev/null | head -1)"
[ -n "$port" ] || exit 0

# A pipeline agent's own events carry "agent_type":"adlc:<agent>". A session handing work to one carries
# "subagent_type":"adlc:<agent>". Any other event stays here, whatever agent or session it comes from.
ours='"(agent_type|subagent_type)"[[:space:]]*:[[:space:]]*"adlc:(product-analyst|architect|builder|adversarial-reviewer|qa-release-ops)"'
# Reading costs bash about 50 ms a megabyte, and it is the user's tool call that waits. An event past 2 MB (a tool
# that returned a very large result) is let go: its step then shows as not reported back, which is true.
max=2097152
input="$(head -c $((max + 1)))"
[ "${#input}" -le "$max" ] || exit 0
printf '%s' "$input" | grep -qE "$ours" 2>/dev/null || exit 0

# Short timeouts: this is loopback, and a wedged server must not cost a tool call two seconds.
printf '%s' "$input" | curl -s --connect-timeout 0.3 -m 0.8 -o /dev/null -X POST -H 'Content-Type: application/json' \
  --data-binary @- "http://127.0.0.1:$port/hooks" 2>/dev/null || true
exit 0
