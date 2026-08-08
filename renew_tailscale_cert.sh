#!/bin/bash

# cronjob paths
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DOCKER_HOST=unix:///var/run/docker.sock

# Script Config, please replace TS_DOMAIN with your machine-name.tailnet-name.ts.net
TS_DOMAIN="machine-name.tailnet-name.ts.net"
CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i tailscale | head -n 1)
CERT_NAME="Tailscale-Auto-$(date +%Y%m%d-%H%M%S)"

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: Tailscale container not found. (Docker Socket check: $(ls -l /var/run/docker.sock))"
    exit 1
fi
echo "Found Tailscale container: $CONTAINER_NAME"

echo "Generating certificate for $TS_DOMAIN..."
docker exec "$CONTAINER_NAME" tailscale cert "$TS_DOMAIN"
docker exec "$CONTAINER_NAME" cat "$TS_DOMAIN.crt" > /tmp/ts_cert.crt
docker exec "$CONTAINER_NAME" cat "$TS_DOMAIN.key" > /tmp/ts_key.key

if [ ! -s /tmp/ts_cert.crt ] || [ ! -s /tmp/ts_key.key ]; then
    echo "Error: Failed to retrieve certificate files."
    rm -f /tmp/ts_cert.crt /tmp/ts_key.key
    exit 1
fi

CERT_NAME="$CERT_NAME" TS_DOMAIN="$TS_DOMAIN" python3 <<'EOF'
import os
import sys
import time
from truenas_api_client import Client

cert_name = os.environ["CERT_NAME"]
ts_domain = os.environ["TS_DOMAIN"]

try:
    with Client() as c:
        print(f"Importing certificate '{cert_name}' into TrueNAS...")
        cert = c.call('certificate.create', {
            'name': cert_name,
            'certificate': open('/tmp/ts_cert.crt').read(),
            'privatekey': open('/tmp/ts_key.key').read(),
            'create_type': 'CERTIFICATE_CREATE_IMPORTED',
        }, job=True)
        cert_id = cert['id']
        print(f"Certificate imported successfully. ID: {cert_id}")

        print("Waiting 5 seconds")
        time.sleep(5)

        print(f"Activating new certificate for WebUI (ID: {cert_id})...")
        c.call('system.general.update', {'ui_certificate': cert_id})
        print("WebUI settings updated successfully.")

        print("Restarting WebUI service...")
        c.call('service.reload', 'http')

        current_id = c.call('system.general.config')['ui_certificate']['id']
        if current_id != cert_id:
            print(f"Warning: System is reporting Active ID {current_id}, "
                  f"but we just installed {cert_id}. Skipping cleanup.")
            sys.exit(0)

        print("Cleaning up old certificates...")
        for old in c.call('certificate.query'):
            if old['name'].startswith('Tailscale-Auto-') and old['id'] != current_id:
                print(f"Deleting old certificate ID: {old['id']}")
                c.call('certificate.delete', old['id'])

        print(f"Success! WebUI updated to use {ts_domain}")

except Exception as e:
    print(f"CRITICAL ERROR: {e}")
    sys.exit(1)
EOF
PYTHON_EXIT=$?

rm -f /tmp/ts_cert.crt /tmp/ts_key.key

exit $PYTHON_EXIT
