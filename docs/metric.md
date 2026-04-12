# throttled-py OTel Metric Verification

## Preparation

### Components

| Service | Role |
|---------|------|
| FastAPI (`app.py`) | App with throttled-py + OTelHook/AsyncOTelHook applied (Docker) |
| OTel Collector | Receives OTLP → Prometheus remote write |
| Prometheus | Metric storage |
| Grafana | Dashboard visualization |

### Metrics Recorded by OTelHook / AsyncOTelHook

Both sync (`OTelHook`) and async (`AsyncOTelHook`) record the same metrics. They are distinguished by the `key` label (`/sync/...` vs `/async/...`).

| OTel Name | Prometheus Conversion | Type | Description |
|-----------|----------------------|------|-------------|
| `throttled.requests` | `throttled_requests_total` | Counter | Number of rate limit checks (label: `result=allowed\|denied`) |
| `throttled.duration` | `throttled_duration_seconds_*` | Histogram | Time taken for rate limit checks |

### Histogram Bucket Boundary Correction

In OpenTelemetry SDK 1.39.1, the default histogram bucket boundaries are large for a latency metric recorded in seconds (`0, 5, 10, 25, ...` seconds).
Since in-memory rate-limit checks are on the microsecond scale, all samples fall into the first bucket, causing `histogram_quantile` to return meaningless values (e.g., p50 around 2.5s).

This is resolved by specifying microsecond-scale boundaries using an `ExplicitBucketHistogramAggregation` View:

```python
from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View

duration_view = View(
    instrument_name="throttled.duration",
    aggregation=ExplicitBucketHistogramAggregation(
        boundaries=[
            0.000005,   # 5μs
            0.00001,    # 10μs
            0.000025,   # 25μs
            0.00005,    # 50μs
            0.0001,     # 100μs
            0.00025,    # 250μs
            0.0005,     # 500μs
            0.001,      # 1ms
            0.005,      # 5ms
            0.01,       # 10ms
        ]
    ),
)
```

## Grafana Dashboard

A `mode` (sync/async) dropdown is available at the top of the dashboard, and all queries have the `key=~"/${mode}/.*"` filter applied.

### Panel Configuration

#### 1. Requests / sec (allowed vs denied)

```promql
rate(throttled_requests_total{result="allowed", algorithm="$algorithm", key=~"/${mode}/.*"}[1m])
rate(throttled_requests_total{result="denied", algorithm="$algorithm", key=~"/${mode}/.*"}[1m])
```

#### 2. Denied ratio

```promql
sum(throttled_requests_total{result="denied", algorithm="$algorithm", key=~"/${mode}/.*"})
  / clamp_min(sum(throttled_requests_total{algorithm="$algorithm", key=~"/${mode}/.*"}), 1)
```

#### 3. Total requests

```promql
throttled_requests_total{algorithm="$algorithm", key=~"/${mode}/.*"}
```

#### 4. Rate limit check latency (p50 / p95 / p99)

```promql
histogram_quantile(0.50, sum by (le) (rate(throttled_duration_seconds_bucket{algorithm="$algorithm", key=~"/${mode}/.*"}[1m])))
histogram_quantile(0.95, sum by (le) (rate(throttled_duration_seconds_bucket{algorithm="$algorithm", key=~"/${mode}/.*"}[1m])))
histogram_quantile(0.99, sum by (le) (rate(throttled_duration_seconds_bucket{algorithm="$algorithm", key=~"/${mode}/.*"}[1m])))
```

`sum by (le)` aggregates the `result` label (allowed/denied) into a single series.

## Results

Configuration: `per_min(500)`, in-memory store. The scenario was run against each algorithm for 5 minutes, but the numbers below should be treated as a rough observation rather than a precise benchmark. The goal is to confirm that the limiter and metrics pipeline behave as expected and to compare the broad algorithm patterns.

### Scenario (5 minutes)

| Phase | Time | Traffic | Result |
|-------|------|---------|--------|
| 1. Normal | 0:00 - 1:00 | 3 req/s (180/min) | All allowed |
| 2. Ramp up | 1:00 - 2:30 | 8 req/s (480/min) | All allowed (near limit) |
| 3. Burst | 2:30 - 4:00 | 20 req/s (1200/min) | Mixed allowed/denied after available capacity is exhausted |
| 4. Cool down | 4:00 - 5:00 | 3 req/s (180/min) | Immediate recovery, all allowed |

### Measurement Results

| Metric | Value |
|--------|-------|
| Total allowed | 2,430 |
| Total denied | 450 |
| Denied ratio | 15.6% |
| Latency p50 | ~20μs |
| Latency p95 | ~35μs |
| Latency p99 | ~50μs |

### Analysis

- **Rate limiter behavior**: During the burst phase, the token bucket still allows some traffic as tokens refill. In `throttled-py` 3.2.0 this refill is based on whole-second timestamps, so the allowed/denied pattern can appear in coarse batches rather than at a perfectly even 0.12s cadence.
- **Denied ratio interpretation**: The cumulative denied ratio is 15.6%. With the measured 450 denials over the 90-second burst phase (1,800 requests), the phase-wide burst denial rate is 25%; after the initial bucket capacity is exhausted, the instantaneous denial rate moves toward roughly `(20 - 8.33) / 20 ≈ 58%`. For operational alerting, a separate instantaneous denial rate based on `rate()` should be configured.
- **Latency overhead**: With an in-memory store, p99 is ~50μs. Compared to business logic, this overhead is less than 0.01% and can be considered negligible. When switching to Redis, latency may increase to the millisecond range, making latency monitoring significantly more important.
