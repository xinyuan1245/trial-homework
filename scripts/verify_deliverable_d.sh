#!/usr/bin/env bash
set -euo pipefail

# Verifies Deliverable D artifacts exist and are discoverable.

need_file() {
  local f="$1"
  if [[ ! -f "${f}" ]]; then
    echo "missing required file: ${f}" >&2
    exit 1
  fi
}

need_file "README.md"
need_file "AI_USAGE.md"
need_file "ARCHITECTURE_AND_CHOICES.md"

echo "OK: Deliverable D artifacts exist:"
echo "- README.md"
echo "- AI_USAGE.md"
echo "- ARCHITECTURE_AND_CHOICES.md"

