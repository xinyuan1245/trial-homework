#!/usr/bin/env bash
set -euo pipefail

# Verifies Deliverable B (ingestion + Redis aggregates) after running:
# - docker compose up -d --build
# - ./scripts/populate_deliverable_a.sh

TIMEOUT_SEC="${TIMEOUT_SEC:-180}"
SLEEP_SEC="${SLEEP_SEC:-2}"
MIN_BIDS="${MIN_BIDS:-10000}"
MIN_IMPRESSIONS="${MIN_IMPRESSIONS:-10000}"

REDIS_SERVICE="${REDIS_SERVICE:-redis}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}" # fallback for older deployments
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

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return
  fi
  echo "missing docker compose (need 'docker compose' plugin or 'docker-compose' binary)" >&2
  exit 1
}

service_container_id() {
  local service="$1"
  compose ps -q "${service}" 2>/dev/null | head -n 1 || true
}

container_running() {
  local name="$1"
  local id status
  id="$(service_container_id "${name}")"
  if [[ -n "${id}" ]]; then
    status="$(docker inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || true)"
    [[ "${status}" == "running" ]]
    return $?
  fi
  docker ps --format '{{.Names}}' | awk -v n="${name}" '$0==n{found=1} END{exit found?0:1}'
}

redis_exec() {
  local id
  id="$(service_container_id "${REDIS_SERVICE}")"
  if [[ -n "${id}" ]]; then
    compose exec -T "${REDIS_SERVICE}" "$@"
    return
  fi
  docker exec "${REDIS_CONTAINER}" "$@"
}

redis_get_int() {
  local key="$1"
  local v
  v="$(redis_exec redis-cli ${REDIS_CLI_ARGS} GET "${key}" 2>/dev/null || true)"
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

echo "Verify Deliverable B (Redis aggregates)"
echo "timeout=${TIMEOUT_SEC}s min_bids=${MIN_BIDS} min_impressions=${MIN_IMPRESSIONS}"
echo

if ! container_running "${REDIS_SERVICE}" && ! container_running "${REDIS_CONTAINER}"; then
  echo "redis not running (tried service=${REDIS_SERVICE}, container=${REDIS_CONTAINER})" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

if ! container_running redpanda; then
  echo "container not running: redpanda" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

if ! container_running ingester-bids; then
  echo "container not running: ingester-bids" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

if ! container_running ingester-impressions; then
  echo "container not running: ingester-impressions" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

if ! container_running api && ! container_running bidsrv; then
  echo "bidding server not running (tried service=api, container=bidsrv)" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

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
redis_exec redis-cli ${REDIS_CLI_ARGS} --scan --pattern 'agg:campaign:*:bids' 2>/dev/null | head -n 10 | while IFS= read -r k; do
  v="$(redis_exec redis-cli ${REDIS_CLI_ARGS} GET "$k" 2>/dev/null || true)"
  echo "$k=$v"
done

echo
echo "OK: Deliverable B verification complete (check thresholds + numbers above)."
