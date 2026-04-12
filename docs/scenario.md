# Rate Limit Dashboard Scenario

rate limit: **500 req/min** (`per_min(500)`, ~8.3 req/s)

## Prerequisites

```bash
# Start the full stack
make up

# Grafana
open http://localhost:3000
# Dashboards → Throttled Rate Limit → Switch between sync/async using the mode dropdown at the top
```

## Scenario (5 min)

```bash
# Run individually (sync)
make run-token-bucket

# Run individually (async)
make run-token-bucket MODE=async

# All algorithms in parallel (sync)
make run-all-sync

# All algorithms in parallel (async)
make run-all-async

# Run the scenario script directly
bash scenario.sh token_bucket async
```

| Phase | Time | Rate | Expected |
|-------|------|------|----------|
| 1. Normal | 0:00 - 1:00 | ~3 req/s (180/min) | All allowed. Flat green line |
| 2. Ramp up | 1:00 - 2:30 | ~8 req/s (480/min) | Near the limit. Denied should usually remain at 0 |
| 3. Burst | 2:30 - 4:00 | ~20 req/s (1200/min) | Heavy overload. Red(denied) rises after available capacity is exhausted |
| 4. Cool down | 4:00 - 5:00 | ~3 req/s (180/min) | Recovery. Green returns, red disappears |

## What to Watch

- **Requests/sec** — Confirm the spike in red(denied) during Phase 3
- **Denied ratio** — Phase 1: 0% → Phase 3: rises after capacity is exhausted → Phase 4: 0%
- **Latency p50/p95/p99** — Observe latency changes during the burst phase
- **Total requests** — Cumulative count of allowed vs denied
