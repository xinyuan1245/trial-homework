# AI Usage

This project was developed with the assistance of an AI coding agent (Antigravity). The agent was tasked primarily with:

- Analyzing the requirement document to outline the project's task breakdown and system design.
- Creating the core Go project layout and boilerplate HTTP handlers utilizing `go-chi`.
- Generating the Dockerfile and configuring the `docker-compose.yml` components (Redis, Redpanda, Go app).
- Writing the `bash` scripts (`scripts/test_local.sh`, `scripts/test_vm.sh`, `scripts/consume.sh`) to fulfill the verification and testing scenarios.
- Providing implementations for Kafka publish (using `franz-go`) and Redis locks/idempotency handling.

All logic choices follow the project prompt constraints closely (avoiding DBs, keeping simplicity, relying strictly on environment configuration, etc.).
