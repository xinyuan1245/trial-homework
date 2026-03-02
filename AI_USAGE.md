# AI Usage

This project was developed with assistance from **OpenAI Codex CLI (GPT-5.2)**. I used the AI agent primarily for:

- Scanning the repo/README against Deliverables A–D and identifying missing artifacts.
- Writing / updating documentation:
  - `ARCHITECTURE_AND_CHOICES.md`
  - `README.md` (run steps + verification)
- Creating verification and end-to-end scripts:
  - `scripts/verify_deliverable_a.sh`
  - `scripts/verify_deliverable_c.sh`
  - `scripts/verify_deliverable_d.sh`
  - `scripts/run_end_to_end.sh`
- Debugging and fixing the Deliverable A verification logic to match `rpk topic describe -p` output.

## What I manually verified (not just AI output)

- Services build and start with `docker compose up -d --build`.
- Deliverable A generation + topic counters:
  - ran `./scripts/populate_deliverable_a.sh`
  - inspected `docker exec redpanda rpk topic describe ...` output to validate the parser
  - ran `./scripts/verify_deliverable_a.sh` successfully
- Deliverable B aggregates in Redis:
  - ran `./scripts/verify_deliverable_b.sh` successfully and checked derived View Rate.
- Deliverable C dashboard correctness:
  - ran `./scripts/verify_deliverable_c.sh` successfully (health + JSON shape + `view_rate = imps/bids` check).
- Deliverable D artifacts:
  - ran `./scripts/verify_deliverable_d.sh` successfully.

## Notes / constraints

- I did not rely on the AI agent for “trust me” correctness: scripts were executed and failures were debugged (e.g., the initial Deliverable A verification parser returned 0 until it was fixed to use `rpk ... -p`).
