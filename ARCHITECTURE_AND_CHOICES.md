# ARCHITECTURE_AND_CHOICES (Deliverable D)

This document explains the end-to-end design for Deliverables A–C and the key tradeoffs.

---

## High-Level Architecture

**Data flow:**

1. `bidsrv` API receives HTTP calls:
   - `POST /v1/bid` produces a **bid event** to Redpanda topic `bid-requests`
   - `POST /v1/billing` produces an **impression event** to Redpanda topic `impressions` (with Redis-based idempotency)
2. Two ingesters consume from Redpanda and maintain **low-latency aggregates** in Redis:
   - `ingester-bids` (topic `bid-requests`)
   - `ingester-impressions` (topic `impressions`)
3. `dashboard` serves `http://<host>:8082` and reads the Redis aggregates to display metrics with low latency.

**Why this architecture:** it keeps the system minimal and reproducible on a clean VM while meeting the “low-latency dashboard” requirement by serving from Redis rather than querying raw events.

---

## Deliverable A — How >10k Bid + >10k Impression Events Are Driven via HTTP

Script: `scripts/populate_deliverable_a.sh`

- Generates **>10,000** `POST /v1/bid` calls to create bids (eligible bid IDs are captured from responses).
- Generates **>10,000** `POST /v1/billing` calls:
  - Most calls use real `bid_id` values returned by `/v1/bid` (normal matched impressions).
  - Some calls intentionally reuse the same `bid_id` (idempotency path).
  - Some calls use a synthetic random `bid_id` (unknown/unmatched impressions).

### Corner cases injected

1. **No-fill bids**: `user_idfv=789` is expected to return HTTP `204` from `/v1/bid` (no event emitted).
2. **Duplicate billing**: repeated `/v1/billing` for the same `bid_id` exercises the idempotency behavior (should be HTTP `200` but deduped downstream).
3. **Unknown impressions**: `/v1/billing` for random/synthetic `bid_id` values creates impressions without a corresponding bid.

---

## Deliverable B — Ingestion + Storage Choice and Tradeoffs

### Storage choice: Redis aggregates (not raw events)

The system stores **aggregated counters** in Redis to support fast dashboard queries:

- Global counters:
  - `agg:bid_requests`
  - `agg:deduped_impressions`
  - `agg:unknown_impressions`
- Dimension enumerations (for dashboard dropdown):
  - `dim:campaign`, `dim:placement`, `dim:app_bundle`
- Per-dimension counters:
  - `agg:<dimension>:<value>:bids`
  - `agg:campaign:<value>:impressions_dedup`

### Dedup + unknown/unmatched strategy

- **Bid dedup**: first-seen `bid_id` increments bid counters; duplicates are ignored.
- **Impression dedup**: first-seen impression for a `bid_id` increments impression counters; duplicates are ignored.
- **Unknown impressions**:
  - If an impression arrives before a bid is seen, it is counted as “unknown” (stored as `pending:imp:<bid_id>`).
  - If a matching bid later arrives, the pending unknown is cleared and the unknown counter is decremented.

These updates are implemented with **Redis Lua scripts** for atomicity (so the counters and dedup keys stay consistent under concurrency).

### Tradeoffs

Pros:
- Very low-latency reads for the dashboard (simple `GET` / `MGET` / `SMEMBERS`).
- Minimal operational complexity (single Redis).
- Deterministic metric definition (explicit counters).

Cons / limitations:
- Aggregates are lossy; you can’t run arbitrary queries over raw events.
- Dimensions for impressions are limited to what is present on impression events (currently `campaign_id`).
- Keys have a TTL (configured by ingesters); it’s designed for a “recent window”, not long-term retention.

---

## Deliverable C — Dashboard Approach and Latency Considerations

Dashboard service: `cmd/dashboard/main.go` + `internal/dashboard/server.go`

- Serves HTML UI at `/` and JSON at `/api/metrics`.
- Computes **View Rate** as:

  `View Rate = (deduped impressions) / (bid requests)`

- Displays required counters:
  - bid requests
  - deduped impressions
  - unknown/unmatched impressions
- Provides segmentation by at least one dimension (campaign; additionally shows bid-only breakdowns for placement and app bundle).

Latency is dominated by Redis round-trips, so the handler uses `MGET` for breakdown counters and keeps the server logic simple.

---

## Verification + Runbook (Deliverable D)

- One-command end-to-end (on the VM itself): `scripts/run_end_to_end.sh`
  - Preflights Docker, waits for containers, waits for Redpanda readiness, and ensures topics exist before driving >10k HTTP events.
- Remote verification (from your local machine to the VM): `scripts/verify_remote.sh <VM_EXTERNAL_IP>`
  - Checks `:8080/healthz` + `:8082/healthz`, validates `/api/metrics`, and emits a small amount of smoke traffic to confirm ingestion updates aggregates.

---

## Tech Stack Rationale

- **Redpanda (Kafka-compatible)**: event log, scale-out partitions, easy local reproducibility in docker compose.
- **Go + franz-go**: a fast Kafka client with explicit offset control.
- **Redis**:
  - idempotency storage for `/v1/billing`
  - low-latency, atomic aggregate maintenance for the dashboard
- **Single-binary services in one image**: simpler build/deploy story for the VM.

---

## What I’d Change for 100x Scale

- Persist raw events (or at least a durable fact table) into an analytical store (e.g., ClickHouse/BigQuery) and keep Redis as a hot cache for “last N minutes/hours”.
- Add a stream processor (Flink/Kafka Streams) for joins (e.g., attributing impressions to placement/app_bundle via bid join) and richer segmentation.
- Use stronger correctness guarantees:
  - clearer event schemas and versioning
  - end-to-end idempotency keys
  - consumer group scaling and backpressure controls
- Improve observability (metrics, tracing) and add automated load tests on the VM.


## Addendum (Personal Notes & Uncertainties)

I reviewed most of the AI-generated code and also validated that the generated scripts run successfully. However, because my understanding of the project domain, Go, and Redpanda is not very deep, I had many questions during implementation. Some configuration and design choices were made by leaning on prior experience and best-effort judgment.

- Why split into two consumer types: with multiple queues/topics, each one has its own responsibilities. This makes it easier to tune concurrency differently per topic based on its workload characteristics and target QPS.
- Why Redis for storage: Redis is memory-backed and typically faster for reads/writes, which fits a low-latency dashboard use case.
- Thoughts on extensibility: I considered using another database for the dashboard because I’ve used columnar stores for analytics/dashboarding before. In that approach, Redis can remain the “hot” aggregation/cache layer, while an analytical database provides longer retention and more flexible querying.

Many things felt uncertain while building this: even if the AI produced code that looks like what I wanted, whether it can be reliably used in practice still depends on improving my own understanding of the frameworks, language features, and design tradeoffs involved.

---