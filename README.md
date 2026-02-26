# fastapi-throttled-py-integration

[throttled-py](https://github.com/ZhuoZhuoCrayon/throttled-py) 라이브러리의 5가지 rate limiting 알고리즘을 FastAPI + OTel + Grafana로 시각화하는 프로젝트.

## 구성

```
┌──────────┐    OTLP/gRPC    ┌───────────────┐   remote write   ┌────────────┐
│  FastAPI  │ ──────────────→ │ OTel Collector │ ──────────────→ │ Prometheus │
│  (app)    │   :4317         └───────────────┘                  └─────┬──────┘
└──────────┘                                                          │
                                                                      │ query
                                                                ┌─────▼──────┐
                                                                │  Grafana   │
                                                                │  :3000     │
                                                                └────────────┘
```

### 알고리즘별 앱

| 알고리즘 | 파일 | 포트 |
|---------|------|------|
| Token Bucket | `metric_check_token_bucket.py` | 8000 |
| Fixed Window | `metric_check_fixed_window.py` | 8001 |
| Sliding Window | `metric_check_sliding_window.py` | 8002 |
| Leaking Bucket | `metric_check_leaking_bucket.py` | 8003 |
| GCRA | `metric_check_gcra.py` | 8004 |

모든 앱은 동일한 설정(`per_min(500)`, in-memory store)으로 동작하며, `using` 파라미터만 다르다.

### 수집 메트릭

| Prometheus 이름 | 타입 | 레이블 | 설명 |
|----------------|------|--------|------|
| `throttled_requests_total` | Counter | `result`, `algorithm`, `key`, `store_type` | rate limit 체크 횟수 |
| `throttled_duration_seconds_*` | Histogram | (동일) | rate limit 체크 소요 시간 |

Grafana 대시보드는 `algorithm` 레이블로 row를 반복하여, 알고리즘별 섹션을 자동 생성한다.

## 테스트 방법

### 사전 준비

```bash
# Python 의존성 설치
uv sync

# 인프라 기동 (OTel Collector, Prometheus, Grafana)
make up
```

### 단일 알고리즘 테스트

```bash
# 1. 앱 기동 (별도 터미널)
make app-token-bucket

# 2. 시나리오 실행 (별도 터미널)
make scenario-token-bucket

# 3. Grafana 확인
#    http://localhost:3000 → Dashboards → Throttled Rate Limit
```

### 단일 알고리즘 원커맨드

앱 기동 → 시나리오 실행 → 앱 종료를 한 번에:

```bash
make run-token-bucket
```

### 전체 알고리즘 병렬 실행

5개 알고리즘을 동시에 실행하고 비교:

```bash
make run-all
```

5개 앱이 각각 다른 포트(8000~8004)에서 병렬로 기동되고, 동일한 시나리오가 동시에 실행된다. 메트릭은 모두 같은 OTel Collector로 전송되어 Grafana에서 알고리즘별 섹션으로 분리된다.

### 시나리오 (5분)

| Phase | 시간 | 트래픽 | 예상 결과 |
|-------|------|--------|----------|
| 1. Normal | 0:00 - 1:00 | 3 req/s (180/min) | 전량 allowed |
| 2. Ramp up | 1:00 - 2:30 | 8 req/s (480/min) | allowed (한계선) |
| 3. Burst | 2:30 - 4:00 | 20 req/s (1200/min) | allowed/denied 교차 |
| 4. Cool down | 4:00 - 5:00 | 3 req/s (180/min) | 즉시 회복 |

### 정리

```bash
make down
```

## Makefile 타겟 요약

| 타겟 | 설명 |
|------|------|
| `make up` | 인프라 기동 (docker compose) |
| `make down` | 인프라 종료 |
| `make app-{알고리즘}` | 앱만 포그라운드로 기동 |
| `make scenario-{알고리즘}` | 시나리오만 실행 |
| `make run-{알고리즘}` | 앱 기동 + 시나리오 + 종료 (원커맨드) |
| `make run-all` | 전체 알고리즘 병렬 실행 |
| `make logs-{서비스}` | 서비스 로그 확인 |

`{알고리즘}`: `token-bucket`, `fixed-window`, `sliding-window`, `leaking-bucket`, `gcra`

## 문서

### 메트릭 및 대시보드

- [OTel Metric 검증](docs/metric.md) — 메트릭 구성, Grafana 패널, histogram bucket 보정
- [테스트 시나리오](docs/scenario.md) — 시나리오 구성 및 관찰 포인트

### 알고리즘별 작동 원리

각 문서는 알고리즘의 작동 원리, 시나리오별 동작, 메트릭과의 관계를 설명한다.

- [Token Bucket](docs/metric_explanation_token_bucket.md) — 토큰 보충/차감 모델, graceful degradation 교차 패턴
- [Fixed Window](docs/metric_explanation_fixed_window.md) — 카운터 기반, 윈도우 경계 2배 burst 취약점
- [Sliding Window](docs/metric_explanation_sliding_window.md) — 이전/현재 윈도우 가중 평균, 가장 정확한 제한
- [Leaking Bucket](docs/metric_explanation_leaking_bucket.md) — Token Bucket의 역전 모델, 동일한 메트릭 결과
- [GCRA](docs/metric_explanation_gcra.md) — TAT 하나로 추적, 최소 상태, 가장 균일한 허용 패턴

### 알고리즘 비교

| 특성 | Token Bucket | Fixed Window | Sliding Window | Leaking Bucket | GCRA |
|------|-------------|--------------|----------------|---------------|------|
| 상태 크기 | 2개 필드 | 카운터 1개 | 카운터 2개 | 2개 필드 | 타임스탬프 1개 |
| Burst 패턴 | 교차 | 완전 차단 | 점진적 차단 | 교차 | 균일 교차 |
| 윈도우 경계 문제 | 없음 | 2배 burst | 없음 | 없음 | 없음 |
| 허용 균일성 | 보통 | 낮음 | 보통 | 보통 | 가장 균일 |
| 구현 복잡도 | 보통 | 가장 단순 | 높음 | 보통 | 보통 |
