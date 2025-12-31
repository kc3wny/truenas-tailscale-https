#!/bin/bash

# cronjob paths
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DOCKER_HOST=unix:///var/run/docker.sock

# Script Config, please replace TS_DOMAIN with your machine-name.tailnet-name.ts.net
TS_DOMAIN="machine-name.tailnet-name.ts.net"
CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i tailscale | head -n 1)
CERT_NAME="Tailscale-Auto-$(date +%Y%m%d-%H%M%S)"

# tailscale app container check
if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: Tailscale container not found. (Docker Socket check: $(ls -l /var/run/docker.sock))"
    exit 1
fi

echo "Found Tailscale container: $CONTAINER_NAME"

# generate tailscale tls cert
echo "Generating certificate for $TS_DOMAIN..."
docker exec "$CONTAINER_NAME" tailscale cert "$TS_DOMAIN"

# copy cert files to temp files
docker exec "$CONTAINER_NAME" cat "$TS_DOMAIN.crt" > /tmp/ts_cert.crt
docker exec "$CONTAINER_NAME" cat "$TS_DOMAIN.key" > /tmp/ts_key.key

# verify certs not empty
if [ ! -s /tmp/ts_cert.crt ] || [ ! -s /tmp/ts_key.key ]; then
    echo "Error: Failed to retrieve certificate files."
    rm -f /tmp/ts_cert.crt /tmp/ts_key.key
    exit 1
fi

# import certs to TrueNAS
echo "Importing certificate '$CERT_NAME' into TrueNAS..."

PAYLOAD=$(python3 -c "import json; print(json.dumps({
    'name': '$CERT_NAME',
    'certificate': open('/tmp/ts_cert.crt').read(),
    'privatekey': open('/tmp/ts_key.key').read(),
    'create_type': 'CERTIFICATE_CREATE_IMPORTED'
}))")

midclt call certificate.create "$PAYLOAD" > /dev/null 2>&1

# cleanup temp files
rm -f /tmp/ts_cert.crt /tmp/ts_key.key

# retrieve cert ID
CERT_ID=$(midclt call certificate.query | jq -r ".[] | select(.name == \"$CERT_NAME\") | .id")

if ! [[ "$CERT_ID" =~ ^[0-9]+$ ]]; then
    echo "CRITICAL ERROR: Failed to find imported certificate ID for name $CERT_NAME"
    exit 1
fi

echo "Certificate imported successfully. ID: $CERT_ID"

# wait for sync
echo "Waiting 5 seconds"
sleep 5

# provision cert to WebUI
echo "Activating new certificate for WebUI (ID: $CERT_ID)..."

UPDATE_STATUS=$(midclt call system.general.update "{\"ui_certificate\": $CERT_ID}" 2>&1)

if [[ "$UPDATE_STATUS" == *"[E"* ]] || [[ "$UPDATE_STATUS" == *"Error"* ]]; then
    echo "CRITICAL ERROR: Activation failed. Stopping to prevent deletion."
    echo "Error details: $UPDATE_STATUS"
    exit 1
fi

echo "WebUI settings updated successfully."

# reload WebUI
echo "Restarting WebUI service..."
midclt call service.reload http

# clean old certificates
echo "Cleaning up old certificates..."
CURRENT_CERT_ID=$(midclt call system.general.config | jq -r '.ui_certificate.id')

if [ "$CURRENT_CERT_ID" != "$CERT_ID" ]; then
    echo "Warning: System is reporting Active ID $CURRENT_CERT_ID, but we just installed $CERT_ID. Skipping cleanup."
    exit 0
fi

midclt call certificate.query | jq -r ".[] | select(.name | startswith(\"Tailscale-Auto-\")) | select(.id != $CURRENT_CERT_ID) | .id" | while read -r OLD_ID; do
    echo "Deleting old certificate ID: $OLD_ID"
    midclt call certificate.delete "$OLD_ID"
done

echo "Success! WebUI updated to use $TS_DOMAIN"
