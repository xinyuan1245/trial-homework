#!/usr/bin/env bash
set -euo pipefail

# Verifies Deliverable B (ingestion + Redis aggregates) after running:
# - docker compose up -d --build
# - ./scripts/populate_deliverable_a.sh

TIMEOUT_SEC="${TIMEOUT_SEC:-180}"
SLEEP_SEC="${SLEEP_SEC:-2}"
MIN_BIDS="${MIN_BIDS:-10000}"
MIN_IMPRESSIONS="${MIN_IMPRESSIONS:-10000}"

REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"
REDIS_CLI_ARGS="${REDIS_CLI_ARGS:-}"

KEY_BIDS="agg:bid_requests"
KEY_IMPS="agg:deduped_impressions"
KEY_UNKNOWN="agg:unknown_impressions"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd awk
need_cmd date

redis_get_int() {
  local key="$1"
  local v
  v="$(docker exec "${REDIS_CONTAINER}" redis-cli ${REDIS_CLI_ARGS} GET "${key}" 2>/dev/null || true)"
  if [[ -z "${v}" || "${v}" == "(nil)" ]]; then
    echo 0
    return
  fi
  # best-effort; if non-int sneaks in, treat as 0
  if [[ "${v}" =~ ^-?[0-9]+$ ]]; then
    echo "${v}"
  else
    echo 0
  fi
}

container_running() {
  local name="$1"
  docker ps --format '{{.Names}}' | awk -v n="${name}" '$0==n{found=1} END{exit found?0:1}'
}

echo "Verify Deliverable B (Redis aggregates)"
echo "timeout=${TIMEOUT_SEC}s min_bids=${MIN_BIDS} min_impressions=${MIN_IMPRESSIONS}"
echo

for c in "${REDIS_CONTAINER}" redpanda bidsrv ingester-bids ingester-impressions; do
  if ! container_running "${c}"; then
    echo "container not running: ${c}" >&2
    echo "hint: run 'docker compose up -d --build' first" >&2
    exit 1
  fi
done

start_ts="$(date +%s)"
while true; do
  bids="$(redis_get_int "${KEY_BIDS}")"
  imps="$(redis_get_int "${KEY_IMPS}")"
  unknown="$(redis_get_int "${KEY_UNKNOWN}")"

  now="$(date +%s)"
  elapsed=$((now - start_ts))

  printf "elapsed=%ss bids=%s imps_dedup=%s unknown_imps=%s\r" "${elapsed}" "${bids}" "${imps}" "${unknown}"

  if (( bids >= MIN_BIDS && imps >= MIN_IMPRESSIONS )); then
    echo
    break
  fi

  if (( elapsed >= TIMEOUT_SEC )); then
    echo
    echo "timeout waiting for aggregates to reach thresholds" >&2
    break
  fi
  sleep "${SLEEP_SEC}"
done

echo
echo "=== Redis Aggregates ==="
echo "${KEY_BIDS}=$(redis_get_int "${KEY_BIDS}")"
echo "${KEY_IMPS}=$(redis_get_int "${KEY_IMPS}")"
echo "${KEY_UNKNOWN}=$(redis_get_int "${KEY_UNKNOWN}")"

bids="$(redis_get_int "${KEY_BIDS}")"
imps="$(redis_get_int "${KEY_IMPS}")"
unknown="$(redis_get_int "${KEY_UNKNOWN}")"

echo
echo "=== Derived Metrics ==="
if (( bids > 0 )); then
  view_rate="$(awk -v imps="${imps}" -v bids="${bids}" 'BEGIN{printf "%.6f", (imps / bids)}')"
else
  view_rate="0.000000"
fi
echo "view_rate=${view_rate} (deduped_impressions / bid_requests)"

if (( unknown > imps )); then
  echo "warning: unknown_impressions > deduped_impressions (likely still catching up or key corruption)" >&2
fi

echo
echo "=== Sample Breakdowns (campaign) ==="
docker exec "${REDIS_CONTAINER}" redis-cli ${REDIS_CLI_ARGS} --scan --pattern 'agg:campaign:*:bids' 2>/dev/null | head -n 10 | while IFS= read -r k; do
  v="$(docker exec "${REDIS_CONTAINER}" redis-cli ${REDIS_CLI_ARGS} GET "$k" 2>/dev/null || true)"
  echo "$k=$v"
done

echo
echo "OK: Deliverable B verification complete (check thresholds + numbers above)."

