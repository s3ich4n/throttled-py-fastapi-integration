# Sliding Window Algorithm and Metric Interpretation

## How the Sliding Window Works

### Core Concept

The counters from the previous window and the current window are combined using a **weighted average**. The weight of the previous window is reduced proportionally to the elapsed time in the current window, solving the boundary problem of Fixed Window.

```
        Previous Window (prev)          Current Window (curr)
   ┌─────────────────────────┬─────────────────────────┐
   │  counter: 400           │  counter: 100           │
   └─────────────────────────┴─────────────────────────┘
                              │←── 40% elapsed ──→│

   Current ratio = 0.4    (at the 40% point of the window)
   Previous ratio = 0.6   (60% of the previous window is still valid)

   Weighted sum = floor(0.6 × 400) + 100 + cost
               = 240 + 100 + 1
               = 341

   341 ≤ 500 → allowed
```

### Decision Logic

```
Request arrives
  │
  ▼
① Retrieve window counters
  │  curr_key = "{key}:period:{now // period}"
  │  prev_key = "{key}:period:{now // period - 1}"
  │  current = GET(curr_key) or 0
  │  previous = GET(prev_key) or 0
  │
  ▼
② Weighted sum calculation
  │  elapsed_ratio = (now_ms % period_ms) / period_ms
  │  prev_weight = 1 - elapsed_ratio
  │  weighted_prev = floor(prev_weight × previous)
  │  used = weighted_prev + current + cost
  │
  ▼
③ Limit check
  │  used > limit ?
  │
  ├── YES → limited = true  (denied)
  │         Counter is NOT incremented
  │
  └── NO  → limited = false (allowed)
            INCRBY(curr_key, cost)
```

### Parameters

When configured with `per_min(500)`:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| limit | 500 | Maximum requests in the sliding window |
| period | 60 sec | Window size |
| cost | 1 (default) | Consumption per request |

### State

| Stored Field | Description |
|--------------|-------------|
| `current_counter` | Number of requests in the current window |
| `previous_counter` | Number of requests in the previous window |

| Derived Field | Calculation | Description |
|---------------|-------------|-------------|
| `remaining` | = max(0, limit - used) | Number of remaining allowed requests |
| `reset_after` | = period | Total length of the current window |
| `retry_after` | ≈ time until weighted previous-window usage decreases enough | Approximate wait time before the next request can fit within the weighted window |

Key point: **The counter is NOT incremented on denial**. Unlike Token Bucket and Fixed Window, denied requests do not change the state.

## How the Weighted Sum Changes Over Time

Based on `per_min(500)`:

```
used (weighted sum)
500 ┤                          ■■■━━━━━━━━━━━
    │                        ■■   ↑ limit
    │                      ■■     denial starts
    │                    ■■       (but counter unchanged)
    │          ■■■■■■■■■■
    │        ■■
    │ ■■■■■■■
    │■
  0 ┤──────────────────────────────────────────
    │  Phase 1     Phase 2      Phase 3
    │
    │  Weighted sum increases gradually
    │  No abrupt changes at window boundaries
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### How the Weighted Average Solves the Boundary Problem

The 2x burst problem of Fixed Window does not occur:

```
       Fixed Window:
       Late window A: 490 req    Early window B: 500 req
       ─────────────────────┃─────────────────────
       990 req allowed in 2 seconds (2x the limit!)

       Sliding Window:
       Late window A: 490 req    Early window B attempt
       ─────────────────────┃─────────────────────
       Right after B starts: used = floor(0.99 × 490) + 0 + 1 = 486
       486 ≤ 500 → allowed
       ...
       used = floor(0.99 × 490) + 14 + 1 = 500
       500 ≤ 500 → allowed
       used = floor(0.99 × 490) + 15 + 1 = 501
       501 > 500 → denied ← blocked at the 15th request
```

Since the previous window's weight decreases slowly, the previous traffic is still reflected even at the moment of crossing the boundary.

### Phase 3 (Burst) Detail: Why Gradual Throttling Occurs

At 20 req/s traffic, at the 30-second mark of the window (prev_weight=0.5):

```
Time   prev  curr  weighted_sum  decision  description
──────────────────────────────────────────────
0.00   200   201   301           allowed   weighted sum has headroom
0.05   200   202   302           allowed
...
0.00   200   299   399           allowed
0.00   200   300   400           allowed
...
0.00   200   399   499           allowed
0.00   200   400   500           allowed   limit reached
0.05   200   400   500+1         denied    exceeded
0.10   199   400   500           allowed   prev weight decreased → 1 allowed
0.15   199   401   501           denied    exceeded again
...
```

As the previous window's weight decreases over time, a pattern of **intermittently allowing a small number of requests** emerges. This is similar to the partial-throughput pattern of Token Bucket, but the mechanism is different.

## Relationship with Metrics

### `throttled_requests_total` (Counter)

```
                     Gradual throttling (intermittent allows)
                          ↓↓↓
allowed ████████████████████▓▓▓▓▓▓▓▓▓████████
denied                     ▓▓▓▓▓▓▓▓▓
        ──────────────────────────────────────── time
        Phase 1,2        Phase 3       Phase 4
        Weighted sum     Near limit     Weighted sum
        has headroom                    decreasing
```

| Phase | Weighted Sum | allowed rate | denied rate |
|-------|-------------|-------------|-------------|
| Normal (3 req/s) | ~180 (below limit) | 3/s | 0/s |
| Ramp up (8 req/s) | Gradual increase | 8/s | 0/s |
| Burst (20 req/s) | Oscillating near limit | ~8.33/s over time (the configured 500/min rate) | ~11.67/s after the limiter reaches saturation |
| Cool down (3 req/s) | Rapidly decreasing | 3/s | 0/s |

The allowed rate during the saturated part of the Burst phase converges to the configured limit rate similarly to Token Bucket, but for a different reason:
- Token bucket: Determined by the token replenishment rate, with whole-second batching in `throttled-py` 3.2.0
- Sliding window: Determined by the rate at which the previous window's weight decreases

### `throttled_duration_seconds` (Histogram)

Since it queries two keys and performs floating-point arithmetic (weighted average), it is slightly slower than Fixed Window which uses a simple counter.

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

It is still an O(1) operation, but the constant factor is larger due to the additional 2 GETs + floating-point multiplication.

### Denied ratio (Gauge)

| Phase | Instantaneous denial rate | Characteristics |
|-------|--------------------------|-----------------|
| Normal / Ramp up | 0% | Weighted sum has headroom |
| Burst steady state | ~58% | Similar saturated ratio to Token Bucket |
| Cool down | 0% | Weighted sum decreases rapidly |

Instead of the 0%/100% step pattern of Fixed Window, a **smooth curve** appears. As the previous window's weight decreases gradually, the denial rate also changes gradually.

## Differences from Other Algorithms

| Property | Sliding Window | Fixed Window | Token Bucket |
|----------|---------------|--------------|--------------|
| Window boundary | Smooth (weighted average) | Abrupt reset (2x burst) | N/A |
| Burst pattern | Gradual throttling | Complete blocking periods | Batched graceful degradation |
| Accuracy | Most accurate | Inaccurate at boundaries | Accurate long-term average |
| State change on denial | None (counter unchanged) | Yes (counter incremented) | None (tokens unchanged) |
| Storage space | 2 counters | 1 counter | 2 fields |
| Suitable use case | Precise rate limiting, fair traffic control | Simple quota | General purpose, burst-tolerant |
