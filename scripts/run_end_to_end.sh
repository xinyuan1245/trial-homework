#!/usr/bin/env bash
set -euo pipefail

# End-to-end runner for Deliverables A/B/C (and quick sanity checks).
#
# Usage:
#   ./scripts/run_end_to_end.sh
#
# Optional env:
#   BASE_URL=http://localhost:8080
#   MIN_BIDS=10000 MIN_IMPRESSIONS=10000

BASE_URL="${BASE_URL:-http://localhost:8080}"

echo "=== Step 1: Start services (docker compose) ==="
docker compose up -d --build

echo
echo "=== Step 2: Wait for bidsrv health ==="
for i in {1..120}; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" || true)"
  if [[ "${code}" == "200" ]]; then
    echo "bidsrv healthy (${BASE_URL})"
    break
  fi
  if [[ "${i}" == "120" ]]; then
    echo "bidsrv not healthy after waiting (last code=${code})" >&2
    exit 1
  fi
  sleep 1
done

echo
echo "=== Step 3: Populate Deliverable A via HTTP ==="
./scripts/populate_deliverable_a.sh "${BASE_URL}"

echo
echo "=== Step 4: Verify Deliverable A (topics) ==="
./scripts/verify_deliverable_a.sh

echo
echo "=== Step 5: Verify Deliverable B (Redis aggregates) ==="
./scripts/verify_deliverable_b.sh

echo
echo "=== Step 6: Verify Deliverable C (dashboard) ==="
./scripts/verify_deliverable_c.sh

echo
echo "OK: end-to-end run completed."

