# fastapi-throttled-py-integration

[throttled-py](https://github.com/ZhuoZhuoCrayon/throttled-py) 라이브러리의 5가지 rate limiting 알고리즘을 FastAPI + OTel + Grafana로 시각화하는 프로젝트. 동기(sync)와 비동기(async) 두 가지 모드를 지원한다.

## 구성

```
┌─────────────────────────┐
│  FastAPI (app.py)       │
│  /sync/{algorithm}/pay  │    OTLP/gRPC    ┌───────────────┐   remote write   ┌────────────┐
│  /async/{algorithm}/pay │ ──────────────→ │ OTel Collector │ ──────────────→ │ Prometheus │
│  :8000 (Docker)         │   :4317         └───────────────┘                  └─────┬──────┘
└─────────────────────────┘                                                          │
                                                                                     │ query
                                                                               ┌─────▼──────┐
                                                                               │  Grafana   │
                                                                               │  :3000     │
                                                                               └────────────┘
```

### 앱 구조

단일 FastAPI 앱(`app.py`)이 5개 알고리즘 × 2가지 모드 = 10개 엔드포인트를 제공한다.

| 엔드포인트 | 설명 |
|-----------|------|
| `POST /sync/{algorithm}/pay` | 동기 rate limit 체크 (`Throttled` + `OTelHook`) |
| `POST /async/{algorithm}/pay` | 비동기 rate limit 체크 (`AsyncThrottled` + `AsyncOTelHook`) |

`{algorithm}`: `token_bucket`, `fixed_window`, `sliding_window`, `leaking_bucket`, `gcra`

모든 엔드포인트는 동일한 설정(`per_min(500)`, in-memory store)으로 동작하며, `using` 파라미터만 다르다.

### 수집 메트릭

| Prometheus 이름 | 타입 | 레이블 | 설명 |
|----------------|------|--------|------|
| `throttled_requests_total` | Counter | `result`, `algorithm`, `key`, `store_type` | rate limit 체크 횟수 |
| `throttled_duration_seconds_*` | Histogram | (동일) | rate limit 체크 소요 시간 |

Grafana 대시보드는 `mode`(sync/async) 드롭다운과 `algorithm` 레이블로 row를 반복하여, 모드별·알고리즘별 섹션을 자동 생성한다.

## 테스트 방법

### 사전 준비

```bash
# 전체 스택 기동 (앱 + OTel Collector + Prometheus + Grafana)
make up

# 또는 빌드부터
make build && make up
```

### 단일 알고리즘 테스트

```bash
# sync 모드 (기본)
make run-token-bucket

# async 모드
make run-token-bucket MODE=async

# Grafana 확인
#   http://localhost:3000 → Dashboards → Throttled Rate Limit
#   상단 mode 드롭다운에서 sync/async 전환
```

### 전체 알고리즘 병렬 실행

5개 알고리즘을 동시에 실행하고 비교:

```bash
# sync 모드 전체
make run-all-sync

# async 모드 전체
make run-all-async

# 기본 모드(sync) 전체
make run-all
```

단일 FastAPI 앱(포트 8000)에서 5개 알고리즘 시나리오가 동시에 실행된다. 메트릭은 `key` 레이블(`/sync/...` 또는 `/async/...`)로 구분되어 Grafana에서 모드별로 필터링된다.

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

### 시나리오 스크립트 직접 실행

```bash
# bash scenario.sh <algorithm> [sync|async]
bash scenario.sh token_bucket async
```

## Makefile 타겟 요약

| 타겟 | 설명 |
|------|------|
| `make build` | Docker 이미지 빌드 |
| `make up` | 전체 스택 기동 (docker compose) |
| `make down` | 전체 스택 종료 |
| `make run-{알고리즘}` | 기동 + 시나리오 실행 (`MODE=async` 지원) |
| `make run-all` | 전체 알고리즘 병렬 실행 (기본 sync) |
| `make run-all-sync` | 전체 알고리즘 병렬 실행 (sync) |
| `make run-all-async` | 전체 알고리즘 병렬 실행 (async) |
| `make scenario-{알고리즘}` | 시나리오만 실행 (앱이 떠있어야 함) |
| `make logs` | 앱 로그 확인 |
| `make logs-{서비스}` | 인프라 서비스 로그 확인 |

`{알고리즘}`: `token_bucket`, `fixed_window`, `sliding_window`, `leaking_bucket`, `gcra`

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
