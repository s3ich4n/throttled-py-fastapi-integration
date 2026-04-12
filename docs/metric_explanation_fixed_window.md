# Fixed Window Algorithm and Metric Interpretation

## How Fixed Window Works

### Core Concept

Time is divided into fixed-size windows, and requests are counted within each window. If the limit is exceeded, requests are denied. When the window changes, the counter resets.

```
        window 0           window 1           window 2
   ┌──────────────────┬──────────────────┬──────────────────┐
   │  counter: 0→1→2  │  counter: 0→1    │  counter: 0      │
   │  limit: 5        │  limit: 5        │  limit: 5        │
   └──────────────────┴──────────────────┴──────────────────┘
   │←── period(60s) ──→│←── period(60s) ──→│

   window number = now // period
   Counter automatically resets on window transition (new key created)
```

### Decision Logic

```
Request arrives
  │
  ▼
① Calculate window key
  │  window_idx = now // period
  │  key = "{key}:period:{window_idx}"
  │
  ▼
② Increment counter (atomic)
  │  counter = INCRBY(key, cost)
  │  if counter == cost → first request, set TTL = period
  │
  ▼
③ Check limit
  │  counter > limit ?
  │
  ├── YES → limited = true  (denied)
  │         retry_after = period - (now % period)
  │
  └── NO  → limited = false (allowed)
            remaining = limit - counter
```

### Parameters

When configured with `per_min(500)`:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| limit | 500 | Maximum requests per window |
| period | 60 sec | Window size |
| cost | 1 (default) | Consumption per request |

### State

| Stored Field | Description |
|--------------|-------------|
| `counter` | Cumulative request count in the current window (single integer) |

| Derived Field | Calculation | Description |
|---------------|-------------|-------------|
| `remaining` | = max(0, limit - counter) | Remaining requests in the current window |
| `reset_after` | = period - (now % period) | Time remaining until the next window |
| `retry_after` | = reset_after (when denied) | Wait time until the next window |

Since the stored state is only **a single integer**, this is the simplest of all algorithms.

## Counter Changes Over Time

Counter flow by scenario, based on `per_min(500)`:

```
counter
500 ┤            ┃           ■■■■■■━━━━━━━━━━━━
    │            ┃          ■       ↑ limit reached
    │            ┃         ■        all denied after this
    │            ┃        ■
    │        ■■■■■■■■■■■■■
    │       ■    ┃
    │ ■■■■■■     ┃
    │■           ┃                    ■■■■■■■■■
  0 ┤━━━━━━━━━━━━╋━━━━━━━━━━━━━━━━━━━╋━━━━━━━━━
    │  Phase 1   ┃    Phase 2,3      ┃ Phase 4
    │            ┃                   ┃
    │       window reset         window reset
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### Window Boundary Problem: 2x Burst

A well-known weakness of Fixed Window. Up to 2x the limit can be allowed instantaneously at window boundaries.

```
       window A (last 1 second)      window B (first 1 second)
  ─────────────────────┃─────────────────────
           ...490 req  ┃  500 req...
                       ┃
              990 req allowed in this 2-second span
              (nearly 2x despite limit=500)
```

If 490 requests arrive at the end of window A and 500 at the beginning of window B, 990 requests pass through in 2 seconds. Although the limit is 500 per minute, this effectively allows ~495 requests per second momentarily.

### Phase 3 (Burst) Detail: Why Complete Blocking Occurs

At 20 req/s traffic (from window start):

```
Time   counter  Decision   Description
────────────────────────────────────────────
0.00      1    allowed    counter starts
0.05      2    allowed
...
24.95   500    allowed    limit reached
25.00   501    denied     exceeded → all blocked after this
25.05   502    denied
...
59.95  1200    denied     continuous denied until window ends
60.00     1    allowed    new window → counter reset
```

If the limit (500) is exhausted in 25 seconds, the remaining 35 seconds are **all denied**. Unlike the partial-throughput pattern of token bucket, a **complete blocking interval** occurs.

## Relationship with Metrics

### `throttled_requests_total` (Counter)

```
                    Complete blocking interval
                    ↓↓↓↓↓↓↓↓↓↓
allowed ████████████████████         ███████████████
denied                      █████████
        ──────────────────────────────────────── time
        Phase 1,2     Phase 3            Phase 4
        counter has    limit exhausted    new window
        headroom       → blocked

```

| Phase | Counter State | allowed rate | denied rate |
|-------|--------------|-------------|-------------|
| Normal (3 req/s) | ~180 (headroom) | 3/s | 0/s |
| Ramp up (8 req/s) | gradually increasing | 8/s | 0/s |
| Burst (20 req/s) | rapidly reaches 500 | early 20/s → 0/s | 0/s → 20/s |
| Cool down (3 req/s) | ~180 after reset | 3/s | 0/s |

Key difference from token bucket: in the burst phase, the **allowed→denied transition happens once**, followed by continuous blocking until the window resets.

### `throttled_duration_seconds` (Histogram)

The operation is just INCRBY + one comparison, making it simpler than token bucket.

```
latency
100μs ┤
      │
 50μs ┤ ──────── p99 ──────────────────────
      │
 35μs ┤ ──────── p95 ──────────────────────
      │
 20μs ┤ ──────── p50 ──────────────────────
      │
  0μs ┤
      ├──────────────────────────────────── time
```

O(1) operation. Since it only performs a counter increment and an integer comparison, it can be the fastest among all algorithms.

### Denied ratio (Gauge)

| Phase | Instantaneous Block Rate | Calculation |
|-------|--------------------------|-------------|
| Normal / Ramp up | 0% | counter has headroom |
| Burst early | 0% | still below limit |
| Burst late | 100% | limit exhausted → all blocked |
| Cool down | 0% | new window reset |

Unlike token bucket's saturated steady-state denial ratio of roughly ~58%, the burst late phase has **100% blocking**. The graph shows a step pattern where the block rate sharply alternates between 0% and 100%.

## Differences from Other Algorithms

| Characteristic | Fixed Window | Token Bucket | Sliding Window |
|----------------|-------------|--------------|----------------|
| Implementation complexity | Simplest (1 counter) | Moderate (2 fields) | High (2 windows) |
| Burst pattern | Concentrated allowance early in window → complete blocking late | Batched graceful degradation | Gradual throttling |
| Window boundary | Vulnerable to 2x burst | Not applicable | Resolved via weighted average |
| Accuracy | Inaccurate at boundaries | Accurate long-term average | Most accurate |
| Suitable use cases | Simple API quotas, when precision is not required | General purpose, when burst tolerance is needed | When precise rate limiting is required |
