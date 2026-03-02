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
#   RESET=1                         # runs `docker compose down -v` first
#   DOCKER_AUTO_START=1             # tries to start docker via systemctl (Linux only)

BASE_URL="${BASE_URL:-http://localhost:8080}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

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

docker_ready() {
  docker info >/dev/null 2>&1
}

wait_container_running() {
  local name="$1"
  local timeout_sec="${2:-120}"
  local sleep_sec="${3:-1}"
  local status

  for ((i=1; i<=timeout_sec; i++)); do
    # exists + is running
    status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)"
    if [[ "${status}" == "running" ]]; then
      return 0
    fi
    if [[ "${status}" == "exited" || "${status}" == "dead" ]]; then
      echo "container ${name} is ${status}; check logs: docker logs ${name}" >&2
      return 1
    fi
    sleep "${sleep_sec}"
  done
  echo "timeout waiting for container to be running: ${name}" >&2
  echo "hint: check status with: docker ps -a" >&2
  return 1
}

wait_redpanda_ready() {
  local timeout_sec="${1:-120}"
  for ((i=1; i<=timeout_sec; i++)); do
    if docker exec redpanda rpk cluster info --brokers redpanda:29092 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "timeout waiting for redpanda to be ready" >&2
  echo "hint: docker logs redpanda --tail=200" >&2
  return 1
}

ensure_topics() {
  # Make the init step resilient to timing issues on clean machines.
  # We prefer idempotent creation; if rpk doesn't support `--if-not-exists`,
  # we fall back to ignoring 'already exists' errors.
  local out
  out="$(docker exec redpanda rpk topic create bid-requests impressions --partitions 6 --brokers redpanda:29092 --if-not-exists 2>&1 || true)"
  if [[ -n "${out}" ]]; then
    if echo "${out}" | grep -qi "unknown flag: --if-not-exists" >/dev/null 2>&1; then
      out="$(docker exec redpanda rpk topic create bid-requests impressions --partitions 6 --brokers redpanda:29092 2>&1 || true)"
    fi
    if echo "${out}" | grep -qi "already exists" >/dev/null 2>&1; then
      return 0
    fi
    if echo "${out}" | grep -Eqi "Created topic|created topic|created" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Final check: must be able to describe topics.
  docker exec redpanda rpk topic describe -p bid-requests impressions --brokers redpanda:29092 >/dev/null 2>&1 || {
    echo "failed to ensure topics exist (bid-requests, impressions)" >&2
    echo "debug output:" >&2
    echo "${out}" >&2
    return 1
  }
}

need_cmd docker
need_cmd curl

if ! docker_ready; then
  if [[ "${DOCKER_AUTO_START:-0}" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
    echo "docker daemon not ready; attempting to start via systemctl (DOCKER_AUTO_START=1)"
    sudo systemctl start docker || true
  fi
fi

if ! docker_ready; then
  echo "docker daemon not ready (cannot run 'docker info')." >&2
  echo "hint: start docker and retry (or set DOCKER_AUTO_START=1 on Linux with systemd)." >&2
  exit 1
fi

if [[ "${RESET:-0}" == "1" ]]; then
  echo "=== Pre-step: Reset docker compose state (RESET=1) ==="
  compose down -v || true
fi

echo "=== Step 1: Start services (docker compose) ==="
compose up -d --build

echo
echo "=== Step 2: Wait for core containers to be running ==="
wait_container_running redpanda 180
wait_container_running redis 180
wait_container_running bidsrv 180
wait_container_running ingester-bids 180
wait_container_running ingester-impressions 180
wait_container_running dashboard 180

echo
echo "=== Step 3: Wait for Redpanda + ensure topics ==="
wait_redpanda_ready 180
ensure_topics

echo
echo "=== Step 4: Wait for bidsrv health ==="
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
echo "=== Step 5: Populate Deliverable A via HTTP ==="
./scripts/populate_deliverable_a.sh "${BASE_URL}"

echo
echo "=== Step 6: Verify Deliverable A (topics) ==="
./scripts/verify_deliverable_a.sh

echo
echo "=== Step 7: Verify Deliverable B (Redis aggregates) ==="
./scripts/verify_deliverable_b.sh

echo
echo "=== Step 8: Verify Deliverable C (dashboard) ==="
./scripts/verify_deliverable_c.sh

echo
echo "OK: end-to-end run completed."
