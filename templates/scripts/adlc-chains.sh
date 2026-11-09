#!/usr/bin/env bash
# Follow-up chains: which issue each follow-up follows, how deep each chain runs, and whether
# the Principal has decided it. On one host 91 of 224 issue titles were follow-ups and several
# chains ran four to seven issues deep, each issue a full pipeline run; its retro had already
# said of one chain that the approach would keep losing, and three more rounds followed. A deep
# chain is a decision for the Principal (accept the risk, or redesign), not one more follow-up;
# this is what the retro, the cycle-retro and QA read to see one. Requires: gh authenticated, jq.
#
#   adlc-chains.sh report [min_depth]   (default 3; a whole number of 2 or more)
#       One line per chain at or over the depth, deepest first:
#         depth=4  #34 → #67 → #85 → #116  (issues: 6, open: 1)
#       A chain is a ROOT issue (one that follows no other) and every issue that follows from it,
#       so a parent with three follow-ups is one chain, not three: the line shows its longest
#       path (a tie goes to the lower numbers) and counts the issues in the chain, the root
#       included, with how many are still open. depth = issues on that path, root included.
#       A chain whose root carries `adlc:accepted-risk` is decided: it is listed after the
#       others on a line that starts `decided`, so `grep '^depth='` gives those still to decide.
#   adlc-chains.sh root <issue>
#       One line, `root=#34 depth=4 open` or `root=#34 depth=4 accepted-risk`: the root of that
#       issue's chain, the chain's depth as `report` counts it, and whether the root carries
#       `adlc:accepted-risk`. An issue that follows nothing and has no follow-up is its own
#       root, depth=1. QA asks this before it files a follow-up.
#
# The parent of an issue, first hit wins:
#   1. the marker line QA writes in a follow-up's body:  ADLC-FOLLOW-UP: #<parent issue>
#   2. for older issues, a phrase in the title, else in the body (case-insensitive):
#      "follow-up of|to|on|for|from #N", "residuals of|from #N", "residuals from QA of #N",
#      "QA of #N", "(from PR #N)" — `PR`, `issue` or nothing before the `#`.
# When #N is an issue that was read, it is the parent. When it is not, the number may be a pull
# request: ONE `gh pr list` call (made only then) reads the PR bodies, and the parent is the
# issue the PR's body closes (its first `Closes|Fixes|Resolves #M`, as the Builder writes it; an
# issue linked to the PR by hand only is not found). A parent must be OLDER than its follow-up
# (a lower number): a reference to itself or to a newer issue is dropped, so two issues that
# name each other cannot loop. `report` names on stderr every reference that gave no parent.
#
# Limits: every issue read counts, whatever its author or label. Whoever can open an issue in
# the repo (anyone, on a public one) can file issues whose marker lines name an existing issue
# and each other, and so deepen its chain: `report` and QA's `root` then read the greater
# depth. They cannot change what an existing issue names as its parent, and cannot make a
# chain read decided (that takes the label on the root). The phrase reading is a heuristic: a
# title or body that says "QA of #N" about an unrelated issue links to it.
#
# Cost: one `gh issue list --state all --limit $ADLC_CHAINS_LIMIT` call (default 1000, newest
# first), plus the one `gh pr list` call above with the same limit. When the list comes back
# full, older issues may not have been read and a chain can be cut short: stderr says so.
# Exit 0 when the read succeeded (also with no chain to show), 1 when gh or jq failed or `root`
# was asked for a number that is not among the issues read, 2 on bad arguments.
set -euo pipefail
cmd="${1:-}"; arg="${2:-}"
LIMIT="${ADLC_CHAINS_LIMIT:-1000}"
[ "$#" -le 2 ] || { echo "adlc-chains: too many arguments" >&2; exit 2; }
case "$cmd" in
  report) min="${arg:-3}"
          case "$min" in ''|*[!0-9]*) min=0 ;; esac
          [ "$min" -ge 2 ] || { echo "adlc-chains: min_depth must be a whole number of 2 or more, got '${arg}'" >&2; exit 2; } ;;
  root)   case "$arg" in ''|*[!0-9]*) echo "adlc-chains: the issue must be a number, got '${arg}'" >&2; exit 2 ;; esac ;;
  *)      sed -n '2,22p' "$0"; exit 2 ;;
esac
case "$LIMIT" in ''|*[!0-9]*|0) echo "adlc-chains: ADLC_CHAINS_LIMIT must be a whole number above 0, got '${LIMIT}'" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "adlc-chains: jq not found" >&2; exit 1; }

# .ref = the number an issue says it follows (null when it names none)
REF='
def ref:
  ((.body // "") | [match("(?:^|\\n)[ \\t>*`_-]*ADLC-FOLLOW-UP:[*`_ \\t]*#?([0-9]+)").captures[0].string] | first)
  // ([(.title // ""), (.body // "")
       | match("(?:follow[- ]?ups?\\s+(?:of|to|on|for|from)|residuals?\\s+(?:of|from)(?:\\s+(?:the\\s+)?QA\\s+of)?|QA\\s+of|\\(from)\\s+(?:(?:PR|issue|pull\\s+request)\\s+)?#([0-9]+)"; "i").captures[0].string] | first)
  | if . == null then null else tonumber end;'

issues="$(gh issue list --state all --limit "$LIMIT" --json number,title,body,labels,state)" \
  || { echo "adlc-chains: could not list the issues (gh issue list)" >&2; exit 1; }
read_n="$(printf '%s' "$issues" | jq 'if type == "array" then length else error("not a list") end')" \
  || { echo "adlc-chains: gh issue list did not return a JSON list" >&2; exit 1; }
[ "$read_n" -lt "$LIMIT" ] || echo "adlc-chains: read ${read_n} issues, the limit: older issues may not have been read and a chain can be cut short (set ADLC_CHAINS_LIMIT)" >&2

# Only a reference to a number that is not a listed issue needs the pull requests.
prs='[]'
stray="$(printf '%s' "$issues" | jq "$REF"' (map(.number)) as $nums | [.[] | ref | select(. != null)] - $nums | length')" \
  || { echo "adlc-chains: could not read the issue list" >&2; exit 1; }
if [ "$stray" -gt 0 ]; then
  prs="$(gh pr list --state all --limit "$LIMIT" --json number,body)" \
    || { echo "adlc-chains: could not list the pull requests (gh pr list); ${stray} reference(s) name a number that is not a listed issue" >&2; exit 1; }
fi

# One object: {trees: [{root, depth, path, issues, open, decided}], of: {"<issue>": <root>}, dropped: ["…"]}
# Both lists go in through file descriptors: a thousand issue bodies overflow an argument.
graph="$(jq -n --slurpfile issues <(printf '%s' "$issues") --slurpfile prs <(printf '%s' "$prs") "$REF"'
  $issues[0] as $all
  | ($all | map({key: (.number | tostring), value: .}) | from_entries) as $by
  | ($prs[0] | map({key: (.number | tostring),
                    value: ((.body // "") | [match("\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\b:?\\s+#([0-9]+)"; "i").captures[0].string | tonumber] | first)})
     | map(select(.value != null)) | from_entries) as $closes
  | ($all | map(. as $i | ($i | ref) as $r
       | (if $r == null then null
          elif $by[$r | tostring] != null then $r
          else ($closes[$r | tostring] // null) | if . != null and $by[tostring] != null then . else null end
          end) as $p
       | {n: $i.number, ref: $r, parent: (if $p != null and $p < $i.number then $p else null end),
          why: (if $r == null then null
                elif $p == null then "#\($i.number) names #\($r), which is neither a listed issue nor a pull request whose body closes one"
                elif $p >= $i.number then "#\($i.number) names #\($r)\(if $p != $r then " (which closes #\($p))" else "" end), which is not older than it"
                else null end)})) as $links
  | ($links | map(select(.parent != null) | {key: (.n | tostring), value: .parent}) | from_entries) as $par
  | def lineage: [recurse($par[tostring] // empty)] | reverse;   # root … this issue; a parent is always a lower number, so it ends
    ($all | map(. as $i | ($i.number | lineage) as $p
       | {n: $i.number, root: $p[0], path: $p, open: (($i.state // "") | ascii_downcase == "open")})) as $rows
  | {of: ($rows | map({key: (.n | tostring), value: .root}) | from_entries),
     dropped: ($links | map(.why | select(. != null))),
     trees: ($rows | group_by(.root) | map(
        {root: .[0].root, issues: length, open: (map(select(.open)) | length),
         path: (map(.path) | sort_by([-(length)] + .) | first),
         decided: ([$by[.[0].root | tostring].labels[]?.name] | index("adlc:accepted-risk") != null)}
        | .depth = (.path | length)))}')" \
  || { echo "adlc-chains: could not build the chains from the issue list" >&2; exit 1; }

case "$cmd" in
  report)
    printf '%s' "$graph" | jq -r '.dropped[] | "adlc-chains: \(.); no link made"' >&2
    printf '%s' "$graph" | jq -r --arg min "$min" --arg n "$read_n" '
      ($min | tonumber) as $min |
      def line: "depth=\(.depth)  \(.path | map("#\(.)") | join(" → "))  (issues: \(.issues), open: \(.open))";
      ([.trees[] | select(.depth >= $min)] | sort_by([-.depth, .root])) as $deep
      | "# ADLC follow-up chains — depth >= \($min) (\($n) issues read; one line per root issue: its longest path; issues = the issues in the chain, the root included)",
        ($deep[] | select(.decided | not) | line),
        (if ([$deep[] | select(.decided | not)] | length) == 0 then "no undecided chain of depth >= \($min)" else empty end),
        ($deep[] | select(.decided) | "decided  " + line + "  root carries adlc:accepted-risk"),
        "# Each depth= line is a decision for the Principal: accept the risk (label the root adlc:accepted-risk) or redesign (one issue that replaces the approach). Not another follow-up."'
    ;;
  root)
    printf '%s' "$graph" | jq -er --arg n "$arg" '
      .of[$n | tonumber | tostring] as $root
      | if $root == null then empty
        else (.trees[] | select(.root == $root) | "root=#\(.root) depth=\(.depth) \(if .decided then "accepted-risk" else "open" end)") end' \
      || { echo "adlc-chains: #${arg} is not among the ${read_n} issues read (a pull request, a number that does not exist, or an issue older than the newest ${LIMIT}: ADLC_CHAINS_LIMIT)" >&2; exit 1; }
    ;;
esac
