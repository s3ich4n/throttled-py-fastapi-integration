# Token Bucket 알고리즘과 메트릭 해석

## Token Bucket 작동 원리

### 핵심 개념

버킷에 토큰이 들어있고, 요청마다 토큰을 꺼낸다. 토큰이 없으면 거부. 토큰은 일정 속도로 자동 보충된다.

```
              fill_rate (초당 보충)
                  │
                  ▼
        ┌─────────────────┐
        │ ○ ○ ○ ○ ○ ○ ○ ○ │ ← capacity (최대 토큰 수)
        │ ○ ○ ○ ○ ○       │ ← tokens (현재 토큰 수)
        └────────┬────────┘
                 │
          요청 → 토큰 차감
                 │
           ┌─────┴─────┐
           │            │
      tokens ≥ cost  tokens < cost
           │            │
        allowed       denied
```

### 파라미터

`per_min(500)` 설정 시:

| 파라미터 | 값 | 의미 |
|----------|-----|------|
| capacity | 500 | 버킷 최대 토큰 수 (= burst 허용량) |
| fill_rate | 8.33 tokens/sec | 초당 보충량 (500 / 60) |
| emission_interval | 0.12 sec | 토큰 1개 보충 주기 (60 / 500) |
| cost | 1 (기본값) | 요청 1회당 소모 토큰 |

### 요청 처리 흐름

```
요청 도착
  │
  ▼
① 토큰 보충 계산
  │  time_elapsed = now - last_refreshed
  │  tokens_added = floor(time_elapsed × fill_rate)
  │  tokens = min(capacity, old_tokens + tokens_added)
  │
  ▼
② 토큰 확인
  │  cost > tokens ?
  │
  ├── YES → limited = true  (denied)
  │         retry_after = ceil((cost - tokens) / fill_rate)
  │
  └── NO  → limited = false (allowed)
            tokens = tokens - cost
            last_refreshed = now
  │
  ▼
③ 상태 저장
   { tokens, last_refreshed } → store (memory 또는 Redis)
```

### 상태 (State)

| 저장 필드 | 설명 |
|-----------|------|
| `tokens` | 현재 남은 토큰 수 (0 ~ capacity) |
| `last_refreshed` | 마지막 보충 시각 (unix timestamp) |

| 파생 필드 | 계산 | 설명 |
|-----------|------|------|
| `remaining` | = tokens | 남은 요청 가능 횟수 |
| `reset_after` | = ceil((capacity - tokens) / fill_rate) | 버킷이 가득 차기까지 남은 시간 |
| `retry_after` | = ceil((cost - tokens) / fill_rate) | denied 시, 재시도 가능까지 남은 시간 |

## 시간에 따른 토큰 변화

`per_min(500)` 기준, 시나리오별 토큰 흐름:

```
tokens
500 ┤■■■■■■■■■■■■■■
    │              ■■■■■■■■■■
    │  Phase 1          ■       Phase 2
    │  3 req/s          ■       8 req/s
    │  소모 < 보충       ■       소모 ≈ 보충
    │  → 항상 가득       ■       → 서서히 감소
    │                    ■
    │                     ■■
    │                       ■
    │                        ■■■     Phase 4
  0 ┤                     ■■■  ■■■   3 req/s
    │              Phase 3       ■■■■■■■■■■
    │              20 req/s          → 즉시 회복
    │              소모 >> 보충
    │              → 바닥 근처 진동
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### Phase 3 (Burst) 상세: 왜 교차 패턴이 나타나는가

20 req/s 트래픽에서:

```
시간  토큰  판정     설명
─────────────────────────────────────────
0.00   5   allowed  토큰 있음, 차감 → 4
0.05   4   allowed  차감 → 3
0.10   3   allowed  차감 → 2
0.15   2   allowed  차감 → 1
0.20   1   allowed  차감 → 0
0.25   0   denied   토큰 없음
0.30   0   denied   아직 보충 안 됨
0.35   0   denied   아직 보충 안 됨
0.40   1   allowed  0.12초 경과 → 1개 보충됨
0.45   0   denied   다시 소진
...
```

fill_rate(8.33/s)보다 요청률(20/s)이 높으므로, 보충되는 즉시 소모 → **allowed/denied 교차 패턴** 발생. 이것이 token bucket의 **graceful degradation** 특성이다. 완전 차단이 아닌, 보충 속도에 비례한 부분 허용.

## 메트릭과의 관계

### `throttled_requests_total` (Counter)

```
                    allowed/denied 교차
                         ↓↓↓
allowed ████████████████▓▓▓▓▓▓▓▓▓▓▓████████
denied                  ▓▓▓▓▓▓▓▓▓▓▓
        ─────────────────────────────────── time
        Phase 1,2       Phase 3     Phase 4
        tokens 충분      tokens ≈ 0   tokens 회복
```

| 구간 | tokens 상태 | allowed rate | denied rate |
|------|-------------|-------------|-------------|
| Normal (3 req/s) | 항상 500 (가득) | 3/s | 0/s |
| Ramp up (8 req/s) | 서서히 감소 | 8/s | 0/s |
| Burst (20 req/s) | 바닥 진동 (0~1) | ~8.33/s (= fill_rate) | ~11.67/s |
| Cool down (3 req/s) | 즉시 회복 | 3/s | 0/s |

Burst 구간에서 allowed rate가 fill_rate에 수렴하는 것은 token bucket의 본질적 특성이다. 아무리 트래픽이 몰려도 보충 속도 이상으로 허용할 수 없다.

### `throttled_duration_seconds` (Histogram)

token bucket 연산은 단순한 산술:
- 뺄셈 (`tokens - cost`)
- 비교 (`cost > tokens`)
- 곱셈 (`time_elapsed × fill_rate`)

따라서 in-memory store 기준 p99 ~50μs로 매우 빠르다. 이 latency는 알고리즘 자체보다 Python 함수 호출 오버헤드에 가깝다.

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

트래픽 변화에도 latency가 일정한 이유: token bucket은 요청량과 무관하게 O(1) 연산이기 때문.

### Denied ratio (Gauge)

```
denied ratio = denied / (allowed + denied)
```

| 구간 | 순간 차단률 | 계산 |
|------|------------|------|
| Normal / Ramp up | 0% | 토큰 충분 |
| Burst | ~58% | (20 - 8.33) / 20 |
| Cool down | 0% | 토큰 즉시 회복 |
| 누적 | 15.6% | 450 / (2430 + 450) |

운영 알람은 누적 비율이 아닌 `rate()` 기반 순간 차단률로 설정해야 burst 감지가 가능하다.

## 다른 알고리즘과의 차이

| 특성 | Token Bucket | Fixed Window | Sliding Window |
|------|-------------|--------------|----------------|
| Burst 허용 | capacity만큼 순간 burst 가능 | 윈도우 경계에서 2배 burst 가능 | burst 불가 (정확한 제한) |
| Denied 패턴 | 교차 (graceful degradation) | 윈도우 후반 완전 차단 | 균일 차단 |
| 메모리 | O(1) - 2개 필드 | O(1) - 카운터 1개 | O(N) - 요청 타임스탬프 |
| 정확도 | 장기 평균 정확 | 윈도우 경계 부정확 | 가장 정확 |
