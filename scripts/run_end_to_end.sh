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
REDPANDA_CONTAINER="${REDPANDA_CONTAINER:-redpanda}" # only used for debug/legacy names
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"         # only used for debug/legacy names

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

service_container_id() {
  local service="$1"
  compose ps -q "${service}" 2>/dev/null | head -n 1 || true
}

redpanda_exec() {
  local id
  id="$(service_container_id redpanda)"
  if [[ -n "${id}" ]]; then
    compose exec -T redpanda "$@"
    return
  fi
  docker exec "${REDPANDA_CONTAINER}" "$@" 2>/dev/null
}

wait_service_running() {
  local service="$1"
  local timeout_sec="${2:-120}"
  local sleep_sec="${3:-1}"
  local id status

  for ((i=1; i<=timeout_sec; i++)); do
    id="$(service_container_id "${service}")"
    if [[ -z "${id}" ]]; then
      sleep "${sleep_sec}"
      continue
    fi

    status="$(docker inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || true)"
    if [[ "${status}" == "running" ]]; then
      return 0
    fi
    if [[ "${status}" == "exited" || "${status}" == "dead" ]]; then
      echo "service ${service} is ${status}; check logs: docker compose logs ${service} --tail=200" >&2
      return 1
    fi
    sleep "${sleep_sec}"
  done
  echo "timeout waiting for service to be running: ${service}" >&2
  echo "hint: check status with: docker compose ps" >&2
  return 1
}

cleanup_known_containers() {
  # On shared VMs it's common to have prior runs with hard-coded container names or
  # lingering containers holding onto ports. Remove only known container names.
  local names=(
    redpanda
    redpanda-console
    init-kafka
    redis
    bidsrv
    ingester-bids
    ingester-impressions
    dashboard
  )

  echo "=== Cleanup: Remove known containers (best-effort) ==="
  docker rm -f "${names[@]}" >/dev/null 2>&1 || true
}

wait_redpanda_ready() {
  local timeout_sec="${1:-120}"
  for ((i=1; i<=timeout_sec; i++)); do
    if redpanda_exec rpk cluster info --brokers redpanda:29092 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "timeout waiting for redpanda to be ready" >&2
  echo "hint: docker compose logs redpanda --tail=200" >&2
  return 1
}

ensure_topics() {
  # Make the init step resilient to timing issues on clean machines.
  # We prefer idempotent creation; if rpk doesn't support `--if-not-exists`,
  # we fall back to ignoring 'already exists' errors.
  local out
  out="$(redpanda_exec rpk topic create bid-requests impressions --partitions 6 --brokers redpanda:29092 --if-not-exists 2>&1 || true)"
  if [[ -n "${out}" ]]; then
    if echo "${out}" | grep -qi "unknown flag: --if-not-exists" >/dev/null 2>&1; then
      out="$(redpanda_exec rpk topic create bid-requests impressions --partitions 6 --brokers redpanda:29092 2>&1 || true)"
    fi
    if echo "${out}" | grep -qi "already exists" >/dev/null 2>&1; then
      return 0
    fi
    if echo "${out}" | grep -Eqi "Created topic|created topic|created" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Final check: must be able to describe topics.
  redpanda_exec rpk topic describe -p bid-requests impressions --brokers redpanda:29092 >/dev/null 2>&1 || {
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
  cleanup_known_containers
fi

echo "=== Step 1: Start services (docker compose) ==="
set +e
up_out="$(compose up -d --build 2>&1)"
up_rc=$?
set -e
if (( up_rc != 0 )); then
  echo "${up_out}" >&2
  if [[ "${CLEANUP_ON_CONFLICT:-1}" == "1" ]] && echo "${up_out}" | grep -Eqi 'already in use|Conflict\.|port is already allocated'; then
    cleanup_known_containers
    compose up -d --build
  else
    exit "${up_rc}"
  fi
fi

echo
echo "=== Step 2: Wait for core containers to be running ==="
wait_service_running redpanda 180
wait_service_running redis 180
wait_service_running api 180
wait_service_running ingester-bids 180
wait_service_running ingester-impressions 180
wait_service_running dashboard 180

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
