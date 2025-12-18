#!/bin/sh
set -eu

CDC_SERVER="http://ticdc:8300"
SINK_URI="kafka://kafka:9092/app_cdc?protocol=canal-json&partition-num=1&replication-factor=1"
CHANGEFEED_ID="app-changefeed"

echo "[cdc-init] waiting for TiCDC CLI/API... (${CDC_SERVER})"
ok=0
for i in $(seq 1 180); do
  if /cdc cli changefeed list --server "${CDC_SERVER}" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  echo "[cdc-init] ERROR: TiCDC not reachable"
  exit 1
fi

echo "[cdc-init] waiting for Kafka broker... (kafka:9092)"
for i in $(seq 1 120); do
  (echo > /dev/tcp/kafka/9092) >/dev/null 2>&1 && break || true
  sleep 2
done

echo "[cdc-init] checking existing changefeeds..."
if /cdc cli changefeed list --server "${CDC_SERVER}" | grep -q "${CHANGEFEED_ID}"; then
  echo "[cdc-init] changefeed '${CHANGEFEED_ID}' already exists - skipping."
  exit 0
fi

echo "[cdc-init] creating changefeed '${CHANGEFEED_ID}' -> ${SINK_URI}"
/cdc cli changefeed create \
  --server "${CDC_SERVER}" \
  --changefeed-id "${CHANGEFEED_ID}" \
  --sink-uri "${SINK_URI}"

echo "[cdc-init] done."
