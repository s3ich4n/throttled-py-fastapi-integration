# GCRA Algorithm and Metric Interpretation

## How GCRA Works

### Core Concept

GCRA (Generic Cell Rate Algorithm) tracks only **the theoretical arrival time (TAT)** of conforming traffic. A request is allowed when the current time is not earlier than `allow_at`, where `allow_at` is derived from TAT and the allowed burst capacity.

```
         TAT (Theoretical Arrival Time)
          │
          ▼
   ──────────────────────────────────── time
   past          now              future
                  │
          ┌───────┴───────┐
          │               │
     now ≥ allow_at    now < allow_at
          │               │
       allowed          denied

   allow_at = TAT - (capacity × emission_interval)
```

### Fundamental Differences from Other Algorithms

| Algorithm | Question | What It Tracks |
|---------|------|----------|
| Token Bucket | "Are there tokens remaining?" | Remaining token count + last refill time |
| Fixed Window | "How many have been used in this window?" | Counter |
| Sliding Window | "Is the weighted sum within the limit?" | 2 counters |
| **GCRA** | **"Did this request arrive too quickly?"** | **TAT only** |

GCRA compresses state into **a single timestamp**. It achieves precise rate limiting with very little state.

### Decision Logic

```
Request arrives
  │
  ▼
① Look up TAT
  │  last_tat = GET(key) or now  (current time if first request)
  │
  ▼
② Calculate new TAT
  │  tat = max(now, last_tat) + cost × emission_interval
  │
  ▼
③ Calculate allow time
  │  allow_at = tat - capacity × emission_interval
  │  time_elapsed = now - allow_at
  │  remaining = floor(time_elapsed / emission_interval)
  │
  ▼
④ Decision
  │  remaining ≥ 0 ?
  │
  ├── NO  → limited = true  (denied)
  │         retry_after = -time_elapsed
  │         TAT is not updated
  │
  └── YES → limited = false (allowed)
            Save TAT = tat
            reset_after = tat - now
```

### Parameters

For the `per_min(500)` configuration:

| Parameter | Value | Meaning |
|----------|-----|------|
| capacity | 500 | Burst allowance |
| emission_interval | 0.12 sec | Required interval per request (60 / 500) |
| fill_time | 60 sec | Time to fully recharge capacity (500 × 0.12) |
| cost | 1 (default) | Amount by which a single request advances the TAT |

### State

| Stored Field | Description |
|-----------|------|
| `TAT` | Theoretical arrival time of conforming traffic (a single monotonic timestamp for the in-memory store) |

**That is all.** This is one of the smallest state representations among the supported algorithms.

| Derived Field | Calculation | Description |
|-----------|------|------|
| `remaining` | = floor((now - allow_at) / emission_interval) | Number of remaining allowed requests |
| `reset_after` | = tat - now | Time remaining until TAT falls into the past |
| `retry_after` | = -(now - allow_at) (when denied) | Wait time until the allow time |

## Intuitive Understanding of TAT

TAT can be thought of as "debt." Each time a request is allowed, debt is accumulated into the future, and as time passes, the debt decreases.

```
TAT
future ┤
       │  ■              TAT shifts into the future with each request
       │  ■■              (debt accumulates)
       │    ■■
       │      ■■■
       │         ■■■■■■■■■■ ← When TAT is capacity-worth ahead,
       │                       no more debt can be added → denied
  now  ┤─────────────────────
       │
 past  ┤  When TAT is in the past,
       │  there is no debt → always allowed
       ├──────────────────────────────── time
```

### Concrete Example

With capacity=5, emission_interval=1 second:

```
Time  TAT    allow_at  Decision  Explanation
─────────────────────────────────────────────
t=0   1      -4       allowed   TAT=max(0,0)+1=1, allow_at=1-5=-4
t=0   2      -3       allowed   TAT=max(0,1)+1=2, allow_at=2-5=-3
t=0   3      -2       allowed   TAT=max(0,2)+1=3
t=0   4      -1       allowed   TAT=max(0,3)+1=4
t=0   5       0       allowed   TAT=max(0,4)+1=5, allow_at=5-5=0, 0≥0 OK
t=0   6       1       denied    TAT=max(0,5)+1=6, allow_at=6-5=1, 0<1 NG
                                retry_after = 1 sec

t=1   6       1       allowed   now=1 ≥ allow_at=1 → OK
                                TAT=max(1,5)+1=6

t=2   7       2       allowed   TAT=max(2,6)+1=7, allow_at=2, 2≥2 OK
                                The limiter is still exactly at the sustained rate
```

As time passes, allow_at becomes relatively further in the past, naturally allowing requests again.

## TAT Changes Over Time

Based on `per_min(500)`:

```
TAT - now (debt in seconds)
 60 ┤                    ■■■━━━━━━━━
    │                   ■    capacity × emission_interval
    │                  ■     = 500 × 0.12 = 60 sec
    │                ■■      No more debt can be accumulated beyond this
    │            ■■■■
    │  Phase 1  ■    Phase 2
    │  3 req/s ■     8 req/s
    │  debt < repay ■  debt ≈ repay
    │  → TAT≈now ■   → TAT gradually rises
  0 ┤■■■■■■■■■■■                      ■■■■■■■■■
    │                          Phase 4
    │                          debt repaid → TAT≈now
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### Phase 3 (Burst) Details

At 20 req/s traffic, after TAT reaches maximum (60 seconds ahead). Values below are approximate illustrations of the steady-state pattern:

```
Time    TAT-now  remaining  Decision  Explanation
────────────────────────────────────────────
0.00    ~59.88     1       allowed   Last available slot
0.05    ~60.00     0       allowed   Exactly at the limit
0.10    ~60.00    -1       denied    Debt limit exceeded
0.15    ~60.00    -1       denied
0.20    ~59.88     0       allowed   ~0.12 sec elapsed → debt repaid → 1 allowed
0.25    ~60.00    -1       denied
0.30    ~59.88     0       allowed   Another ~0.12 sec elapsed → 1 allowed
...
```

Approximately 1 request is allowed per emission_interval (0.12 sec). **This produces the most uniform alternating pattern.** Exact values depend on the monotonic clock resolution and actual request arrival timing.

## Relationship to Metrics

### `throttled_requests_total` (Counter)

```
                    Uniform alternating pattern
                         ↓↓↓
allowed ████████████████▓▓▓▓▓▓▓▓▓▓▓████████
denied                  ▓▓▓▓▓▓▓▓▓▓▓
        ─────────────────────────────────── time
        Phase 1,2       Phase 3     Phase 4
        TAT ≈ now       TAT at max   TAT declining
```

| Phase | TAT State | allowed rate | denied rate |
|------|---------|-------------|-------------|
| Normal (3 req/s) | TAT ≈ now | 3/s | 0/s |
| Ramp up (8 req/s) | TAT gradually rising | 8/s | 0/s |
| Burst (20 req/s) | TAT at max (60 sec ahead) | ~8.33/s (= 1/emission_interval) | ~11.67/s |
| Cool down (3 req/s) | TAT declining | 3/s | 0/s |

The saturated throughput is the same as Token Bucket and Leaking Bucket, but GCRA's allow pattern is more uniform in this library because the in-memory implementation uses a monotonic floating-point clock and allows exactly 1 request per emission_interval once saturated.

### `throttled_duration_seconds` (Histogram)

GCRA has the simplest computation:
- 1 timestamp comparison
- A few additions/subtractions
- 1 division (floor)

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

O(1) operations, with only 1 GET/SET for state access each. Theoretically the lightest algorithm.

### Denied ratio (Gauge)

| Phase | Instantaneous Block Rate | Characteristics |
|------|------------|------|
| Normal / Ramp up | 0% | TAT has headroom |
| Burst steady state | ~58% | (20 - 8.33) / 20, same saturated ratio as token bucket |
| Cool down | 0% | TAT drops quickly |

The saturated block rate is the same as other bucket-based algorithms. The difference with GCRA lies not in the ratio but in the **uniformity of allow timing**.

## Why GCRA Is Special

### 1. Minimal State

| Algorithm | Stored State |
|---------|----------|
| Token Bucket | tokens + last_refreshed (2 fields) |
| Leaking Bucket | tokens + last_refreshed (2 fields) |
| Fixed Window | counter (1 field, but window number included in key) |
| Sliding Window | counter × 2 (2 keys) |
| **GCRA** | **TAT (1 timestamp)** |

### 2. Most Uniform Traffic Shaping

Comparison of allow patterns during burst phase:

```
Token Bucket:  ✓✓✓✓✓✗✗✗✓✓✓✗✗✗✗✗  (batched in `throttled-py` 3.2.0)
Leaking Bucket: ✓✓✓✓✓✗✗✗✓✓✓✗✗✗✗✗  (batched in `throttled-py` 3.2.0)
GCRA:          ✓✓✓✓✓✗✓✗✓✗✓✗✓✗✓✗  (exactly 1 per emission_interval)
Fixed Window:  ✓✓✓✓✓✗✗✗✗✗✗✗✗✗✗✗  (complete block after limit reached)
```

GCRA originated from cell transmission rate control in ATM networks, where uniform-interval traffic shaping was the core design goal.

## Differences from Other Algorithms

| Property | GCRA | Token Bucket | Fixed Window | Sliding Window |
|------|------|-------------|--------------|----------------|
| State size | 1 timestamp | 2 fields | 1 counter | 2 counters |
| Allow uniformity | Most uniform | Depends on refill cycle | Concentrated at start of window | Weight fluctuation |
| Burst pattern | Uniform alternation | Batched graceful degradation | Complete block | Gradual block |
| Origin | ATM networks | Network QoS | Web APIs | Web APIs |
| Best suited for | Uniform rate control, minimal memory | General purpose, burst tolerance | Simple quotas | Precise control |
