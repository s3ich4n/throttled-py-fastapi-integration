# Leaking Bucket 알고리즘과 메트릭 해석

## Leaking Bucket 작동 원리

### 핵심 개념

버킷에 요청(물)이 쌓이고, 일정 속도로 빠져나간다. 버킷이 가득 차면 거부. Token bucket의 **역전** 모델이다.

```
          요청 → 물 추가 (cost)
                  │
                  ▼
        ┌─────────────────┐
        │ ● ● ● ● ● ● ● ● │ ← capacity (버킷 용량)
        │ ● ● ● ● ●       │ ← tokens (현재 수위)
        └────────┬────────┘
                 │
                 ▼
           leak_rate (초당 배출)
                 │
           ┌─────┴─────┐
           │            │
   tokens+cost ≤ cap  tokens+cost > cap
           │            │
        allowed       denied
```

### Token Bucket과의 핵심 차이

| 관점 | Token Bucket | Leaking Bucket |
|------|-------------|----------------|
| 버킷 의미 | "사용 가능한 토큰" | "쌓인 요청(물)" |
| 초기 상태 | 가득 참 (capacity) | 비어 있음 (0) |
| 요청 시 | 토큰 차감 (tokens - cost) | 물 추가 (tokens + cost) |
| 시간 경과 | 토큰 보충 (+) | 물 배출 (-) |
| 거부 조건 | tokens < cost | tokens + cost > capacity |

둘 다 동일한 처리량을 달성하지만, 정신 모델이 반대이다.

### 판정 로직

```
요청 도착
  │
  ▼
① 배출 계산 (leak)
  │  time_elapsed = now - last_refreshed
  │  leaked = floor(time_elapsed × leak_rate)
  │  tokens = max(0, old_tokens - leaked)
  │
  ▼
② 용량 확인
  │  tokens + cost > capacity ?
  │
  ├── YES → limited = true  (denied)
  │         retry_after = ceil((cost - (capacity - tokens)) / leak_rate)
  │
  └── NO  → limited = false (allowed)
            tokens = tokens + cost
            last_refreshed = now
  │
  ▼
③ 상태 저장
   { tokens, last_refreshed } → store (memory 또는 Redis)
```

### 파라미터

`per_min(500)` 설정 시:

| 파라미터 | 값 | 의미 |
|----------|-----|------|
| capacity | 500 | 버킷 최대 용량 (= burst 허용량) |
| leak_rate | 8.33 req/sec | 초당 배출 속도 (500 / 60) |
| cost | 1 (기본값) | 요청 1회당 추가되는 물의 양 |

leak_rate = token bucket의 fill_rate와 동일한 값. 방향만 반대.

### 상태 (State)

| 저장 필드 | 설명 |
|-----------|------|
| `tokens` | 현재 버킷 수위 — 쌓인 요청 수 (0 ~ capacity) |
| `last_refreshed` | 마지막 배출 시각 (unix timestamp) |

| 파생 필드 | 계산 | 설명 |
|-----------|------|------|
| `remaining` | = capacity - tokens | 남은 여유 공간 |
| `reset_after` | = ceil(tokens / leak_rate) | 버킷이 비기까지 남은 시간 |
| `retry_after` | = ceil((cost - remaining) / leak_rate) | denied 시, 재시도 가능까지 |

## 시간에 따른 수위 변화

`per_min(500)` 기준, 시나리오별 수위 흐름:

```
tokens (수위)
500 ┤                     ■■■  ■■■
    │                    ■  ■■■  ■■■     capacity
    │                   ■            ■
    │                  ■              ■
    │              ■■■■                ■
    │  Phase 1   ■      Phase 2        ■   Phase 4
    │  3 req/s  ■       8 req/s         ■  3 req/s
    │  유입<배출 ■       유입≈배출        ■  유입<배출
    │  → 수위 0  ■      → 수위 상승       ■ → 수위 하강
  0 ┤■■■■■■■■■■■                          ■■■■■■■■
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

Token bucket의 토큰 그래프를 **상하 반전**한 것과 동일한 형태.

### Phase 3 (Burst) 상세

20 req/s 트래픽에서:

```
시간   수위   판정     설명
────────────────────────────────────────────
0.00    1    allowed  물 추가, 수위 1
0.05    2    allowed  물 추가, 수위 2
...
0.00  499    allowed  아직 여유 1
0.05  500    allowed  수위 = capacity (가득)
0.10  501    denied   넘침! (실제로는 추가 안 됨)
0.12  500    denied   0.12초 경과, 1개 배출 → 수위 499
                      하지만 500 + 1 > 500 이므로 여전히...
                      아니, 499 + 1 = 500 ≤ 500 → allowed!
0.17  500    allowed  배출 1개 → 빈 자리에 1개 추가
0.22  501    denied   다시 가득
...
```

Token bucket과 동일한 **교차 패턴** — leak_rate만큼만 허용하고 나머지를 거부한다. 이것은 수학적으로 동치이기 때문이다.

## 메트릭과의 관계

### `throttled_requests_total` (Counter)

```
                    allowed/denied 교차
                         ↓↓↓
allowed ████████████████▓▓▓▓▓▓▓▓▓▓▓████████
denied                  ▓▓▓▓▓▓▓▓▓▓▓
        ─────────────────────────────────── time
        Phase 1,2       Phase 3     Phase 4
        수위 여유        수위 ≈ cap   수위 하강
```

| 구간 | 수위 상태 | allowed rate | denied rate |
|------|----------|-------------|-------------|
| Normal (3 req/s) | 0 (항상 비어 있음) | 3/s | 0/s |
| Ramp up (8 req/s) | 점진 상승 | 8/s | 0/s |
| Burst (20 req/s) | capacity 근처 진동 | ~8.33/s (= leak_rate) | ~11.67/s |
| Cool down (3 req/s) | 빠르게 하강 | 3/s | 0/s |

Token bucket과 사실상 동일한 메트릭 패턴. 내부 모델은 다르지만 외부에서 관측되는 동작은 같다.

### `throttled_duration_seconds` (Histogram)

Token bucket과 동일한 연산 구조:
- 뺄셈 (`tokens - leaked`)
- 덧셈 (`tokens + cost`)
- 비교 (`> capacity`)

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

O(1) 연산. Token bucket과 동일한 수준의 latency를 기대할 수 있다.

### Denied ratio (Gauge)

| 구간 | 순간 차단률 | 계산 |
|------|------------|------|
| Normal / Ramp up | 0% | 수위 낮음 |
| Burst | ~58% | (20 - 8.33) / 20 |
| Cool down | 0% | 수위 빠르게 하강 |

Token bucket과 동일한 비율. 두 알고리즘은 수학적으로 동치이므로 메트릭 상 구분이 어렵다.

## Token Bucket과 정말 같은가?

메트릭 관점에서는 동일한 결과를 보이지만, 미묘한 차이가 있다:

| 관점 | Token Bucket | Leaking Bucket |
|------|-------------|----------------|
| 첫 요청 | tokens=capacity, 즉시 허용 | tokens=0, 즉시 허용 |
| 초기 burst | capacity만큼 즉시 소화 | capacity만큼 즉시 소화 |
| retry_after 계산 | (cost - tokens) / fill_rate | (cost - remaining) / leak_rate |
| 정신 모델 | "잔액 확인" | "용량 확인" |
| 코드 가독성 | 토큰이 충분한가? | 공간이 있는가? |

실무에서는 팀의 멘탈 모델에 맞는 쪽을 선택한다.

## 다른 알고리즘과의 차이

| 특성 | Leaking Bucket | Token Bucket | Fixed Window | Sliding Window |
|------|---------------|-------------|--------------|----------------|
| 모델 | 물 채우기/배출 | 토큰 소모/보충 | 카운터 리셋 | 가중 평균 |
| Burst 패턴 | 교차 (graceful) | 교차 (graceful) | 완전 차단 구간 | 점진적 차단 |
| 메트릭 패턴 | ≈ Token Bucket | ≈ Leaking Bucket | 계단형 | 부드러운 곡선 |
| 저장 공간 | O(1) - 2개 필드 | O(1) - 2개 필드 | O(1) - 1개 | O(1) - 2개 카운터 |
| 적합 용도 | "용량" 관점 선호 시 | "잔액" 관점 선호 시 | 단순 quota | 정밀 제어 |
