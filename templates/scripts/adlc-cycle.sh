#!/usr/bin/env bash
# Cycle time per issue and per stage, from the GitHub label timeline — the deterministic record of
# when each stage started and ended (the lanes and the Principal move the `stage:*` / `gate:*`
# labels; nobody types these numbers in). Feeds the `cycle-retro` skill with the `runs.jsonl`
# ledger from adlc-run-log.sh. Requires: gh authenticated, jq.
#
#   adlc-cycle.sh issues [DAYS]   one JSONL row per issue created in the window (default 30 days):
#       {"issue","title","created","closed","lane":"full|fast","pr","pr_opened",
#        "intake_to_pr_seconds","rounds","dwell":{"stage:intake":s,…},"stage_seconds","gate_seconds"}
#       dwell = seconds the issue wore each label (open intervals run to the issue's close, or now);
#       stage_seconds = time in stage:* labels — queue time AND agent time (an issue can sit at
#       stage:intake for days before the Analyst runs; the agent's own minutes are in runs.jsonl);
#       gate_seconds = time in gate:* labels (waiting on the Principal); rounds = the
#       `adlc:changes-requested` labels put on the linked PR (fix rounds); pr = the first PR that
#       references the issue; intake_to_pr = first stage:intake → that PR (null when no intake label
#       precedes the PR, e.g. an issue filed from a PR).
#   adlc-cycle.sh report [DAYS]   the ranked tables the retro reads, from .adlc/metrics/runs.jsonl
#       and .adlc/metrics/cycle.jsonl (materialize both first; see the skill). Window filters rows.
#
# Cost: one `gh issue list` + one timeline call per issue (+ one per linked PR). Materialize into
# .adlc/metrics/cycle.jsonl the way the finding ledger is, never commit it from CI. An issue whose
# timeline cannot be read (deleted, transferred, rate-limited) is skipped with a line on stderr and
# the run goes on; a PR whose timeline fails gives rounds: null. Only cross-references from THIS
# repo count as the issue's PR (a host repo's issues also cite the plugin repo's PRs).
set -euo pipefail
cmd="${1:-}"; days="${2:-30}"
SINCE=$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ)
M="${CLAUDE_PROJECT_DIR:-.}/.adlc/metrics"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

timeline() { gh api "repos/{owner}/{repo}/issues/$1/timeline?per_page=100" --paginate --jq '.[]' | jq -sc .; }
# A cross-referenced event's source repo, lower-cased, in either shape GitHub sends.
XREF_REPO='((.source.issue.repository.full_name // (.source.issue.repository_url // "" | sub(".*/repos/"; ""))) | ascii_downcase)'


case "$cmd" in
  issues)
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner | tr 'A-Z' 'a-z')"
    [ -n "$REPO" ] || { echo "adlc-cycle: cannot tell this repo's owner/name (gh repo view)" >&2; exit 2; }
    gh issue list --state all --limit 200 --json number,title,createdAt,closedAt,labels \
      --jq "[.[] | select(.createdAt >= \"$SINCE\")] | sort_by(.number)[] | @json" \
    | while IFS= read -r issue; do
        n="$(printf '%s' "$issue" | jq -r .number)"
        tl="$(timeline "$n")" || { echo "adlc-cycle: could not read the timeline of #$n; skipped" >&2; continue; }
        pr="$(printf '%s' "$tl" | jq -r --arg repo "$REPO" "[.[] | select(.event == \"cross-referenced\" and .source.issue.pull_request != null and $XREF_REPO == \$repo)] | sort_by(.created_at) | first | .source.issue.number // empty")"
        rounds=0
        if [ -n "$pr" ]; then
          rounds="$(timeline "$pr" | jq '[.[] | select(.event == "labeled" and .label.name == "adlc:changes-requested")] | length')" \
            || { echo "adlc-cycle: could not read the timeline of PR #$pr (issue #$n); rounds unknown" >&2; rounds=null; }
        fi
        printf '%s' "$tl" | jq -c --argjson issue "$issue" --arg now "$NOW" --arg pr "${pr:-}" --argjson rounds "$rounds" --arg repo "$REPO" '
          def t: fromdate;
          ($issue.closedAt // $now | t) as $end
          | [.[] | select(.event == "labeled" or .event == "unlabeled")
                 | select(.label.name | test("^(stage|gate):"))
                 | {e: .event, l: .label.name, t: (.created_at | t)}] as $ev
          | ($ev | map(.l) | unique) as $labels
          # dwell per label: each labeled→next unlabeled interval; an open interval runs to $end, and one
          # that opens after $end (a label put on a closed issue) counts 0, never negative.
          | ($labels | map({(.): (. as $l | [$ev[] | select(.l == $l)] | sort_by(.t)
                | reduce .[] as $x ({open: null, sum: 0};
                    if $x.e == "labeled" then (if .open == null then .open = $x.t else . end)
                    else (if .open != null then .sum += ($x.t - .open) | .open = null else . end) end)
                | .sum + (if .open != null then ([$end - .open, 0] | max) else 0 end))}) | add // {}) as $dwell
          | ([$ev[] | select(.e == "labeled" and .l == "stage:intake")] | sort_by(.t) | first | .t) as $intake
          | ([.[] | select(.event == "cross-referenced" and .source.issue.pull_request != null and '"$XREF_REPO"' == $repo)] | sort_by(.created_at) | first | .created_at) as $pr_opened
          | {issue: $issue.number, title: $issue.title, created: $issue.createdAt, closed: $issue.closedAt,
             lane: (if $labels | index("stage:fast") then "fast" else "full" end),
             pr: (if $pr == "" then null else ($pr | tonumber) end), pr_opened: $pr_opened,
             intake_to_pr_seconds: (if $intake != null and $pr_opened != null and ($pr_opened | t) >= $intake then (($pr_opened | t) - $intake) else null end),
             rounds: $rounds, dwell: $dwell,
             stage_seconds: ([$dwell | to_entries[] | select(.key | startswith("stage:")) | .value] | add // 0),
             gate_seconds:  ([$dwell | to_entries[] | select(.key | startswith("gate:"))  | .value] | add // 0)}'
      done
    ;;

  report)
    runs="$M/runs.jsonl"; cyc="$M/cycle.jsonl"
    echo "# ADLC cycle report — last ${days}d (since ${SINCE})"
    if [ -s "$runs" ]; then
      echo
      echo "## Spend and latency per stage (runs.jsonl; agent runs — tokens/usd only where telemetry was on)"
      jq -rs --arg since "$SINCE" '
        [.[] | select(.ts >= $since and .source != "actions")] as $r
        | ($r | map(.cost_usd // 0) | add // 0) as $usd
        | ($r | map(.seconds // 0) | add // 0) as $sec
        | "stage        runs  with_telemetry      usd  usd_share   avg_sec  sec_share  cached%_of_prompt",
          ($r | group_by(.stage) | map(
             (map(.cost_usd // 0) | add) as $u | (map(.seconds // 0) | add) as $s
             | [.[] | select((.tokens // 0) > 0)] as $tel
             | {stage: (.[0].stage // "unknown"), n: length, tel: ($tel | length), usd: $u,
                share: (if $usd > 0 then 100 * $u / $usd else 0 end),
                avg: (if length > 0 then $s / length else 0 end),
                sshare: (if $sec > 0 then 100 * $s / $sec else 0 end),
                rd: (($tel | map(.input + .cache_read + .cache_creation) | add // 0) as $den | if $den > 0 then 100 * ($tel | map(.cache_read) | add) / $den else null end)})
             | sort_by(-.usd)[]
             | "\(.stage|.[0:12]|. + " " * (12 - length))  \(.n|tostring|" " * (4 - length) + .)  \(.tel|tostring|" " * (14 - length) + .)  \(.usd*100|round/100|tostring|" " * (7 - length) + .)  \(.share|round|tostring|" " * (8 - length) + .)%  \(.avg|round|tostring|" " * (8 - length) + .)  \(.sshare|round|tostring|" " * (8 - length) + .)%  \(if .rd == null then "-" else (.rd|round|tostring) + "%" end)"),
          "TOTAL        \($r|length)  usd=\($usd*100|round/100)  agent_hours=\($sec/3600*10|round/10)"' "$runs"
      echo
      echo "## GitHub Actions lanes (runs.jsonl; agent lanes and guard lanes alike): avg seconds and failures"
      jq -rs --arg since "$SINCE" '
        [.[] | select(.ts >= $since and .source == "actions")]
        | group_by(.stage)[] | (map(.seconds) | add / length) as $avg
        | "\(.[0].stage): runs=\(length) avg_sec=\($avg|round) failed=\([.[] | select(.conclusion == "failure")] | length)"' "$runs"
    else
      echo "runs.jsonl: empty or missing — materialize it with adlc-run-log.sh (mc | otel | actions) first"
    fi
    if [ -s "$cyc" ]; then
      echo
      echo "## Cycle time per issue (cycle.jsonl; label timeline)"
      jq -rs --arg since "$SINCE" '
        [.[] | select(.created >= $since)] as $c
        | def h: if . == null then "-" else (. / 3600 * 10 | round / 10 | tostring) + "h" end;
          "issue  lane  rounds  intake→PR   stage_time  gate_wait  pr",
          ($c | sort_by(.issue)[] | "\(.issue|tostring|" " * (5 - length) + .)  \(.lane|.[0:4]|. + " " * (4 - length))  \(.rounds|tostring|" " * (6 - length) + .)  \(.intake_to_pr_seconds|h|" " * (9 - length) + .)   \(.stage_seconds|h|" " * (10 - length) + .)  \(.gate_seconds|h|" " * (9 - length) + .)  \(.pr // "-")"),
          "",
          "issues=\($c|length)  with_pr=\([$c[] | select(.pr != null)] | length)  fast_lane=\([$c[] | select(.lane == "fast")] | length)",
          "median intake→PR: \([$c[] | .intake_to_pr_seconds | select(. != null)] | sort | if length == 0 then null else .[length/2|floor] end | h)",
          "rounds: total=\($c | map(.rounds) | add // 0)  issues_with_a_fix_round=\([$c[] | select(.rounds > 0)] | length)",
          "time split: in a stage label=\($c | map(.stage_seconds) | add // 0 | h)  at a gate=\($c | map(.gate_seconds) | add // 0 | h)   (stage time = queue + agent; the agents'"'"' own minutes are the runs.jsonl table)",
          "dwell per stage (sum): \([$c[] | .dwell | to_entries[]] | group_by(.key) | map("\(.[0].key)=\(map(.value) | add | h)") | join("  "))"' "$cyc"
    else
      echo
      echo "cycle.jsonl: empty or missing — materialize it with adlc-cycle.sh issues [DAYS] first"
    fi
    echo
    echo "# Feed this to the cycle-retro skill: rank stage × cost × wall time × rounds, propose the cheapest pipeline-shape fix."
    ;;

  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
