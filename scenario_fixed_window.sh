#!/usr/bin/env bash
# 5-minute load scenario — fixed_window
# Rate limit: 500 req/min (~8.3 req/s)

URL="http://localhost:8001/api/pay"

send() {
  local rps=$1 duration=$2 label=$3
  local interval=$(echo "scale=4; 1/$rps" | bc)
  local total=$(echo "$rps * $duration" | bc)
  echo "[$label] ${rps} req/s for ${duration}s (interval=${interval}s, total=${total} reqs)"
  for i in $(seq 1 "$total"); do
    curl -s -o /dev/null -w "%{http_code} " "$URL" -X POST
    sleep "$interval"
  done
  echo
}

echo "=== Phase 1: Normal traffic (0:00 - 1:00) ==="
echo "    ~3 req/s (~180 req/min) — well under 500/min limit"
send 3 60 "Phase 1"

echo "=== Phase 2: Ramp up (1:00 - 2:30) ==="
echo "    ~8 req/s (~480 req/min) — right at the limit"
send 8 90 "Phase 2"

echo "=== Phase 3: Burst (2:30 - 4:00) ==="
echo "    ~20 req/s (~1200 req/min) — heavy overload"
send 20 90 "Phase 3"

echo "=== Phase 4: Cool down (4:00 - 5:00) ==="
echo "    ~3 req/s (~180 req/min) — back to normal"
send 3 60 "Phase 4"

echo "=== Done ==="
