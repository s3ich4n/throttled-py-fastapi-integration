# Leaking Bucket Algorithm and Metric Interpretation

## How the Leaking Bucket Works

### Core Concept

Requests (water) accumulate in a bucket and drain out at a constant rate. When the bucket is full, requests are rejected. It is the **inverse** model of the token bucket.

```
          Request → Add water (cost)
                  │
                  ▼
        ┌─────────────────┐
        │ ● ● ● ● ● ● ● ● │ ← capacity (bucket size)
        │ ● ● ● ● ●       │ ← tokens (current water level)
        └────────┬────────┘
                 │
                 ▼
           leak_rate (drain per second)
                 │
           ┌─────┴─────┐
           │            │
   tokens+cost ≤ cap  tokens+cost > cap
           │            │
        allowed       denied
```

### Key Differences from Token Bucket

| Aspect | Token Bucket | Leaking Bucket |
|------|-------------|----------------|
| Bucket meaning | "Available tokens" | "Accumulated requests (water)" |
| Initial state | Full (capacity) | Empty (0) |
| On request | Deduct tokens (tokens - cost) | Add water (tokens + cost) |
| Over time | Tokens replenish (+) | Water drains (-) |
| Denial condition | tokens < cost | tokens + cost > capacity |

Both achieve the same throughput, but the mental model is reversed.

### Decision Logic

```
Request arrives
  │
  ▼
① Calculate drain (leak)
  │  time_elapsed = now_sec - last_refreshed
  │  leaked = floor(time_elapsed × leak_rate)
  │  tokens = max(0, old_tokens - leaked)
  │
  ▼
② Check capacity
  │  tokens + cost > capacity ?
  │
  ├── YES → limited = true  (denied)
  │         retry_after = ceil((cost - (capacity - tokens)) / leak_rate)
  │
  └── NO  → limited = false (allowed)
            tokens = tokens + cost
            last_refreshed = now_sec
  │
  ▼
③ Save state
   { tokens, last_refreshed } → store (memory or Redis)
```

### Parameters

When configured with `per_min(500)`:

| Parameter | Value | Meaning |
|----------|-----|------|
| capacity | 500 | Maximum bucket size (= burst allowance) |
| leak_rate | 8.33 req/sec | Average drain rate per second (500 / 60). In `throttled-py` 3.2.0 leaking bucket uses whole-second timestamps, so draining happens in whole-token batches based on elapsed seconds |
| cost | 1 (default) | Amount of water added per request |

leak_rate = same value as fill_rate in token bucket. Only the direction is reversed. Because this implementation uses whole-second timestamps, the observed drain cadence is batched even though the average rate is 8.33/sec.

### State

| Stored Field | Description |
|-----------|------|
| `tokens` | Current bucket water level — number of accumulated requests (0 ~ capacity) |
| `last_refreshed` | Last drain time (integer Unix timestamp in seconds) |

| Derived Field | Calculation | Description |
|-----------|------|------|
| `remaining` | = capacity - tokens | Remaining available space |
| `reset_after` | = ceil(tokens / leak_rate) | Time remaining until the bucket is empty |
| `retry_after` | = ceil((cost - remaining) / leak_rate) | When denied, time until retry is possible |

## Water Level Changes Over Time

Based on `per_min(500)`, water level flow by scenario:

```
tokens (water level)
500 ┤                     ■■■  ■■■
    │                    ■  ■■■  ■■■     capacity
    │                   ■            ■
    │                  ■              ■
    │              ■■■■                ■
    │  Phase 1   ■      Phase 2        ■   Phase 4
    │  3 req/s  ■       8 req/s         ■  3 req/s
    │  in<drain ■       in≈drain        ■  in<drain
    │  → level 0 ■      → level rises    ■ → level drops
  0 ┤■■■■■■■■■■■                          ■■■■■■■■
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

Over longer windows, this is roughly the token bucket's token graph **flipped vertically**.

### Phase 3 (Burst) Detail

At 20 req/s traffic:

```
Time   Level  Decision   Description
────────────────────────────────────────────
0.00    1    allowed  Water added, level 1
0.05    2    allowed  Water added, level 2
...
0.00  499    allowed  Still 1 space left
0.05  500    allowed  Level = capacity (full)
0.10  501    denied   Overflow! (not actually added)
0.15  500    denied   Still in the same integer second, nothing drained yet
...
~1s   492    allowed  1 elapsed second → floor(1 × 8.33) = 8 drained, then +1
~1s+  500    allowed  Freed capacity is consumed quickly under 20 req/s traffic
~1.4s 500    denied   Full again until the next whole-second drain
...
```

The long-term throughput is the same as token bucket: only the leak_rate amount is allowed after the initial capacity is exhausted and the rest is denied. In this implementation, however, the observed pattern is closer to **small allowed batches followed by denials** because the drain calculation uses elapsed whole seconds.

## Relationship with Metrics

### `throttled_requests_total` (Counter)

```
                    allowed batches / denied intervals
                         ↓↓↓
allowed ████████████████▓▓▓▓▓▓▓▓▓▓▓████████
denied                  ▓▓▓▓▓▓▓▓▓▓▓
        ─────────────────────────────────── time
        Phase 1,2       Phase 3     Phase 4
        level has room   level ≈ cap  level dropping
```

| Phase | Level State | allowed rate | denied rate |
|------|----------|-------------|-------------|
| Normal (3 req/s) | 0 (always empty) | 3/s | 0/s |
| Ramp up (8 req/s) | Gradually rising | 8/s | 0/s |
| Burst (20 req/s) | Usually near capacity; periodically drains in small whole-second batches | ~8.33/s long-term (= leak_rate) | ~11.67/s after the initial capacity is exhausted |
| Cool down (3 req/s) | Rapidly dropping | 3/s | 0/s |

Effectively the same long-term metric pattern as token bucket. The internal model differs, but both converge to the configured rate after the initial capacity is exhausted.

### `throttled_duration_seconds` (Histogram)

Same computational structure as token bucket:
- Subtraction (`tokens - leaked`)
- Addition (`tokens + cost`)
- Comparison (`> capacity`)

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

O(1) operation. You can expect the same level of latency as token bucket.

### Denied ratio (Gauge)

| Phase | Instantaneous Block Rate | Calculation |
|------|------------|------|
| Normal / Ramp up | 0% | Level is low |
| Burst steady state | ~58% | (20 - 8.33) / 20, after the initial bucket capacity is exhausted |
| Cool down | 0% | Level drops rapidly |

Same steady-state ratio as token bucket. Since the two algorithms are mathematically equivalent at the rate/capacity level, they are hard to distinguish from aggregate metrics alone.

## Is It Really the Same as Token Bucket?

From an aggregate metrics perspective they show very similar results, but there are subtle differences:

| Aspect | Token Bucket | Leaking Bucket |
|------|-------------|----------------|
| First request | tokens=capacity, immediately allowed | tokens=0, immediately allowed |
| Initial burst | Handles up to capacity immediately | Handles up to capacity immediately |
| retry_after calculation | (cost - tokens) / fill_rate | (cost - remaining) / leak_rate |
| Mental model | "Check balance" | "Check capacity" |
| Code readability | Are there enough tokens? | Is there space available? |

In practice, choose whichever matches your team's mental model.

## Differences from Other Algorithms

| Characteristic | Leaking Bucket | Token Bucket | Fixed Window | Sliding Window |
|------|---------------|-------------|--------------|----------------|
| Model | Fill/drain water | Consume/replenish tokens | Counter reset | Weighted average |
| Burst pattern | Batched graceful degradation | Batched graceful degradation | Full block period | Gradual blocking |
| Metric pattern | ≈ Token Bucket over longer windows | ≈ Leaking Bucket over longer windows | Step-shaped | Smooth curve |
| Storage space | O(1) - 2 fields | O(1) - 2 fields | O(1) - 1 field | O(1) - 2 counters |
| Best suited for | When "capacity" perspective is preferred | When "balance" perspective is preferred | Simple quota | Precise control |
