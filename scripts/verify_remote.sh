#!/usr/bin/env bash
set -euo pipefail

# Verifies the deployed system from your local machine against a remote VM:
# - API health + basic bid/billing behavior
# - Dashboard health + /api/metrics shape + view_rate definition
# - (Best-effort) metrics increase after emitting a few events
#
# Usage:
#   ./scripts/verify_remote.sh <VM_EXTERNAL_IP>
#   ./scripts/verify_remote.sh http://<VM_EXTERNAL_IP>:8080
#
# Optional env:
#   BASE_URL=http://<VM_EXTERNAL_IP>:8080
#   DASHBOARD_URL=http://<VM_EXTERNAL_IP>:8082
#   TIMEOUT_SEC=90

arg="${1:-}"
if [[ -n "${arg}" ]]; then
  if [[ "${arg}" =~ ^https?:// ]]; then
    BASE_URL="${BASE_URL:-${arg}}"
  else
    BASE_URL="${BASE_URL:-http://${arg}:8080}"
    DASHBOARD_URL="${DASHBOARD_URL:-http://${arg}:8082}"
  fi
fi

BASE_URL="${BASE_URL:-http://localhost:8080}"
DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:8082}"
TIMEOUT_SEC="${TIMEOUT_SEC:-90}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd curl

http_code() {
  local url="$1"
  curl -s -o /dev/null -w '%{http_code}' "${url}" || true
}

extract_bid_id() {
  sed -n 's/.*"bid_id":"\([^"]*\)".*/\1/p'
}

echo "Verify remote deployment"
echo "api_base_url=${BASE_URL}"
echo "dashboard_url=${DASHBOARD_URL}"
echo

code="$(http_code "${BASE_URL}/healthz")"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: api /healthz returned ${code} (expected 200)" >&2
  exit 1
fi
echo "OK: api health"

code="$(http_code "${DASHBOARD_URL}/healthz")"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: dashboard /healthz returned ${code} (expected 200)" >&2
  exit 1
fi
echo "OK: dashboard health"
echo

get_metrics_json() {
  curl -sS "${DASHBOARD_URL}/api/metrics?dimension=campaign" || true
}

metrics_json="$(get_metrics_json)"
if [[ -z "${metrics_json}" ]]; then
  echo "FAIL: empty response from dashboard /api/metrics" >&2
  exit 1
fi

have_strict_parser=0
if command -v python3 >/dev/null 2>&1; then
  have_strict_parser=1
elif command -v jq >/dev/null 2>&1; then
  have_strict_parser=1
fi

metrics_get_int() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1; then
    JSON_PAYLOAD="${metrics_json}" KEY="${key}" python3 - <<'PY'
import json, os, sys
raw = os.environ["JSON_PAYLOAD"]
key = os.environ["KEY"]
data = json.loads(raw)
v = data.get(key, 0)
try:
    print(int(v))
except Exception:
    print(0)
PY
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "${metrics_json}" | jq -r --arg k "${key}" '.[$k] // 0' 2>/dev/null | awk '{print int($0)}'
    return
  fi
  # Fallback (no strict parsing): we can't reliably extract ints.
  echo 0
}

metrics_validate_shape_and_vr() {
  if command -v python3 >/dev/null 2>&1; then
    JSON_PAYLOAD="${metrics_json}" python3 - <<'PY'
import json, os, sys
raw = os.environ.get("JSON_PAYLOAD", "")
data = json.loads(raw)
required = ["bid_requests", "deduped_impressions", "unknown_impressions", "view_rate", "dimension", "breakdown"]
missing = [k for k in required if k not in data]
if missing:
    print(f"FAIL: missing fields in /api/metrics response: {missing}", file=sys.stderr)
    sys.exit(1)
if data["dimension"] != "campaign":
    print(f"FAIL: expected dimension=campaign, got {data['dimension']!r}", file=sys.stderr)
    sys.exit(1)
bids = int(data["bid_requests"])
imps = int(data["deduped_impressions"])
vr = float(data["view_rate"])
expected = (imps / bids) if bids > 0 else 0.0
if abs(vr - expected) > 1e-9:
    print(f"FAIL: view_rate mismatch (got {vr}, expected {expected})", file=sys.stderr)
    sys.exit(1)
print("OK: /api/metrics shape + view_rate definition verified.")
PY
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    echo "${metrics_json}" | jq -e '.bid_requests and .deduped_impressions and .unknown_impressions and .view_rate and .dimension and .breakdown' >/dev/null
    dim="$(echo "${metrics_json}" | jq -r '.dimension')"
    if [[ "${dim}" != "campaign" ]]; then
      echo "FAIL: expected dimension=campaign, got ${dim}" >&2
      exit 1
    fi
    bids="$(echo "${metrics_json}" | jq -r '.bid_requests|tonumber' 2>/dev/null || echo 0)"
    imps="$(echo "${metrics_json}" | jq -r '.deduped_impressions|tonumber' 2>/dev/null || echo 0)"
    vr="$(echo "${metrics_json}" | jq -r '.view_rate|tonumber' 2>/dev/null || echo 0)"
    expected="$(awk -v imps="${imps}" -v bids="${bids}" 'BEGIN{if (bids>0) printf "%.12f", (imps/bids); else printf "%.12f", 0.0}')"
    got="$(awk -v vr="${vr}" 'BEGIN{printf "%.12f", vr}')"
    if [[ "${expected}" != "${got}" ]]; then
      echo "FAIL: view_rate mismatch (got ${vr}, expected ${expected})" >&2
      exit 1
    fi
    echo "OK: /api/metrics shape + view_rate definition verified."
    return
  fi

  echo "warning: python3/jq not found; doing best-effort /api/metrics validation"
  echo "${metrics_json}" | grep -q '"view_rate"' || { echo "FAIL: missing view_rate in JSON" >&2; exit 1; }
  echo "${metrics_json}" | grep -q '"unknown_impressions"' || { echo "FAIL: missing unknown_impressions in JSON" >&2; exit 1; }
  echo "OK: /api/metrics basic validation passed."
}

metrics_validate_shape_and_vr

if (( have_strict_parser == 1 )); then
  bids0="$(metrics_get_int bid_requests)"
  imps0="$(metrics_get_int deduped_impressions)"
  unknown0="$(metrics_get_int unknown_impressions)"
  echo
  echo "Current aggregates (before smoke traffic): bids=${bids0} imps_dedup=${imps0} unknown=${unknown0}"
fi

echo
echo "Emit a small amount of smoke traffic via HTTP..."
bid_ids=()
for i in {1..5}; do
  payload="{\"user_idfv\":\"user-remote-${i}\",\"app_bundle\":\"com.remote.test\",\"placement_id\":\"p${i}\",\"timestamp\":$(date +%s)}"
  resp="$(curl -sS -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d "${payload}" || true)"
  bid_id="$(echo "${resp}" | extract_bid_id || true)"
  if [[ -z "${bid_id}" ]]; then
    echo "FAIL: could not extract bid_id from /v1/bid response: ${resp}" >&2
    exit 1
  fi
  bid_ids+=("${bid_id}")
done

for bid_id in "${bid_ids[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d "{\"bid_id\":\"${bid_id}\",\"timestamp\":$(date +%s)}" || true)"
  if [[ "${code}" != "200" ]]; then
    echo "FAIL: /v1/billing returned ${code} for bid_id=${bid_id} (expected 200)" >&2
    exit 1
  fi
done

# Duplicate billing (idempotency path)
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d "{\"bid_id\":\"${bid_ids[0]}\",\"timestamp\":$(date +%s)}" || true)"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: duplicate /v1/billing returned ${code} (expected 200)" >&2
  exit 1
fi

# No-fill (expected 204)
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d "{\"user_idfv\":\"789\",\"timestamp\":$(date +%s)}" || true)"
if [[ "${code}" != "204" ]]; then
  echo "FAIL: no-fill /v1/bid returned ${code} (expected 204)" >&2
  exit 1
fi

echo "OK: api bid/billing smoke traffic succeeded."

if (( have_strict_parser == 1 )); then
  echo
  echo "Wait for aggregates to reflect the new traffic..."
  start_ts="$(date +%s)"
  while true; do
    metrics_json="$(get_metrics_json)"
    bids1="$(metrics_get_int bid_requests)"
    imps1="$(metrics_get_int deduped_impressions)"
    unknown1="$(metrics_get_int unknown_impressions)"

    now="$(date +%s)"
    elapsed=$((now - start_ts))
    printf "elapsed=%ss bids=%s imps_dedup=%s unknown=%s\r" "${elapsed}" "${bids1}" "${imps1}" "${unknown1}"

    if (( bids1 >= bids0 + 1 && imps1 >= imps0 + 1 )); then
      echo
      break
    fi
    if (( elapsed >= TIMEOUT_SEC )); then
      echo
      echo "FAIL: timeout waiting for aggregates to increase (is ingestion running?)" >&2
      exit 1
    fi
    sleep 2
  done

  echo
  echo "Current aggregates (after smoke traffic): bids=${bids1} imps_dedup=${imps1} unknown=${unknown1}"
  metrics_validate_shape_and_vr
fi

echo
echo "OK: remote verification passed."

