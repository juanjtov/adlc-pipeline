# ADLC telemetry — local OTel collector

Captures **token count, cost, and latency per agent / per pipeline run** by receiving what
Claude Code exports over OpenTelemetry. One collector serves all your repos.

## 1. Start the collector
```bash
cd telemetry && mkdir -p data && docker compose up -d
```
It listens on `localhost:4317` (OTLP gRPC) — the endpoint `settings.telemetry.json` points at.

## 2. Turn on export in the repo(s) you want measured
Merge `templates/settings.telemetry.json`'s `env` block into that repo's `.claude/settings.json`
(the bootstrap wizard offers this). New Claude Code sessions in that repo then export usage.
Set a distinct `service.name` per repo if you want to separate them.

## 3. See the numbers
- **Console:** `docker compose logs -f otel-collector` (the `debug` exporter prints each batch).
- **Durable/greppable:** `telemetry/data/telemetry.jsonl` (the `file` exporter). The metrics to
  look for are Claude Code's own — notably **`claude_code.token.usage`** (by `type`:
  input/output/cacheRead/cacheCreation) and **`claude_code.cost.usage`** (USD), plus session
  duration. Group by the resource attribute `service.name` (a pipeline run) or `session.id`
  (one agent). Exact metric names can shift by Claude Code version — the file/console output is
  the ground truth; grep it.
- **Charts (optional):** point Prometheus/Grafana at `localhost:8889/metrics`.

## Cache hit-rate (money saved)
The same `claude_code.token.usage` metric already tells you how well **prompt caching** is
working: a `cacheRead` token bills ~0.1× an uncached `input` token, so the share of input
served from cache is the discount you're getting. `.adlc/scripts/adlc-cache.sh` rolls it up.
Shape the JSONL into `<key> <input> <cacheRead> <cacheCreation>` (one line per `session.id` or
per `service.name`) and pipe it in:

```bash
# Sum claude_code.token.usage dataPoints by key + type, emit the 4 columns adlc-cache.sh wants.
# The exact JSON path shifts by collector/version — adjust to match your telemetry.jsonl.
jq -rn --stream 'inputs' telemetry/data/telemetry.jsonl 2>/dev/null | \
  # ...group input/cacheRead/cacheCreation per key... \
  .adlc/scripts/adlc-cache.sh
```

Output is a per-agent table with a `read%` column and a TOTAL; a `!` marks any lane that read
**0** from cache — a broken or cold prefix (see the `efficient-runs` skill for the fix). This is
the ground truth that caching is on: check it after any change to `CLAUDE.md`, the skills, or an
agent's tool set, since a cache regression is silent — requests still succeed, the bill is just
higher.

## How it fits the pipeline
- **Latency** needs none of this — `.adlc/scripts/adlc-cost.sh` derives per-lane and per-pipeline
  wall-clock from GitHub Actions run durations. Use the collector for **token + cost**, which only
  Claude Code knows.
- The `retro` can read the rolled-up cost the same way it reads other metrics, to spot which
  stage/agent dominates spend (e.g. an opus-vs-fable decision) — or a lane whose `read%` dropped.

## Stop / reset
```bash
docker compose down          # stop
rm -f data/telemetry.jsonl   # reset the captured data
```
