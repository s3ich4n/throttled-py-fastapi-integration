# fastapi-throttled-py-integration

A project that visualizes the 5 rate limiting algorithms of the [throttled-py](https://github.com/ZhuoZhuoCrayon/throttled-py) library using FastAPI + OTel + Grafana. Supports both synchronous (sync) and asynchronous (async) modes.

## Architecture

```
┌─────────────────────────┐
│  FastAPI (app.py)       │
│  /sync/{algorithm}/pay  │    OTLP/gRPC    ┌────────────────┐   remote write  ┌────────────┐
│  /async/{algorithm}/pay │ ──────────────→ │ OTel Collector │ ──────────────→ │ Prometheus │
│  :8000 (Docker)         │   :4317         └────────────────┘                 └─────┬──────┘
└─────────────────────────┘                                                          │
                                                                                     │ query
                                                                               ┌─────▼──────┐
                                                                               │  Grafana   │
                                                                               │  :3000     │
                                                                               └────────────┘
```

### App Structure

A single FastAPI app (`app.py`) serves 5 algorithms × 2 modes = 10 endpoints.

| Endpoint | Description |
|----------|-------------|
| `POST /sync/{algorithm}/pay` | Sync rate limit check (`Throttled` + `OTelHook`) |
| `POST /async/{algorithm}/pay` | Async rate limit check (`AsyncThrottled` + `AsyncOTelHook`) |

`{algorithm}`: `token_bucket`, `fixed_window`, `sliding_window`, `leaking_bucket`, `gcra`

All endpoints use the same configuration (`per_min(500)`, in-memory store) and only differ in the `using` parameter.

### Collected Metrics

| Prometheus Name | Type | Labels | Description |
|-----------------|------|--------|-------------|
| `throttled_requests_total` | Counter | `result`, `algorithm`, `key`, `store_type` | Number of rate limit checks |
| `throttled_duration_seconds_*` | Histogram | (same) | Duration of rate limit checks |

The Grafana dashboard uses a `mode` (sync/async) dropdown and repeats rows by `algorithm` label, automatically generating per-mode and per-algorithm sections.

## How to Test

### Prerequisites

```bash
# Start the full stack (app + OTel Collector + Prometheus + Grafana)
make up

# Or build first
make build && make up
```

### Single Algorithm Test

```bash
# sync mode (default)
make run-token-bucket

# async mode
make run-token-bucket MODE=async

# Check Grafana
#   http://localhost:3000 → Dashboards → Throttled Rate Limit
#   Switch sync/async using the mode dropdown at the top
```

### Run All Algorithms in Parallel

Run all 5 algorithms simultaneously for comparison:

```bash
# All in sync mode
make run-all-sync

# All in async mode
make run-all-async

# All in default mode (sync)
make run-all
```

All 5 algorithm scenarios run concurrently on a single FastAPI app (port 8000). Metrics are distinguished by the `key` label (`/sync/...` or `/async/...`) and filtered by mode in Grafana.

### Scenario (5 minutes)

| Phase | Time | Traffic | Expected Result |
|-------|------|---------|-----------------|
| 1. Normal | 0:00 - 1:00 | 3 req/s (180/min) | All allowed |
| 2. Ramp up | 1:00 - 2:30 | 8 req/s (480/min) | Allowed (near limit) |
| 3. Burst | 2:30 - 4:00 | 20 req/s (1200/min) | Allowed/denied interleaved |
| 4. Cool down | 4:00 - 5:00 | 3 req/s (180/min) | Immediate recovery |

### Cleanup

```bash
make down
```

### Running the Scenario Script Directly

```bash
# bash scenario.sh <algorithm> [sync|async]
bash scenario.sh token_bucket async
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make build` | Build Docker image |
| `make up` | Start the full stack (docker compose, nohup with timestamped log) |
| `make down` | Stop the full stack |
| `make run-{algorithm}` | Start + run scenario (`MODE=async` supported) |
| `make run-all` | Run all algorithms in parallel (default: sync) |
| `make run-all-sync` | Run all algorithms in parallel (sync) |
| `make run-all-async` | Run all algorithms in parallel (async) |
| `make scenario-{algorithm}` | Run scenario only (app must be running) |
| `make logs` | View app logs |
| `make logs-{service}` | View infrastructure service logs |

`{algorithm}`: `token_bucket`, `fixed_window`, `sliding_window`, `leaking_bucket`, `gcra`

## Documentation

### Metrics & Dashboard

- [OTel Metric Verification](docs/metric.md) — Metric structure, Grafana panels, histogram bucket calibration
- [Test Scenario](docs/scenario.md) — Scenario configuration and observation points

### Algorithm Internals

Each document explains how the algorithm works, its behavior under each scenario phase, and its relationship to the collected metrics.

- [Token Bucket](docs/metric_explanation_token_bucket.md) — Token replenishment/deduction model, graceful degradation interleave pattern
- [Fixed Window](docs/metric_explanation_fixed_window.md) — Counter-based, vulnerable to 2x burst at window boundaries
- [Sliding Window](docs/metric_explanation_sliding_window.md) — Weighted average of previous/current windows, most accurate limiting
- [Leaking Bucket](docs/metric_explanation_leaking_bucket.md) — Inverted Token Bucket model, identical metric results
- [GCRA](docs/metric_explanation_gcra.md) — Tracks a single TAT, minimal state, most uniform allow pattern

### Algorithm Comparison

| Property | Token Bucket | Fixed Window | Sliding Window | Leaking Bucket | GCRA |
|----------|-------------|--------------|----------------|---------------|------|
| State Size | 2 fields | 1 counter | 2 counters | 2 fields | 1 timestamp |
| Burst Pattern | Interleaved | Full block | Gradual block | Interleaved | Uniform interleave |
| Window Boundary Issue | None | 2x burst | None | None | None |
| Allow Uniformity | Medium | Low | Medium | Medium | Most uniform |
| Implementation Complexity | Medium | Simplest | High | Medium | Medium |
