# throttled-py OTel Metric 검증

## 준비

### 구성 요소

| 서비스 | 역할 |
|--------|------|
| FastAPI (`metric_check.py`) | throttled-py + OTelHook 적용 앱 |
| OTel Collector | OTLP 수신 → Prometheus remote write |
| Prometheus | 메트릭 저장소 |
| Grafana | 대시보드 시각화 |

### OTelHook이 기록하는 메트릭

| OTel 이름 | Prometheus 변환 | 타입 | 설명 |
|-----------|----------------|------|------|
| `throttled.requests` | `throttled_requests_total` | Counter | rate limit 체크 횟수 (label: `result=allowed\|denied`) |
| `throttled.duration` | `throttled_duration_seconds_*` | Histogram | rate limit 체크 소요 시간 |

### Histogram bucket boundary 보정

OTel SDK의 기본 histogram bucket boundary는 초 단위(`0.005, 0.01, 0.025, ...`)로 설정되어 있음.
in-memory token bucket 연산은 마이크로초 단위이므로, 모든 샘플이 첫 번째 bucket에 몰려 `histogram_quantile`이 무의미한 값(p50=2.5s 등)을 반환함.

`ExplicitBucketHistogramAggregation` View로 마이크로초 스케일 boundary를 지정하여 해결:

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

## Grafana 대시보드

### 패널 구성

#### 1. Requests / sec (allowed vs denied)

```promql
rate(throttled_requests_total{result="allowed"}[1m])
rate(throttled_requests_total{result="denied"}[1m])
```

#### 2. Denied ratio

```promql
sum(throttled_requests_total{result="denied"}) / clamp_min(sum(throttled_requests_total), 1)
```

#### 3. Total requests

```promql
throttled_requests_total
```

#### 4. Rate limit check latency (p50 / p95 / p99)

```promql
histogram_quantile(0.50, sum by (le) (rate(throttled_duration_seconds_bucket[1m])))
histogram_quantile(0.95, sum by (le) (rate(throttled_duration_seconds_bucket[1m])))
histogram_quantile(0.99, sum by (le) (rate(throttled_duration_seconds_bucket[1m])))
```

`sum by (le)`는 `result` label(allowed/denied)을 합산하여 단일 시리즈로 만듦.

## 결과

설정: `per_min(500)` (token bucket), in-memory store

### 시나리오 (5분)

| Phase | 시간 | 트래픽 | 결과 |
|-------|------|--------|------|
| 1. Normal | 0:00 - 1:00 | 3 req/s (180/min) | 전량 allowed |
| 2. Ramp up | 1:00 - 2:30 | 8 req/s (480/min) | 전량 allowed (한계선) |
| 3. Burst | 2:30 - 4:00 | 20 req/s (1200/min) | allowed/denied 교차 |
| 4. Cool down | 4:00 - 5:00 | 3 req/s (180/min) | 즉시 회복, 전량 allowed |

### 측정 결과

| 지표 | 값 |
|------|-----|
| Total allowed | 2,430 |
| Total denied | 450 |
| Denied ratio | 15.6% |
| Latency p50 | ~20μs |
| Latency p95 | ~35μs |
| Latency p99 | ~50μs |

### 분석

- **Rate limiter 동작**: burst 구간에서 token bucket이 토큰 보충 주기에 따라 allowed/denied를 교차 반환. 완전 차단이 아닌 graceful degradation 패턴
- **Denied ratio 해석**: 누적 15.6%이지만, burst 구간만 보면 ~53% 차단. 운영 알람용으로는 `rate()` 기반 순간 차단률을 별도로 설정 필요
- **Latency 오버헤드**: in-memory store 기준 p99 ~50μs. 비즈니스 로직 대비 오버헤드 0.01% 미만으로 무시 가능. Redis 전환 시 ms 단위로 상승할 수 있으므로 latency 모니터링 의미가 커짐
