#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"

# Defaults satisfy Deliverable A with headroom.
TARGET_BIDS="${TARGET_BIDS:-12000}"
TARGET_IMPRESSIONS_FROM_BIDS="${TARGET_IMPRESSIONS_FROM_BIDS:-11000}"
NO_FILL_REQUESTS="${NO_FILL_REQUESTS:-600}"
UNKNOWN_IMPRESSIONS="${UNKNOWN_IMPRESSIONS:-500}"
DUPLICATE_BILLING_ATTEMPTS="${DUPLICATE_BILLING_ATTEMPTS:-300}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

tmp_dir="$(mktemp -d)"
bid_ids_file="${tmp_dir}/bid_ids.txt"
duplicate_ids_file="${tmp_dir}/duplicate_ids.txt"
touch "${bid_ids_file}"
touch "${duplicate_ids_file}"
trap 'rm -rf "${tmp_dir}"' EXIT

extract_bid_id() {
  sed -n 's/.*"bid_id":"\([^"]*\)".*/\1/p'
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    local h
    h="$(openssl rand -hex 16)"
    echo "${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
    return
  fi

  # Fallback: timestamp + pid + random suffix.
  echo "$(date +%s)-$$-$RANDOM"
}

http_up="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" || true)"
if [[ "${http_up}" != "200" ]]; then
  echo "bidsrv is not healthy at ${BASE_URL} (GET /healthz => ${http_up})"
  exit 1
fi

echo "Populate Deliverable A started against ${BASE_URL}"
echo "TARGET_BIDS=${TARGET_BIDS}"
echo "TARGET_IMPRESSIONS_FROM_BIDS=${TARGET_IMPRESSIONS_FROM_BIDS}"
echo "NO_FILL_REQUESTS=${NO_FILL_REQUESTS}"
echo "UNKNOWN_IMPRESSIONS=${UNKNOWN_IMPRESSIONS}"
echo "DUPLICATE_BILLING_ATTEMPTS=${DUPLICATE_BILLING_ATTEMPTS}"
echo

bid_success=0
bid_failed=0
for ((i=1; i<=TARGET_BIDS; i++)); do
  case $((i % 3)) in
    0) user_idfv="123" ;;
    1) user_idfv="456" ;;
    *) user_idfv="user-${i}" ;;
  esac

  placement_id="placement-$((i % 8))"
  app_bundle="com.zarli.sample.$((i % 5))"
  payload="{\"user_idfv\":\"${user_idfv}\",\"app_bundle\":\"${app_bundle}\",\"placement_id\":\"${placement_id}\",\"timestamp\":$(date +%s)}"

  response="$(curl -sS -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d "${payload}" || true)"
  bid_id="$(echo "${response}" | extract_bid_id || true)"
  if [[ -n "${bid_id}" ]]; then
    echo "${bid_id}" >> "${bid_ids_file}"
    bid_success=$((bid_success + 1))
  else
    bid_failed=$((bid_failed + 1))
  fi

  if (( i % 1000 == 0 )); then
    echo "bid progress: ${i}/${TARGET_BIDS} (successful=${bid_success}, failed=${bid_failed})"
  fi
done

no_fill_204=0
for ((i=1; i<=NO_FILL_REQUESTS; i++)); do
  payload="{\"user_idfv\":\"789\",\"app_bundle\":\"com.zarli.nofill\",\"placement_id\":\"no-fill-$((i % 4))\",\"timestamp\":$(date +%s)}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d "${payload}" || true)"
  if [[ "${code}" == "204" ]]; then
    no_fill_204=$((no_fill_204 + 1))
  fi
done

available_bids="$(wc -l < "${bid_ids_file}" | tr -d ' ')"
if (( available_bids == 0 )); then
  echo "No bid_id captured from /v1/bid, cannot continue."
  exit 1
fi

bill_from_bids="${TARGET_IMPRESSIONS_FROM_BIDS}"
if (( bill_from_bids > available_bids )); then
  bill_from_bids="${available_bids}"
fi

impression_ok=0
impression_non_200=0

while IFS= read -r bid_id; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d "{\"bid_id\":\"${bid_id}\",\"timestamp\":$(date +%s)}" || true)"
  if [[ "${code}" == "200" ]]; then
    impression_ok=$((impression_ok + 1))
  else
    impression_non_200=$((impression_non_200 + 1))
  fi
done < <(head -n "${bill_from_bids}" "${bid_ids_file}")

head -n "${DUPLICATE_BILLING_ATTEMPTS}" "${bid_ids_file}" > "${duplicate_ids_file}" || true
duplicate_200=0
while IFS= read -r bid_id; do
  [[ -z "${bid_id}" ]] && continue
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d "{\"bid_id\":\"${bid_id}\",\"timestamp\":$(date +%s)}" || true)"
  if [[ "${code}" == "200" ]]; then
    duplicate_200=$((duplicate_200 + 1))
  fi
done < "${duplicate_ids_file}"

unknown_200=0
for ((i=1; i<=UNKNOWN_IMPRESSIONS; i++)); do
  unknown_bid_id="$(gen_uuid)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d "{\"bid_id\":\"${unknown_bid_id}\",\"timestamp\":$(date +%s)}" || true)"
  if [[ "${code}" == "200" ]]; then
    unknown_200=$((unknown_200 + 1))
  fi
done

echo
echo "=== Populate Summary ==="
echo "successful /v1/bid (eligible bids): ${bid_success}"
echo "failed /v1/bid: ${bid_failed}"
echo "no-fill checks (expected 204): ${no_fill_204}/${NO_FILL_REQUESTS}"
echo "billing from real bids (200): ${impression_ok}/${bill_from_bids}"
echo "duplicate billing attempts (200 due to idempotency): ${duplicate_200}/${DUPLICATE_BILLING_ATTEMPTS}"
echo "unknown/unmatched billing (200): ${unknown_200}/${UNKNOWN_IMPRESSIONS}"
echo
echo "Corner cases generated:"
echo "1) no-fill traffic (user_idfv=789)"
echo "2) duplicate billing for same bid_id"
echo "3) unmatched impressions via unknown bid_id"
echo
echo "If Redpanda is running in docker, verify topic counters with:"
echo "docker compose exec -T redpanda rpk topic describe bid-requests impressions"
echo
echo "Sample events:"
echo "docker compose exec -T redpanda rpk topic consume bid-requests -n 3 -f '%v\\n'"
echo "docker compose exec -T redpanda rpk topic consume impressions -n 3 -f '%v\\n'"
