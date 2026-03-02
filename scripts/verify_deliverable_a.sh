#!/usr/bin/env bash
set -euo pipefail

# Verifies Deliverable A (topic message counts) after running:
# - docker compose up -d --build
# - ./scripts/populate_deliverable_a.sh
#
# Notes:
# - Uses rpk topic partition high watermark as a proxy for produced message count.
# - If you used compaction or deleted records, adjust expectations accordingly.

MIN_BIDS="${MIN_BIDS:-10000}"
MIN_IMPRESSIONS="${MIN_IMPRESSIONS:-10000}"

REDPANDA_SERVICE="${REDPANDA_SERVICE:-redpanda}"
REDPANDA_CONTAINER="${REDPANDA_CONTAINER:-redpanda}" # fallback for older deployments

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd awk

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

redpanda_exec() {
  local id
  id="$(service_container_id "${REDPANDA_SERVICE}")"
  if [[ -n "${id}" ]]; then
    compose exec -T "${REDPANDA_SERVICE}" "$@"
    return
  fi
  docker exec "${REDPANDA_CONTAINER}" "$@"
}

if ! container_running "${REDPANDA_SERVICE}" && ! container_running "${REDPANDA_CONTAINER}"; then
  echo "redpanda not running (tried service=${REDPANDA_SERVICE}, container=${REDPANDA_CONTAINER})" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

topic_hw_sum() {
  local topic="$1"
  local out sum
  out="$(redpanda_exec rpk topic describe -p "${topic}" 2>/dev/null || true)"
  if [[ -z "${out}" ]]; then
    echo 0
    return
  fi
  # rpk v24+ prints a SUMMARY section and a PARTITIONS table like:
  # PARTITION ... HIGH-WATERMARK
  # 0 ... 5929
  sum="$(echo "${out}" | awk '
    BEGIN{sum=0; in_table=0}
    /^PARTITION[[:space:]]+LEADER[[:space:]]+EPOCH/ {in_table=1; next}
    in_table==1 && $1 ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ {sum+=$NF; next}
    in_table==1 && /^$/ {in_table=0}
    END{print sum+0}
  ')"
  echo "${sum}"
}

echo "Verify Deliverable A (Redpanda topic counters)"
echo "min_bids=${MIN_BIDS} min_impressions=${MIN_IMPRESSIONS}"
echo

bids_hw="$(topic_hw_sum "bid-requests")"
imps_hw="$(topic_hw_sum "impressions")"

echo "bid-requests_high_watermark_sum=${bids_hw}"
echo "impressions_high_watermark_sum=${imps_hw}"
echo

ok=1
if (( bids_hw < MIN_BIDS )); then
  echo "FAIL: bid-requests appears to have < ${MIN_BIDS} messages (got ${bids_hw})" >&2
  ok=0
fi
if (( imps_hw < MIN_IMPRESSIONS )); then
  echo "FAIL: impressions appears to have < ${MIN_IMPRESSIONS} messages (got ${imps_hw})" >&2
  ok=0
fi

if (( ok == 0 )); then
  echo
  echo "Debug:"
  echo "docker compose exec -T ${REDPANDA_SERVICE} rpk topic describe bid-requests impressions" >&2
  exit 1
fi

echo "OK: Deliverable A verification passed."
