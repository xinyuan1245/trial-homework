#!/bin/bash
set -e

BASE_URL=${1:-"http://localhost:8080"}

echo "Running tests against ${BASE_URL}"

# Helper function to extract bid_id
extract_bid_id() {
    echo "$1" | grep -o '"bid_id":"[^"]*' | grep -o '[^"]*$'
}

echo "=== Scenario S1: user_idfv=123 (basic bid + billing) ==="
RES1=$(curl -s -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d '{"user_idfv": "123", "app_bundle": "com.test", "placement_id": "p1", "timestamp": '$(date +%s)'}')
echo "Bid Response: $RES1"
BID_ID_A=$(extract_bid_id "$RES1")
echo "Captured Bid ID: $BID_ID_A"
if [ -n "$BID_ID_A" ]; then
    RES_BILL=$(curl -sw "%{http_code}" -o /dev/null -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d '{"bid_id": "'"$BID_ID_A"'", "timestamp": '$(date +%s)'}')
    echo "Billing Response HTTP Code: $RES_BILL (expect 200)"
else
    echo "Failed to capture bid_id!"
fi
echo ""

echo "=== Scenario S2: user_idfv=123 (duplicate billing ignored) ==="
RES2=$(curl -s -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d '{"user_idfv": "123", "timestamp": '$(date +%s)'}')
echo "Bid Response: $RES2"
BID_ID_B=$(extract_bid_id "$RES2")
echo "Captured Bid ID: $BID_ID_B"
if [ -n "$BID_ID_B" ]; then
    RES_BILL1=$(curl -sw "%{http_code}" -o /dev/null -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d '{"bid_id": "'"$BID_ID_B"'", "timestamp": '$(date +%s)'}')
    echo "First Billing Response HTTP Code: $RES_BILL1 (expect 200)"
    
    RES_BILL2=$(curl -sw "%{http_code}" -o /dev/null -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d '{"bid_id": "'"$BID_ID_B"'", "timestamp": '$(date +%s)'}')
    echo "Second (Duplicate) Billing Response HTTP Code: $RES_BILL2 (expect 200, no extra log)"
else
    echo "Failed to capture bid_id!"
fi
echo ""

echo "=== Scenario S3: user_idfv=789 (no fill) ==="
RES3=$(curl -sw "%{http_code}" -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d '{"user_idfv": "789", "timestamp": '$(date +%s)'}')
# The HTTP code is appended to the body since -w outputs at the end. For 204, body is empty.
echo "Bid Response Code: $RES3 (expect 204)"
echo ""

echo "=== Scenario S4: user_idfv=456 (two bids + two billings) ==="
RES4=$(curl -s -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d '{"user_idfv": "456", "timestamp": '$(date +%s)'}')
echo "First Bid Response: $RES4"
BID_ID_C=$(extract_bid_id "$RES4")
if [ -n "$BID_ID_C" ]; then
    RES_BILL_C=$(curl -sw "%{http_code}" -o /dev/null -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d '{"bid_id": "'"$BID_ID_C"'", "timestamp": '$(date +%s)'}')
    echo "First Billing Response HTTP Code: $RES_BILL_C"
fi

RES5=$(curl -s -X POST "${BASE_URL}/v1/bid" -H "Content-Type: application/json" -d '{"user_idfv": "456", "timestamp": '$(date +%s)'}')
echo "Second Bid Response: $RES5"
BID_ID_D=$(extract_bid_id "$RES5")
if [ -n "$BID_ID_D" ]; then
    RES_BILL_D=$(curl -sw "%{http_code}" -o /dev/null -X POST "${BASE_URL}/v1/billing" -H "Content-Type: application/json" -d '{"bid_id": "'"$BID_ID_D"'", "timestamp": '$(date +%s)'}')
    echo "Second Billing Response HTTP Code: $RES_BILL_D"
fi
echo ""

echo "Tests completed. View outputs using scripts/consume.sh"
