# Take-Home Assignment (16h)

## Zarli — Event Pipeline + Metrics Dashboard (GCP VM)

## Trial Homework Objective

This homework is part of our trial evaluation process for a potential full-time Software Engineer role at **InstantConnect Inc (dba Zarli AI)**.

The goal is to assess your ability to design and deliver an end-to-end, production-minded system under a tight timebox:

* make correct engineering choices with clear tradeoffs
* handle production-like messy events and scale considerations
* build a low-latency metrics dashboard with a clear, consistent metric definition
* automate deployment and produce reproducible results on a Linux VM
* use AI tools effectively while still demonstrating strong judgment and verification discipline

**Deliverable-based evaluation:** we evaluate only the deliverables defined in this document. We do not evaluate time spent, and we do not expect perfection—only a correct, stable, minimal implementation consistent with the requirements.

**Hiring pathway:** strong submissions may progress to next stage and can lead to a full-time offer, subject to team fit and interviews. Completion of this homework does not guarantee an offer.

---

## Time, Submission

* **Timebox:** up to **16 hours** (across **3 calendar days assuming part-time**)
* **Submission:**

  * GitHub repo link (all code/scripts/config + README)
  * `AI_USAGE.md` (which AI tools you used + what you manually verified)

---

## Provided Environment (GCP VM) + Access

We will provide an **empty GCP Compute Engine VM (Singapore region)**.

To get access:

```bash
ssh-keygen -t ed25519 -C "your_email_address" -f ~/.ssh/zarli_trial_homework_access
cat ~/.ssh/zarli_trial_homework_access.pub
```

Email the raw `.pub` content to **[founders@zarli.ai](mailto:founders@zarli.ai)**.
We will reply with the exact SSH command.

---

## Provided Starter Repo: Mini Ads Bidding Server 

We will provide a GitHub repository containing a **Mini Ads Bidding Server** that runs via docker compose and exposes:

* `POST /v1/bid`
* `POST /v1/billing`

The repo already includes:

* Go server (listens on `0.0.0.0:8080` inside the container)
* Redis for billing idempotency
* Redpanda (Kafka-compatible) for event logging to topics:

  * `bid-requests`
  * `impressions`
* An init step that creates the topics automatically on startup

You are expected to **use these HTTP endpoints** to generate events for Deliverable A.

> You may extend the starter repo (recommended), but Deliverable A must be driven by **HTTP calls to the bidding server**, not by directly producing to Redpanda.

---

## Homework Overview

You will build a system that:

1. populates Redpanda with a large set of bid and impression events (including production-realistic corner cases),
2. ingests those events into a queryable storage layer,
3. serves a low-latency dashboard that computes key metrics (including View Rate),
4. explains your design choices and tech stack rationale.

---

# Deliverables (Required)

## Deliverable A — Populate Redpanda via HTTP Calls (Outcome-based)

### Goal

After your system is executed, Redpanda must contain:

* **>10,000 Bid events** in topic `bid-requests`
* **>10,000 Impression events** in topic `impressions`

### Key Requirement

You must generate these events by calling the **provided bidding server HTTP APIs**:

* call `/v1/bid` to create bids
* call `/v1/billing` using returned `bid_id` to create impressions

### Additional Requirement

The generated events must include a meaningful mix of **production-realistic corner cases** you consider representative of mobile ads telemetry.

### Acceptance

We must be able to run your repo on the VM and observe:

* Redpanda has **>10k** events in both topics
* your ingestion and dashboard work on the resulting data (Deliverables B/C)

---

## Deliverable B — Ingestion + Storage (Outcome-based)

Implement a pipeline that consumes from Redpanda and persists events into a queryable storage system so the dashboard can compute metrics quickly.

You decide:

* storage technology
* data model/schema
* dedup strategy and matching strategy between bids and impressions
* whether/how to do pre-aggregation, indexing, caching, etc.

Acceptance:

* the dashboard can reliably compute View Rate and required breakdowns
* system is reproducible on the VM

---

## Deliverable C — Low-Latency Web Dashboard (Web)

The dashboard must be accessible at:

* `http://<VM_EXTERNAL_IP>:8082`

### Required Metric Definition

**View Rate = (deduped impressions) / (bid requests)**

The dashboard must show at minimum:

1. View Rate
2. counts of:

   * deduped impressions
   * bid requests
   * unknown/unmatched impressions (impressions without a corresponding bid)
3. at least one segmentation dimension (you choose)

---

## Deliverable D — Verification + Architecture & Choices

Provide:

1. A reproducible way to run the system end-to-end on a clean VM (script or documented commands)
2. `ARCHITECTURE_AND_CHOICES.md` explaining:

   * how you achieved A (how you drove >10k bid + >10k impressions via HTTP, and what corner cases you included)
   * how you achieved B (storage/ingestion choices + tradeoffs)
   * how you achieved C (dashboard approach + latency considerations)
   * why you chose your tech stack, and what you’d change for 100x scale

---

# Non-Goals (Not required)

* full production ads bidding system
* multi-region
* fancy UI polish
* complex IaC

---

# Repo Checklist (Must include)

* README.md (clear run steps)
* code/scripts/config required to run on VM
* dashboard accessible on :8080
* AI_USAGE.md
* ARCHITECTURE_AND_CHOICES.md

---
