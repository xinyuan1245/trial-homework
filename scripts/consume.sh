#!/bin/bash
set -e

echo "=== Consuming bid-requests ==="
docker exec -it redpanda rpk topic consume bid-requests -n 100 -f '%v\n'

echo ""

echo "=== Consuming impressions ==="
docker exec -it redpanda rpk topic consume impressions -n 100 -f '%v\n'
