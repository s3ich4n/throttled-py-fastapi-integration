# Rate Limit Dashboard Scenario

rate limit: **500 req/min** (`per_min(500)`, ~8.3 req/s)

## Prerequisites

```bash
# 전체 스택 기동
make up

# Grafana
open http://localhost:3000
# Dashboards → Throttled Rate Limit → 상단 mode 드롭다운에서 sync/async 전환
```

## Scenario (5 min)

```bash
# 개별 실행 (sync)
make run-token-bucket

# 개별 실행 (async)
make run-token-bucket MODE=async

# 전체 알고리즘 병렬 (sync)
make run-all-sync

# 전체 알고리즘 병렬 (async)
make run-all-async

# 시나리오 스크립트 직접 실행
bash scenario.sh token_bucket async
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
