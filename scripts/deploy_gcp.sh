#!/bin/bash
set -e

PROJECT_ID="trial-homework"
ZONE="asia-southeast1-c"
MACHINE_TYPE="e2-medium"
# Generate a unique instance name using a timestamp
INSTANCE_NAME="bidding-server-$(date +%s)"
REPO_URL="https://github.com/ZarliAI/trial-homework.git"

echo "=================================================="
echo "1. Selecting GCP project..."
echo "=================================================="
gcloud config set project $PROJECT_ID

echo "=================================================="
echo "2. Creating GCP VM ($INSTANCE_NAME)..."
echo "=================================================="
gcloud compute instances create $INSTANCE_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --machine-type=$MACHINE_TYPE \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=bidding-server

echo "=================================================="
echo "3. Enabling firewall ports 8080, 8081, 8082..."
echo "=================================================="
# We create a single rule targeting the 'bidding-server' tag
gcloud compute firewall-rules create allow-bidding-server-ports \
    --project=$PROJECT_ID \
    --allow tcp:8080,tcp:8081,tcp:8082 \
    --target-tags=bidding-server \
    || echo "Firewall rule might already exist, continuing..."

echo "Waiting 15 seconds for SSH to become available..."
sleep 15

echo "=================================================="
echo "4. Deploying the GitHub repo via SSH..."
echo "=================================================="
gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID --command="
    sudo apt-get update &&
    sudo apt-get install -y git docker.io docker-compose &&
    git clone $REPO_URL zarli-trial-hw &&
    cd zarli-trial-hw &&
    sudo systemctl start docker &&
    sudo docker-compose up -d --build
"

echo "=================================================="
echo "5. Retrieving External IP and verifying..."
echo "=================================================="
VM_IP=$(gcloud compute instances describe $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo "Deployment complete! VM IP is $VM_IP"
echo "Running test_vm.sh..."

# Temporarily override test_vm.sh with the dynamic IP
./scripts/test_vm.sh "http://$VM_IP:8080"
