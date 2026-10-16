#!/usr/bin/env bash
# Run ledger — one JSONL row per agent run, from DETERMINISTIC sources only (never an agent's own
# report of what it spent). The `cycle-retro` skill ranks these rows to find where a pipeline run's
# time and money go. Like the finding ledger, the file is MATERIALIZED on demand, not committed from CI:
#
#   : > .adlc/metrics/runs.jsonl
#   adlc-run-log.sh mc                              >> .adlc/metrics/runs.jsonl   # local agent runs
#   adlc-run-log.sh otel telemetry/data/telemetry.jsonl >> .adlc/metrics/runs.jsonl   # or the collector
#   adlc-run-log.sh actions 30                      >> .adlc/metrics/runs.jsonl   # the Actions lanes
#
# Sources:
#   mc [DAYS]        Mission Control's SQLite store (~/.adlc/mission-control/mc.sqlite, or $ADLC_MC_DB):
#                    one row per pipeline-agent run, tokens/cost/latency summed from the api_request
#                    events Claude Code exported over OpenTelemetry. Needs sqlite3. Only runs of THIS
#                    repo (git remote origin, as owner/name; or $ADLC_REPO).
#   otel <file>      The OTel collector's file export (OTLP/JSON logs, one batch per line): the same
#                    api_request events, grouped by session.id (one agent) + agent.name. Needs jq.
#                    Runs it cannot attribute to a pipeline agent ('custom' or unnamed) are kept with
#                    agent "unknown" — set OTEL_LOG_TOOL_DETAILS=1 so Claude Code names the agent.
#   actions [DAYS]   GitHub Actions lane durations (gh run list): latency per lane with no token data.
#                    Lane name -> stage by the template's exact workflow name ("ADLC Builder" ->
#                    builder, "ADLC review" -> reviewer …); other workflows keep their own name
#                    as a slug (adlc-ci, adlc-diff-scope …).
#
# Row: {"ts","source","repo","issue","pr","stage","agent","run_id","seconds","input","output",
#       "cache_read","cache_creation","tokens","cache_read_pct","cost_usd","model"}
# tokens = input + output + cache_read + cache_creation (what the account was billed for, at
# differing rates); cache_read_pct = cache_read / (input + cache_read + cache_creation), the share
# of the prompt that was served from cache rather than sent (uncached input) or written (cache
# creation, billed above input price). NB adlc-cache.sh's read% leaves cache writes out of its
# denominator, so it reads higher on the same run. Nulls where a source does not know a field.
set -euo pipefail
src="${1:-}"; shift || true
[ -n "$src" ] || { sed -n '2,30p' "$0"; exit 2; }

# This repo as owner/name, lower-cased ($ADLC_REPO, else git remote origin). Every source needs it:
# the store holds several repos' runs, and a row must say whose it is. Exit 2 when it cannot be
# told or is not a GitHub-shaped name (it is spliced into the mc query, so it is checked first).
repo_name() {
  local url repo
  if [ -n "${ADLC_REPO:-}" ]; then repo="$(printf '%s' "$ADLC_REPO" | tr 'A-Z' 'a-z')"
  else
    url="$(git remote get-url origin 2>/dev/null || true)"; url="${url%/}"; url="${url%.git}"
    # git@host:owner/name · https://host/owner/name · ssh://git@host/owner/name → owner/name
    repo="$(printf '%s' "$url" | sed -E 's#^[a-z+]+://[^/]+/##; s#^[^@/]+@[^:]+:##; s#^/##' | awk -F/ 'NF>=2 {print tolower($(NF-1)"/"$NF)}')"
  fi
  [ -n "$repo" ] || { echo "adlc-run-log: cannot tell this repo's owner/name (no git remote origin; set ADLC_REPO)" >&2; exit 2; }
  printf '%s' "$repo" | grep -Eq '^[a-z0-9._-]+/[a-z0-9._-]+$' || { echo "adlc-run-log: '$repo' is not an owner/name" >&2; exit 2; }
  printf '%s' "$repo"
}

# One stage vocabulary across sources — Mission Control's stations (analyst · architect · builder ·
# reviewer · qa), plus the lanes that are not one agent's: fix (the Builder's fix round), fast,
# retro. A workflow is mapped by its exact template name (templates/github/*.yml `name:`), so a host
# repo's own "ADLC …" workflow is not mistaken for a lane; anything else keeps its own name as a
# slug (adlc-ci, adlc-diff-scope, adlc-main-tripwire, …).
LANE_STAGE_JQ='def lane_stage: (ascii_downcase) as $n
  | {"adlc intake (auto-start)": "analyst", "adlc design": "architect", "adlc builder": "builder",
     "adlc review": "reviewer", "adlc qa": "qa", "adlc fix loop": "fix", "adlc fast lane": "fast",
     "adlc retro": "retro"}[$n] // ($n | gsub("[^a-z0-9]+"; "-") | sub("^-"; "") | sub("-$"; ""));'
# The issue a lane branch names — the rule of adlc-branch-issue.sh (feat/12-add-login → 12, feat/012 → 12,
# main → null), kept in step by a test there.
BRANCH_ISSUE_JQ='def branch_issue: capture("^[^/]*/0*(?<n>[0-9]+)(-.*)?$") | .n | tonumber;'

case "$src" in
  mc)
    days="${1:-30}"
    db="${ADLC_MC_DB:-$HOME/.adlc/mission-control/mc.sqlite}"
    command -v sqlite3 >/dev/null 2>&1 || { echo "adlc-run-log: sqlite3 not found" >&2; exit 2; }
    [ -f "$db" ] || { echo "adlc-run-log: no Mission Control store at $db (start /adlc-mission-control, or set ADLC_MC_DB)" >&2; exit 2; }
    repo="$(repo_name)"
    since=$(( $(date -u +%s) - days * 86400 ))
    # A run is one pipeline-agent session (or subagent); its api_request events carry the spend.
    # Latency = the run's own started→ended when known, else the span of its api events.
    sqlite3 -json "$db" "
      SELECT r.id AS run_id, r.station AS stage, r.agent_type AS agent, r.issue, r.pr, r.repo, r.model AS run_model,
             r.started, r.ended,
             MIN(a.ts) AS first_ts, MAX(a.ts) AS last_ts,
             SUM(COALESCE(a.input,0)) AS input, SUM(COALESCE(a.output,0)) AS output,
             SUM(COALESCE(a.cache_read,0)) AS cache_read, SUM(COALESCE(a.cache_creation,0)) AS cache_creation,
             SUM(COALESCE(a.cost,0)) AS cost, MAX(a.model) AS api_model
      FROM runs r LEFT JOIN api a ON a.run = r.id
      WHERE lower(r.repo) = '$repo' AND r.station IS NOT NULL AND r.started >= $since
      GROUP BY r.id ORDER BY r.started" \
    | jq -c --arg repo "$repo" '.[]
        | (.started // .first_ts) as $t0
        | (.ended // .last_ts) as $t1
        | (.agent | if . == null then null else (split(":") | last) end) as $agent
        | {ts: ($t0 | if . == null then null else (floor | todate) end), source: "mc", repo: $repo,
           issue: .issue, pr: .pr, stage: .stage, agent: $agent, run_id: .run_id,
           seconds: (if $t0 == null or $t1 == null then null else (($t1 - $t0) | floor) end),
           input: .input, output: .output, cache_read: .cache_read, cache_creation: .cache_creation,
           tokens: (.input + .output + .cache_read + .cache_creation),
           cache_read_pct: (if (.input + .cache_read + .cache_creation) > 0 then ((100 * .cache_read / (.input + .cache_read + .cache_creation)) * 10 | round / 10) else null end),
           cost_usd: ((.cost * 100 | round) / 100), model: (.run_model // .api_model)}'
    ;;

  otel)
    file="${1:-}"
    [ -n "$file" ] && [ -f "$file" ] || { echo "adlc-run-log: otel needs the collector's JSONL file (telemetry/data/telemetry.jsonl)" >&2; exit 2; }
    repo="$(repo_name)"
    # OTLP/JSON: resourceLogs[].scopeLogs[].logRecords[]; attributes are [{key, value:{stringValue|intValue|doubleValue}}].
    # Keep api_request events; group by session.id + agent.name; sum tokens/cost; latency = event span.
    jq -c --arg repo "$repo" '
      def val: if type == "object" then (.stringValue // .intValue // .doubleValue // .boolValue // (.arrayValue|tostring?) // null) else . end;
      def attrs: (. // []) | map({(.key): (.value | val)}) | add // {};
      def num: if . == null then 0 else (tonumber? // 0) end;
      [ .resourceLogs[]? as $rl
        | ($rl.resource.attributes | attrs) as $base
        | $rl.scopeLogs[]?.logRecords[]?
        | ($base + (.attributes | attrs)) as $a
        | select((($a["event.name"] // (.body | val) // "") | tostring) | endswith("api_request"))
        | {ts: ((.timeUnixNano // .observedTimeUnixNano) | num / 1e9),
           session: ($a["session.id"] // "unknown"), agent: ($a["agent.name"] // null), model: $a.model,
           input: ($a.input_tokens | num), output: ($a.output_tokens | num),
           cache_read: ($a.cache_read_tokens | num), cache_creation: ($a.cache_creation_tokens | num),
           cost: ($a.cost_usd | num), ms: ($a.duration_ms | num)} ]' "$file" \
    | jq -sc --arg repo "$repo" '
      add // [] | group_by([.session, .agent]) | .[]
      | (map(.ts) | min) as $t0 | (map(.ts) | max) as $t1
      | (.[0].agent | if . == null or . == "custom" then "unknown" else (split(":") | last) end) as $agent
      | (map(.input) | add) as $in | (map(.cache_read) | add) as $rd | (map(.cache_creation) | add) as $wr
      | {ts: ($t0 | floor | todate), source: "otel", repo: $repo, issue: null, pr: null,
         stage: ({"product-analyst":"analyst","architect":"architect","builder":"builder","adversarial-reviewer":"reviewer","qa-release-ops":"qa"}[$agent] // null),
         agent: $agent, run_id: (.[0].session + (if .[0].agent then ":" + .[0].agent else "" end)),
         seconds: (($t1 - $t0) | floor), input: $in, output: (map(.output) | add), cache_read: $rd,
         cache_creation: $wr,
         tokens: ($in + (map(.output) | add) + $rd + $wr),
         cache_read_pct: (if ($in + $rd + $wr) > 0 then ((100 * $rd / ($in + $rd + $wr)) * 10 | round / 10) else null end),
         cost_usd: (((map(.cost) | add) * 100 | round) / 100), model: (map(.model) | map(select(. != null)) | first)}'
    ;;

  actions)
    days="${1:-30}"
    repo="$(repo_name)"
    since=$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ)
    # An issue number comes from the head branch, so only PR-triggered lanes (review, fix, CI,
    # diff-scope, fast) carry one; the issue-triggered lanes run on the default branch → null.
    gh run list --limit 500 --json databaseId,workflowName,headBranch,status,conclusion,startedAt,updatedAt \
      --jq "[.[] | select(.status == \"completed\" and .startedAt >= \"$since\")]" \
    | jq -c --arg repo "$repo" "$LANE_STAGE_JQ $BRANCH_ISSUE_JQ"'
        .[] | select(.workflowName | test("ADLC"; "i"))
        | {ts: .startedAt, source: "actions", repo: $repo, issue: ((.headBranch // "") | branch_issue? // null), pr: null,
           stage: (.workflowName | lane_stage), agent: null, run_id: ("actions:" + (.databaseId | tostring)),
           seconds: ((.updatedAt | fromdate) - (.startedAt | fromdate)),
           input: null, output: null, cache_read: null, cache_creation: null, tokens: null, cache_read_pct: null,
           cost_usd: null, model: null, lane: .workflowName, conclusion: .conclusion}'
    ;;

  *) echo "adlc-run-log: unknown source '$src' (mc | otel <file> | actions [DAYS])" >&2; exit 2 ;;
esac
