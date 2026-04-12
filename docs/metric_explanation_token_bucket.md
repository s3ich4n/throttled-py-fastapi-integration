# Token Bucket Algorithm and Metric Interpretation

## How Token Bucket Works

### Core Concept

A bucket holds tokens, and each request consumes a token. If there are no tokens, the request is denied. Tokens are automatically replenished at a constant rate.

```
              fill_rate (replenish per second)
                  │
                  ▼
        ┌─────────────────┐
        │ ○ ○ ○ ○ ○ ○ ○ ○ │ ← capacity (max number of tokens)
        │ ○ ○ ○ ○ ○       │ ← tokens (current number of tokens)
        └────────┬────────┘
                 │
          request → deduct token
                 │
           ┌─────┴─────┐
           │            │
      tokens ≥ cost  tokens < cost
           │            │
        allowed       denied
```

### Parameters

When configured with `per_min(500)`:

| Parameter | Value | Description |
|----------|-----|------|
| capacity | 500 | Max number of tokens in the bucket (= burst allowance) |
| fill_rate | 8.33 tokens/sec | Replenishment rate per second (500 / 60) |
| emission_interval | 0.12 sec | Theoretical average interval for 1 token (60 / 500). In `throttled-py` 3.2.0 token bucket uses whole-second timestamps, so refills happen in whole-token batches based on elapsed seconds |
| cost | 1 (default) | Tokens consumed per request |

### Request Processing Flow

```
Request arrives
  │
  ▼
① Token replenishment calculation
  │  time_elapsed = now_sec - last_refreshed
  │  tokens_added = floor(time_elapsed × fill_rate)
  │  tokens = min(capacity, old_tokens + tokens_added)
  │
  ▼
② Token check
  │  cost > tokens ?
  │
  ├── YES → limited = true  (denied)
  │         retry_after = ceil((cost - tokens) / fill_rate)
  │
  └── NO  → limited = false (allowed)
            tokens = tokens - cost
            last_refreshed = now_sec
  │
  ▼
③ Save state
   { tokens, last_refreshed } → store (memory or Redis)
```

### State

| Stored Field | Description |
|-----------|------|
| `tokens` | Current remaining token count (0 ~ capacity) |
| `last_refreshed` | Last replenishment time (integer Unix timestamp in seconds) |

| Derived Field | Calculation | Description |
|-----------|------|------|
| `remaining` | = tokens | Number of remaining allowed requests |
| `reset_after` | = ceil((capacity - tokens) / fill_rate) | Time remaining until the bucket is full |
| `retry_after` | = ceil((cost - tokens) / fill_rate) | Time remaining until retry is possible when denied |

## Token Changes Over Time

Based on `per_min(500)`, token flow by scenario:

```
tokens
500 ┤■■■■■■■■■■■■■■
    │              ■■■■■■■■■■
    │  Phase 1          ■       Phase 2
    │  3 req/s          ■       8 req/s
    │  consumption < replenishment       consumption ≈ replenishment
    │  → always full     ■       → gradually decreasing
    │                    ■
    │                     ■■
    │                       ■
    │                        ■■■     Phase 4
  0 ┤                     ■■■  ■■■   3 req/s
    │              Phase 3       ■■■■■■■■■■
    │              20 req/s          → immediate recovery
    │              consumption >> replenishment
    │              → oscillating near zero
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### Phase 3 (Burst) Detail: Why Batched Degradation Appears

At 20 req/s traffic:

```
Time  Tokens  Result    Description
─────────────────────────────────────────
0.00   5   allowed  Tokens available, deduct → 4
0.05   4   allowed  Deduct → 3
0.10   3   allowed  Deduct → 2
0.15   2   allowed  Deduct → 1
0.20   1   allowed  Deduct → 0
0.25   0   denied   No tokens
0.30   0   denied   Not yet replenished
...
~1s    8   allowed  1 elapsed second → floor(1 × 8.33) = 8 tokens replenished, then deduct → 7
~1s+   7   allowed  The small batch is consumed quickly under 20 req/s traffic
...
~1.4s  0   denied   Depleted again until the next whole-second refill
...
```

Since the request rate (20/s) exceeds the fill_rate (8.33/s), tokens are consumed as soon as they are replenished. The long-term allowed throughput approaches the fill_rate, but in `throttled-py` 3.2.0 the use of whole-second timestamps means the pattern can look like **small allowed batches followed by denials**, rather than a perfectly even 0.12-second alternation. This is still graceful degradation rather than a complete block.

## Relationship to Metrics

### `throttled_requests_total` (Counter)

```
                    allowed batches / denied intervals
                         ↓↓↓
allowed ████████████████▓▓▓▓▓▓▓▓▓▓▓████████
denied                  ▓▓▓▓▓▓▓▓▓▓▓
        ─────────────────────────────────── time
        Phase 1,2       Phase 3     Phase 4
        tokens sufficient  tokens ≈ 0   tokens recovered
```

| Phase | Token State | allowed rate | denied rate |
|------|-------------|-------------|-------------|
| Normal (3 req/s) | Always 500 (full) | 3/s | 0/s |
| Ramp up (8 req/s) | Gradually decreasing | 8/s | 0/s |
| Burst (20 req/s) | Usually near zero; periodically refilled in small whole-second batches | ~8.33/s long-term (= fill_rate) | ~11.67/s after the initial capacity is exhausted |
| Cool down (3 req/s) | Immediate recovery | 3/s | 0/s |

During the burst phase, the allowed rate converges to the fill_rate after the initial capacity has been consumed. No matter how much traffic surges, sustained throughput cannot exceed the replenishment rate.

### `throttled_duration_seconds` (Histogram)

The token bucket operation is simple arithmetic:
- Subtraction (`tokens - cost`)
- Comparison (`cost > tokens`)
- Multiplication (`time_elapsed × fill_rate`)

Therefore, with an in-memory store, it is very fast at p99 ~50μs. This latency is closer to Python function call overhead than the algorithm itself.

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

The reason latency remains constant despite traffic changes: token bucket is an O(1) operation regardless of request volume.

### Denied ratio (Gauge)

```
denied ratio = denied / (allowed + denied)
```

| Phase | Instantaneous Denial Rate | Calculation |
|------|------------|------|
| Normal / Ramp up | 0% | Sufficient tokens |
| Burst steady state | ~58% | (20 - 8.33) / 20, after the initial bucket capacity is exhausted |
| Cool down | 0% | Tokens immediately recovered |
| Cumulative | 15.6% | 450 / (2430 + 450) |

Operational alerts should be based on `rate()`-based instantaneous denial rate rather than cumulative ratio to enable burst detection.

## Differences from Other Algorithms

| Characteristic | Token Bucket | Fixed Window | Sliding Window |
|------|-------------|--------------|----------------|
| Burst Allowance | Instant burst up to capacity | Up to 2x burst at window boundary | Boundary burst is smoothed by weighted previous-window usage |
| Denied Pattern | Batched graceful degradation in this implementation | Complete block in latter half of window | Gradual throttling |
| Memory | O(1) - 2 fields | O(1) - 1 counter | O(1) - 2 counters |
| Accuracy | Accurate over long-term average | Inaccurate at boundaries | More accurate near window boundaries |
