#!/usr/bin/env bash
set -euo pipefail

# Verifies Deliverable C (dashboard is up and returns required metrics).
#
# Expected:
# - dashboard at http://localhost:8082
# - /healthz returns 200
# - /api/metrics returns JSON with required fields

DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:8082}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd curl

echo "Verify Deliverable C (dashboard)"
echo "dashboard_url=${DASHBOARD_URL}"
echo

code="$(curl -s -o /dev/null -w '%{http_code}' "${DASHBOARD_URL}/healthz" || true)"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: dashboard /healthz returned ${code} (expected 200)" >&2
  echo "hint: run 'docker compose up -d --build' and verify port 8082 is exposed" >&2
  exit 1
fi

json="$(curl -sS "${DASHBOARD_URL}/api/metrics?dimension=campaign" || true)"
if [[ -z "${json}" ]]; then
  echo "FAIL: empty response from /api/metrics" >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  JSON_PAYLOAD="${json}" python3 - <<'PY'
import json, os, sys

raw = os.environ.get("JSON_PAYLOAD", "")
try:
    data = json.loads(raw)
except Exception as e:
    print(f"FAIL: invalid JSON from /api/metrics: {e}", file=sys.stderr)
    sys.exit(1)

required = ["bid_requests", "deduped_impressions", "unknown_impressions", "view_rate", "dimension", "breakdown"]
missing = [k for k in required if k not in data]
if missing:
    print(f"FAIL: missing fields in /api/metrics response: {missing}", file=sys.stderr)
    sys.exit(1)

if data["dimension"] != "campaign":
    print(f"FAIL: expected dimension=campaign, got {data['dimension']!r}", file=sys.stderr)
    sys.exit(1)

try:
    bids = int(data["bid_requests"])
    imps = int(data["deduped_impressions"])
except Exception:
    print("FAIL: bid_requests and deduped_impressions must be integers", file=sys.stderr)
    sys.exit(1)

vr = float(data["view_rate"])
expected = (imps / bids) if bids > 0 else 0.0
if abs(vr - expected) > 1e-9:
    print(f"FAIL: view_rate mismatch (got {vr}, expected {expected})", file=sys.stderr)
    sys.exit(1)

print("OK: /api/metrics shape + view_rate definition verified.")
PY
else
  echo "warning: python3 not found; skipping strict JSON validation"
  echo "${json}" | grep -q '"view_rate"' || { echo "FAIL: missing view_rate in JSON" >&2; exit 1; }
  echo "${json}" | grep -q '"unknown_impressions"' || { echo "FAIL: missing unknown_impressions in JSON" >&2; exit 1; }
fi

echo "OK: Deliverable C verification passed."
