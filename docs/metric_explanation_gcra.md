# GCRA 알고리즘과 메트릭 해석

## GCRA 작동 원리

### 핵심 개념

GCRA(Generic Cell Rate Algorithm)는 **다음 요청이 허용되는 이론적 시각(TAT)** 하나만 추적한다. 요청이 TAT보다 충분히 이후에 도착하면 허용, 아니면 거부.

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

### 다른 알고리즘과의 근본적 차이

| 알고리즘 | 질문 | 추적 대상 |
|---------|------|----------|
| Token Bucket | "토큰이 남았는가?" | 남은 토큰 수 + 마지막 보충 시각 |
| Fixed Window | "이 윈도우에서 몇 개 썼는가?" | 카운터 |
| Sliding Window | "가중 합산이 한도 이내인가?" | 카운터 2개 |
| **GCRA** | **"이 요청이 너무 빨리 온 건 아닌가?"** | **TAT 하나** |

GCRA는 상태를 **타임스탬프 하나**로 압축한다. 가장 적은 상태로 정밀한 rate limiting을 구현한다.

### 판정 로직

```
요청 도착
  │
  ▼
① TAT 조회
  │  last_tat = GET(key) or now  (첫 요청이면 현재 시각)
  │
  ▼
② 새 TAT 계산
  │  tat = max(now, last_tat) + cost × emission_interval
  │
  ▼
③ 허용 시각 계산
  │  allow_at = tat - capacity × emission_interval
  │  time_elapsed = now - allow_at
  │  remaining = floor(time_elapsed / emission_interval)
  │
  ▼
④ 판정
  │  remaining ≥ 0 ?
  │
  ├── NO  → limited = true  (denied)
  │         retry_after = -time_elapsed
  │         TAT 갱신 안 함
  │
  └── YES → limited = false (allowed)
            TAT = tat 저장
            reset_after = tat - now
```

### 파라미터

`per_min(500)` 설정 시:

| 파라미터 | 값 | 의미 |
|----------|-----|------|
| capacity | 500 | burst 허용량 |
| emission_interval | 0.12 sec | 요청 1개당 필요 간격 (60 / 500) |
| fill_time | 60 sec | 전체 capacity 충전 시간 (500 × 0.12) |
| cost | 1 (기본값) | 요청 1회가 TAT를 밀어내는 양 |

### 상태 (State)

| 저장 필드 | 설명 |
|-----------|------|
| `TAT` | 다음 허용 이론 시각 (단일 타임스탬프) |

**이것이 전부다.** 모든 알고리즘 중 가장 적은 상태.

| 파생 필드 | 계산 | 설명 |
|-----------|------|------|
| `remaining` | = floor((now - allow_at) / emission_interval) | 남은 허용 가능 횟수 |
| `reset_after` | = tat - now | TAT가 과거가 될 때까지 남은 시간 |
| `retry_after` | = -(now - allow_at) (denied 시) | 허용 시각까지 대기 시간 |

## TAT의 직관적 이해

TAT는 "빚"으로 생각할 수 있다. 요청을 허용할 때마다 미래에 빚을 쌓고, 시간이 지나면 빚이 줄어든다.

```
TAT
future ┤
       │  ■              요청마다 TAT가 미래로 밀림
       │  ■■              (빚이 쌓임)
       │    ■■
       │      ■■■
       │         ■■■■■■■■■■ ← TAT가 capacity분 앞에 있으면
       │                       더 이상 빚을 쌓을 수 없음 → denied
  now  ┤─────────────────────
       │
 past  ┤  TAT가 과거에 있으면
       │  빚이 없는 상태 → 무조건 allowed
       ├──────────────────────────────── time
```

### 구체적 예시

capacity=5, emission_interval=1초 기준:

```
시각  TAT    allow_at  판정     설명
─────────────────────────────────────────────
t=0   1      -4       allowed  TAT=max(0,0)+1=1, allow_at=1-5=-4
t=0   2      -3       allowed  TAT=max(0,1)+1=2, allow_at=2-5=-3
t=0   3      -2       allowed  TAT=max(0,2)+1=3
t=0   4      -1       allowed  TAT=max(0,3)+1=4
t=0   5       0       allowed  TAT=max(0,4)+1=5, allow_at=5-5=0, 0≥0 OK
t=0   6       1       denied   TAT=max(0,5)+1=6, allow_at=6-5=1, 0<1 NG
                                retry_after = 1초

t=1   6       1       allowed  now=1 ≥ allow_at=1 → OK
                                TAT=max(1,5)+1=6 (동일)

t=2   6       1       allowed  TAT=max(2,5)+1=6, allow_at=1, 2≥1 OK
                                하지만 remaining=floor((2-1)/1)=1 → 딱 1개만
```

시간이 지나면 allow_at이 상대적으로 과거가 되어 자연스럽게 요청이 허용된다.

## 시간에 따른 TAT 변화

`per_min(500)` 기준:

```
TAT - now (초 단위 "빚")
 60 ┤                    ■■■━━━━━━━━
    │                   ■    capacity × emission_interval
    │                  ■     = 500 × 0.12 = 60초
    │                ■■      이 이상 빚을 쌓을 수 없음
    │            ■■■■
    │  Phase 1  ■    Phase 2
    │  3 req/s ■     8 req/s
    │  빚 < 보상 ■    빚 ≈ 보상
    │  → TAT≈now ■   → TAT 점진 상승
  0 ┤■■■■■■■■■■■                      ■■■■■■■■■
    │                          Phase 4
    │                          빚 상환 → TAT≈now
    ├──────────────────────────────────────── time
    0:00    1:00    2:00    3:00    4:00    5:00
```

### Phase 3 (Burst) 상세

20 req/s 트래픽에서, TAT가 최대(60초 앞)에 도달한 후:

```
시간   TAT-now  remaining  판정     설명
────────────────────────────────────────────
0.00    59.88      1      allowed  마지막 여유
0.05    60.00      0      allowed  정확히 한계
0.10    60.00     -1      denied   빚 한도 초과
0.15    60.00     -1      denied
0.20    59.88      0      allowed  0.12초 경과 → 빚 0.12 상환 → 1개 허용
0.25    60.00     -1      denied
0.30    59.88      0      allowed  다시 0.12초 경과 → 1개 허용
...
```

emission_interval(0.12초)마다 정확히 1개씩 허용. **가장 균일한 교차 패턴**을 보인다.

## 메트릭과의 관계

### `throttled_requests_total` (Counter)

```
                    균일한 교차 패턴
                         ↓↓↓
allowed ████████████████▓▓▓▓▓▓▓▓▓▓▓████████
denied                  ▓▓▓▓▓▓▓▓▓▓▓
        ─────────────────────────────────── time
        Phase 1,2       Phase 3     Phase 4
        TAT ≈ now       TAT 최대     TAT 하강
```

| 구간 | TAT 상태 | allowed rate | denied rate |
|------|---------|-------------|-------------|
| Normal (3 req/s) | TAT ≈ now | 3/s | 0/s |
| Ramp up (8 req/s) | TAT 점진 상승 | 8/s | 0/s |
| Burst (20 req/s) | TAT 최대 (60초 앞) | ~8.33/s (= 1/emission_interval) | ~11.67/s |
| Cool down (3 req/s) | TAT 하강 | 3/s | 0/s |

Token bucket, Leaking bucket과 동일한 처리량이지만, GCRA의 허용 패턴이 가장 균일하다. emission_interval 간격으로 정확히 1개씩 허용하기 때문.

### `throttled_duration_seconds` (Histogram)

GCRA는 연산이 가장 단순하다:
- 타임스탬프 비교 1회
- 덧셈/뺄셈 몇 번
- 나눗셈 1회 (floor)

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

O(1) 연산, 상태 접근도 GET/SET 1회씩. 이론적으로 가장 가벼운 알고리즘.

### Denied ratio (Gauge)

| 구간 | 순간 차단률 | 특성 |
|------|------------|------|
| Normal / Ramp up | 0% | TAT 여유 |
| Burst | ~58% | (20 - 8.33) / 20, token bucket과 동일 |
| Cool down | 0% | TAT 빠르게 하강 |

다른 bucket 계열과 동일한 차단률. GCRA의 차이는 비율이 아니라 **허용 타이밍의 균일성**에 있다.

## GCRA가 특별한 이유

### 1. 최소 상태

| 알고리즘 | 저장 상태 |
|---------|----------|
| Token Bucket | tokens + last_refreshed (2개) |
| Leaking Bucket | tokens + last_refreshed (2개) |
| Fixed Window | counter (1개, but 키에 윈도우 번호 포함) |
| Sliding Window | counter × 2 (2개 키) |
| **GCRA** | **TAT (1개 타임스탬프)** |

### 2. 가장 균일한 트래픽 성형

Burst 구간에서 허용 패턴 비교:

```
Token Bucket:  ✓✓✓✓✓✗✗✗✓✗✗✓✗✗✓✗  (보충 타이밍에 따라 불규칙)
Leaking Bucket: ✓✓✓✓✓✗✗✗✓✗✗✓✗✗✓✗  (배출 타이밍에 따라 불규칙)
GCRA:          ✓✓✓✓✓✗✓✗✓✗✓✗✓✗✓✗  (emission_interval마다 정확히 1개)
Fixed Window:  ✓✓✓✓✓✗✗✗✗✗✗✗✗✗✗✗  (한도 도달 후 전면 차단)
```

GCRA는 ATM 네트워크의 셀 전송 속도 제어에서 유래했으며, 균일한 간격의 트래픽 성형이 핵심 설계 목표다.

## 다른 알고리즘과의 차이

| 특성 | GCRA | Token Bucket | Fixed Window | Sliding Window |
|------|------|-------------|--------------|----------------|
| 상태 크기 | 타임스탬프 1개 | 필드 2개 | 카운터 1개 | 카운터 2개 |
| 허용 균일성 | 가장 균일 | 보충 주기 의존 | 윈도우 초반 집중 | 가중치 변동 |
| Burst 패턴 | 균일 교차 | 불규칙 교차 | 완전 차단 | 점진적 차단 |
| 출신 | ATM 네트워크 | 네트워크 QoS | 웹 API | 웹 API |
| 적합 용도 | 균일 속도 제어, 최소 메모리 | 범용, burst 허용 | 단순 quota | 정밀 제어 |
