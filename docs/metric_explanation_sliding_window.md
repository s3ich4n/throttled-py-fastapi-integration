# Sliding Window 알고리즘과 메트릭 해석

## Sliding Window 작동 원리

### 핵심 개념

이전 윈도우와 현재 윈도우의 카운터를 **가중 평균**으로 합산한다. 현재 윈도우에서 경과한 시간 비율만큼 이전 윈도우의 가중치를 줄여, Fixed Window의 경계 문제를 해결한다.

```
        이전 윈도우 (prev)          현재 윈도우 (curr)
   ┌─────────────────────────┬─────────────────────────┐
   │  counter: 400           │  counter: 100           │
   └─────────────────────────┴─────────────────────────┘
                              │←── 40% 경과 ──→│

   현재 비율 = 0.4    (윈도우의 40% 지점)
   이전 비율 = 0.6    (이전 윈도우의 60%가 아직 유효)

   가중 합산 = floor(0.6 × 400) + 100 + cost
            = 240 + 100 + 1
            = 341

   341 ≤ 500 → allowed
```

### 판정 로직

```
요청 도착
  │
  ▼
① 윈도우 카운터 조회
  │  curr_key = "{key}:period:{now // period}"
  │  prev_key = "{key}:period:{now // period - 1}"
  │  current = GET(curr_key) or 0
  │  previous = GET(prev_key) or 0
  │
  ▼
② 가중 합산
  │  elapsed_ratio = (now_ms % period_ms) / period_ms
  │  prev_weight = 1 - elapsed_ratio
  │  weighted_prev = floor(prev_weight × previous)
  │  used = weighted_prev + current + cost
  │
  ▼
③ 한도 확인
  │  used > limit ?
  │
  ├── YES → limited = true  (denied)
  │         카운터 증가 안 함
  │
  └── NO  → limited = false (allowed)
            INCRBY(curr_key, cost)
```

### 파라미터

`per_min(500)` 설정 시:

| 파라미터 | 값 | 의미 |
|----------|-----|------|
| limit | 500 | 슬라이딩 윈도우 최대 요청 수 |
| period | 60 sec | 윈도우 크기 |
| cost | 1 (기본값) | 요청 1회당 소모량 |

### 상태 (State)

| 저장 필드 | 설명 |
|-----------|------|
| `current_counter` | 현재 윈도우의 요청 수 |
| `previous_counter` | 이전 윈도우의 요청 수 |

| 파생 필드 | 계산 | 설명 |
|-----------|------|------|
| `remaining` | = max(0, limit - used) | 남은 요청 가능 수 |
| `reset_after` | = period | 현재 윈도우 전체 길이 |
| `retry_after` | = prev_weight × period × cost / previous | 이전 윈도우 가중치가 충분히 줄어들 때까지 |

핵심: **denied 시 카운터를 증가시키지 않는다**. Token bucket, Fixed Window와 달리 거부된 요청은 상태를 변경하지 않는다.

## 시간에 따른 가중 합산 변화

`per_min(500)` 기준:

```
used (가중 합산)
500 ┤                          ■■■━━━━━━━━━━━
    │                        ■■   ↑ limit
    │                      ■■     denied 시작
    │                    ■■       (하지만 카운터 불변)
    │          ■■■■■■■■■■
    │        ■■
    │ ■■■■■■■
    │■
  0 ┤──────────────────────────────────────────
    │  Phase 1     Phase 2      Phase 3
    │
    │  가중 합산이 점진적으로 증가
    │  윈도우 경계에서 급격한 변화 없음
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### 가중 평균이 경계 문제를 해결하는 방법

Fixed Window의 2배 burst 문제가 발생하지 않는다:

```
       Fixed Window:
       window A 후반: 490 req    window B 초반: 500 req
       ─────────────────────┃─────────────────────
       2초 동안 990 req 허용 (limit의 2배!)

       Sliding Window:
       window A 후반: 490 req    window B 초반 시도
       ─────────────────────┃─────────────────────
       B 시작 직후: used = floor(0.99 × 490) + 0 + 1 = 486
       486 ≤ 500 → allowed
       ...
       used = floor(0.99 × 490) + 14 + 1 = 500
       500 ≤ 500 → allowed
       used = floor(0.99 × 490) + 15 + 1 = 501
       501 > 500 → denied ← 15번째에서 차단
```

이전 윈도우의 가중치가 천천히 감소하므로, 경계를 넘는 순간에도 이전 트래픽이 반영된다.

### Phase 3 (Burst) 상세: 왜 점진적 차단이 나타나는가

20 req/s 트래픽, 윈도우 30초 지점 (prev_weight=0.5) 기준:

```
시간   prev  curr  가중합산  판정     설명
──────────────────────────────────────────────
0.00   200   201   301      allowed  가중합산 여유
0.05   200   202   302      allowed
...
0.00   200   299   399      allowed
0.00   200   300   400      allowed
...
0.00   200   399   499      allowed
0.00   200   400   500      allowed  limit 도달
0.05   200   400   500+1    denied   초과
0.10   199   400   500      allowed  prev 가중치 감소 → 1개 허용
0.15   199   401   501      denied   다시 초과
...
```

이전 윈도우 가중치가 시간에 따라 감소하면서, **간헐적으로 1~2개씩 허용**되는 패턴이 나타난다. Token bucket의 교차 패턴과 유사하지만, 메커니즘은 다르다.

## 메트릭과의 관계

### `throttled_requests_total` (Counter)

```
                     점진적 차단 (간헐 허용)
                          ↓↓↓
allowed ████████████████████▓▓▓▓▓▓▓▓▓████████
denied                     ▓▓▓▓▓▓▓▓▓
        ──────────────────────────────────────── time
        Phase 1,2        Phase 3       Phase 4
        가중합산 여유     limit 근처     가중합산 감소
```

| 구간 | 가중 합산 | allowed rate | denied rate |
|------|----------|-------------|-------------|
| Normal (3 req/s) | ~180 (한도 이하) | 3/s | 0/s |
| Ramp up (8 req/s) | 점진 증가 | 8/s | 0/s |
| Burst (20 req/s) | limit 근처 진동 | ~8.33/s (fill_rate 수렴) | ~11.67/s |
| Cool down (3 req/s) | 급격히 감소 | 3/s | 0/s |

Burst 구간의 allowed rate가 token bucket과 비슷하게 fill_rate에 수렴하지만, 그 이유가 다르다:
- Token bucket: 토큰 보충 속도에 의해 결정
- Sliding window: 이전 윈도우 가중치 감소 속도에 의해 결정

### `throttled_duration_seconds` (Histogram)

두 개의 키를 조회하고 부동소수점 연산(가중 평균)을 수행하므로, 단순 카운터인 Fixed Window보다는 약간 느리다.

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

여전히 O(1) 연산이지만, GET 2회 + 부동소수점 곱셈이 추가되어 상수 계수가 더 크다.

### Denied ratio (Gauge)

| 구간 | 순간 차단률 | 특성 |
|------|------------|------|
| Normal / Ramp up | 0% | 가중 합산 여유 |
| Burst | ~58% | token bucket과 유사한 비율 |
| Cool down | 0% | 가중 합산 빠르게 감소 |

Fixed Window의 0%↔100% 계단 패턴이 아닌, **부드러운 곡선**이 나타난다. 이전 윈도우의 가중치가 점진적으로 감소하면서 차단률도 점진적으로 변화한다.

## 다른 알고리즘과의 차이

| 특성 | Sliding Window | Fixed Window | Token Bucket |
|------|---------------|--------------|--------------|
| 윈도우 경계 | 매끄러움 (가중 평균) | 급격한 리셋 (2배 burst) | 해당 없음 |
| Burst 패턴 | 점진적 차단 | 완전 차단 구간 | 교차 패턴 |
| 정확도 | 가장 정확 | 경계에서 부정확 | 장기 평균 정확 |
| 거부 시 상태 변경 | 없음 (카운터 불변) | 있음 (카운터 증가) | 없음 (토큰 불변) |
| 저장 공간 | 카운터 2개 | 카운터 1개 | 필드 2개 |
| 적합 용도 | 정밀한 rate limit, 공정한 트래픽 제어 | 단순 quota | 범용, burst 허용 |
