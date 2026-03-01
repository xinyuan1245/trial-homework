# Mini Ads Bidding Server

This repo contains the minimum ads bidding server implementation for the Zarli AI Trial Homework.

## Architecture

*   **Go Server:** Exposes `/v1/bid` and `/v1/billing` endpoints. Listens on `0.0.0.0:8080` inside the container.
*   **Redis:** Used to handle idempotency for the billing events (ensuring a unique `bid_id` is logged only once).
*   **Redpanda:** Kafka-compatible event broker used to log `bid-requests` and `impressions`. `init-kafka` creates the topics automatically on start.

## Deployment & Execution

### Local Verification

1.  Bring up the containers:
    ```bash
    docker compose up -d --build
    ```

2.  Run the test suite scenarios locally:
    ```bash
    ./scripts/test_local.sh
    ```

3.  Verify the logs in Redpanda topics:
    ```bash
    ./scripts/consume.sh
    ```

### VM Deployment

1.  SSH into your GCP VM instance.
2.  Clone this repository.
3.  Deploy the services:
    ```bash
    docker compose up -d --build
    ```
4.  Run tests from your local machine pointing to the VM:
    ```bash
    ./scripts/test_vm.sh http://<VM_EXTERNAL_IP>:8080
    ```
5.  On the VM, verify logs:
    ```bash
    ./scripts/consume.sh
    ```

## APIs

*   `POST /v1/bid`: Generates and returns a `bid_id` based on hardcoded campaign rules. Logs filled bids to `bid-requests` topic.
*   `POST /v1/billing`: Accepts a `bid_id` and logs successful billing to `impressions` topic idempotently (max once per `bid_id`).
*   `GET /healthz`: Basic healthcheck.
