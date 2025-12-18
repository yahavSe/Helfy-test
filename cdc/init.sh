#!/bin/sh
set -eux

CDC_SERVER="http://ticdc:8300"
SINK_URI="kafka://kafka:9092/app_cdc?protocol=canal-json&partition-num=1&replication-factor=1"
CHANGEFEED_ID="app-changefeed"

echo "[cdc-init] waiting for TiCDC..."
for i in $(seq 1 120); do
  wget -qO- "${CDC_SERVER}/api/v2/status" >/dev/null 2>&1 && break
  sleep 2
done

echo "[cdc-init] existing changefeeds:"
/cdc cli changefeed list --server "${CDC_SERVER}" || true

if /cdc cli changefeed list --server "${CDC_SERVER}" | grep -q "${CHANGEFEED_ID}"; then
  echo "[cdc-init] ${CHANGEFEED_ID} already exists"
  exit 0
fi

echo "[cdc-init] creating ${CHANGEFEED_ID} -> ${SINK_URI}"
/cdc cli changefeed create \
  --server "${CDC_SERVER}" \
  --changefeed-id "${CHANGEFEED_ID}" \
  --sink-uri "${SINK_URI}"

echo "[cdc-init] created. changefeeds now:"
/cdc cli changefeed list --server "${CDC_SERVER}"
