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

REDPANDA_CONTAINER="${REDPANDA_CONTAINER:-redpanda}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd awk

container_running() {
  local name="$1"
  docker ps --format '{{.Names}}' | awk -v n="${name}" '$0==n{found=1} END{exit found?0:1}'
}

if ! container_running "${REDPANDA_CONTAINER}"; then
  echo "container not running: ${REDPANDA_CONTAINER}" >&2
  echo "hint: run 'docker compose up -d --build' first" >&2
  exit 1
fi

topic_hw_sum() {
  local topic="$1"
  local out sum
  out="$(docker exec "${REDPANDA_CONTAINER}" rpk topic describe -p "${topic}" 2>/dev/null || true)"
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
  echo "docker exec ${REDPANDA_CONTAINER} rpk topic describe bid-requests impressions" >&2
  exit 1
fi

echo "OK: Deliverable A verification passed."
