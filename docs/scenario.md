# Rate Limit Dashboard Scenario

rate limit: **500 req/min** (`per_min(500)`, ~8.3 req/s)

## Prerequisites

```bash
# 1. 인프라
make up

# 2. 앱 기동 (예: token bucket)
make app-token-bucket

# 3. Grafana
open http://localhost:3000
# Dashboards → Throttled Rate Limit
```

## Scenario (5 min)

```bash
# 개별 실행
make scenario-token-bucket

# 또는 원커맨드 (앱 기동 + 시나리오 + 종료)
make run-token-bucket

# 전체 알고리즘 병렬
make run-all
```

| Phase | Time | Rate | Expected |
|-------|------|------|----------|
| 1. Normal | 0:00 - 1:00 | ~3 req/s (180/min) | All allowed. Flat green line |
| 2. Ramp up | 1:00 - 2:30 | ~8 req/s (480/min) | At limit. Denied starts appearing |
| 3. Burst | 2:30 - 4:00 | ~20 req/s (1200/min) | Heavy overload. Red(denied) dominates |
| 4. Cool down | 4:00 - 5:00 | ~3 req/s (180/min) | Recovery. Green returns, red disappears |

## What to Watch

- **Requests/sec** — Phase 3에서 red(denied) 급증 확인
- **Denied ratio** — Phase 1: 0% → Phase 3: ~58% → Phase 4: 0%
- **Latency p50/p95/p99** — burst 구간에서 latency 변화 관찰
- **Total requests** — allowed vs denied 누적 카운트
