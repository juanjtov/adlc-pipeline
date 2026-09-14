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

## How it fits the pipeline
- **Latency** needs none of this — `.adlc/scripts/adlc-cost.sh` derives per-lane and per-pipeline
  wall-clock from GitHub Actions run durations. Use the collector for **token + cost**, which only
  Claude Code knows.
- The `retro` can read the rolled-up cost the same way it reads other metrics, to spot which
  stage/agent dominates spend (e.g. an opus-vs-fable decision).

## Stop / reset
```bash
docker compose down          # stop
rm -f data/telemetry.jsonl   # reset the captured data
```
