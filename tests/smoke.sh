#!/usr/bin/env bash
set -euo pipefail

banner() {
  echo "==============================="
  echo "🧪 Helfy smoke test starting..."
  echo "==============================="
}

fail() { echo "❌ $*" >&2; exit 1; }
pass() { echo "✅ $*"; }

wait_http() {
  local name="$1" url="$2" timeout="${3:-180}"
  echo "⏳ waiting for ${name}: ${url} (timeout ${timeout}s)"
  local start now
  start="$(date +%s)"
  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then pass "${name} is up"; return 0; fi
    now="$(date +%s)"
    (( now - start > timeout )) && fail "${name} not reachable after ${timeout}s: ${url}"
    sleep 2
  done
}

wait_mysql() {
  local timeout="${1:-240}"
  echo "⏳ waiting for TiDB mysql ping: tidb:4000 (timeout ${timeout}s)"
  local start now
  start="$(date +%s)"
  while true; do
    if mysql -h tidb -P 4000 -u root -e "SELECT 1" >/dev/null 2>&1; then
      pass "TiDB mysql is up"; return 0
    fi
    now="$(date +%s)"
    (( now - start > timeout )) && fail "TiDB mysql not reachable after ${timeout}s"
    sleep 2
  done
}

# ===== Consumer metrics helpers =====
metric_value() {
  # Usage: metric_value 'cdc_events_total\{table="orders",op="insert"\}'
  local pattern="$1"
  curl -fsS http://consumer:9102/metrics \
    | awk -v pat="$pattern" '$0 ~ pat {print $2; found=1} END { if(!found) print 0 }'
}

wait_metric_increase() {
  # waits until metric increases above before within timeout
  local label="$1" pattern="$2" before="$3" timeout="${4:-60}"
  echo "🧪 validating ${label} metric increments (retrying up to ${timeout}s)"
  local start now after
  start="$(date +%s)"
  while true; do
    after="$(metric_value "$pattern")"
    if awk "BEGIN {exit !($after > $before)}"; then
      pass "${label} observed (counter ${before} -> ${after})"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      echo "🔎 Debug: consumer metrics snippet:"
      curl -fsS http://consumer:9102/metrics | grep -E '^cdc_events_total' || true
      fail "${label} not observed within ${timeout}s"
    fi
    sleep 2
  done
}

# ===== Kafka helpers =====
kafka_has() {
  # Search last N messages for a substring
  local needle="$1" tail="${2:-300}"
  kcat -b kafka:9092 -t app_cdc -C -o "-${tail}" -c "${tail}" -e -q 2>/dev/null \
    | grep -F "$needle" >/dev/null 2>&1
}

wait_kafka_has() {
  local label="$1" needle="$2" timeout="${3:-45}"
  echo "🧪 validating ${label} appears in Kafka (retrying up to ${timeout}s)"
  local start now
  start="$(date +%s)"
  while true; do
    if kafka_has "$needle" 400; then
      pass "Kafka contains ${label}"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      echo "🔎 Debug: showing last 20 Kafka messages:"
      kcat -b kafka:9092 -t app_cdc -C -o -20 -c 20 -e 2>/dev/null || true
      fail "Kafka validation failed: ${label} not observed"
    fi
    sleep 3
  done
}

# ===== Prometheus helpers =====
prom_query() {
  local q="$1"
  curl -fsS "http://prometheus:9090/api/v1/query" --data-urlencode "query=${q}" \
    | jq -r '.data.result[0].value[1] // empty'
}

wait_prom_equals() {
  local label="$1" query="$2" expected="$3" timeout="${4:-60}"
  echo "🧪 validating Prometheus: ${label} (retrying up to ${timeout}s)"
  local start now val
  start="$(date +%s)"
  while true; do
    val="$(prom_query "$query" || true)"
    if [ -n "$val" ] && awk "BEGIN{exit !($val == $expected)}"; then
      pass "Prometheus OK: ${label} = ${val}"
      return 0
    fi
    now="$(date +%s)"
    (( now - start > timeout )) && fail "Prometheus validation failed for ${label} (got '${val}', expected '${expected}')"
    sleep 2
  done
}

# ===== Elasticsearch helpers =====
es_count_recent_consumer_logs() {
  # Resilient query: try multiple common fields
  curl -fsS "http://elasticsearch:9200/_search" -H "Content-Type: application/json" -d @- <<'JSON' \
  | jq -r '.hits.total.value // 0'
{
  "size": 0,
  "query": {
    "bool": {
      "filter": [
        { "range": { "@timestamp": { "gte": "now-10m" } } }
      ],
      "should": [
        { "term": { "container.name": "consumer" } },
        { "term": { "docker.container.name": "consumer" } },
        { "match_phrase": { "message": "cdc_event" } },
        { "match_phrase": { "msg": "cdc_event" } }
      ],
      "minimum_should_match": 1
    }
  }
}
JSON
}

wait_es_min_docs() {
  local min="${1:-1}" timeout="${2:-90}"
  echo "🧪 validating Elasticsearch has recent CDC/consumer logs (>=${min}) (retrying up to ${timeout}s)"
  local start now c
  start="$(date +%s)"
  while true; do
    c="$(es_count_recent_consumer_logs || echo 0)"
    if [ "${c}" -ge "${min}" ]; then
      pass "Elasticsearch OK: recent docs = ${c}"
      return 0
    fi
    now="$(date +%s)"
    (( now - start > timeout )) && fail "Elasticsearch validation failed: only ${c} docs in last 10m"
    sleep 3
  done
}

main() {
  banner

  wait_http "PD" "http://pd:2379/pd/api/v1/version" 180
  wait_mysql 240
  wait_http "TiCDC API" "http://ticdc:8300/api/v2/status" 180
  wait_http "Prometheus" "http://prometheus:9090/-/ready" 180
  wait_http "Consumer /healthz" "http://consumer:9102/healthz" 180
  wait_http "Elasticsearch" "http://elasticsearch:9200" 180

  echo "🔎 checking TiDB schema (app.orders exists)"
  mysql -h tidb -P 4000 -u root -e "USE app; SHOW TABLES LIKE 'orders';" | grep -q orders \
    || fail "orders table not found in app DB"
  pass "TiDB schema OK (orders table exists)"

  # ---------- Scenario A: INSERT ----------
  local insert_before
  insert_before="$(metric_value 'cdc_events_total\{table="orders",op="insert"\}')"

  local cents id
  cents="$(( (RANDOM % 5000) + 40000 ))"
  echo "🧪 [INSERT] inserting into app.orders (amount_cents=${cents})"
  mysql -h tidb -P 4000 -u root -e "USE app; INSERT INTO orders (user_id, amount_cents, status) VALUES (1, ${cents}, 'created'); SELECT LAST_INSERT_ID();" \
    | tail -n 1 | tr -d '\r' | grep -E '^[0-9]+$' >/tmp/last_id || true
  id="$(cat /tmp/last_id 2>/dev/null || echo "")"
  [ -n "$id" ] || fail "Could not read LAST_INSERT_ID()"

  pass "[INSERT] Inserted test row into TiDB (id=${id})"
  wait_metric_increase "[INSERT] consumer orders/insert" 'cdc_events_total\{table="orders",op="insert"\}' "$insert_before" 60
  wait_kafka_has "[INSERT] amount_cents=${cents}" "\"type\":\"INSERT\"" 45
  wait_kafka_has "[INSERT] amount_cents=${cents}" "\"amount_cents\":\"${cents}\"" 45

  # ---------- Scenario B: UPDATE ----------
  local update_before
  update_before="$(metric_value 'cdc_events_total\{table="orders",op="update"\}')"

  local cents2
  cents2="$(( cents + 111 ))"
  echo "🧪 [UPDATE] updating app.orders id=${id} (amount_cents=${cents2}, status=paid)"
  mysql -h tidb -P 4000 -u root -e "USE app; UPDATE orders SET amount_cents=${cents2}, status='paid' WHERE id=${id};" \
    || fail "Update failed"

  pass "[UPDATE] Updated test row in TiDB"
  wait_metric_increase "[UPDATE] consumer orders/update" 'cdc_events_total\{table="orders",op="update"\}' "$update_before" 60
  wait_kafka_has "[UPDATE] id=${id}" "\"type\":\"UPDATE\"" 45
  wait_kafka_has "[UPDATE] new amount_cents=${cents2}" "\"amount_cents\":\"${cents2}\"" 45
  wait_kafka_has "[UPDATE] status=paid" "\"status\":\"paid\"" 45

  # ---------- Scenario C: DELETE ----------
  local delete_before
  delete_before="$(metric_value 'cdc_events_total\{table="orders",op="delete"\}')"

  echo "🧪 [DELETE] deleting app.orders id=${id}"
  mysql -h tidb -P 4000 -u root -e "USE app; DELETE FROM orders WHERE id=${id};" \
    || fail "Delete failed"
  pass "[DELETE] Deleted test row in TiDB"

  wait_metric_increase "[DELETE] consumer orders/delete" 'cdc_events_total\{table="orders",op="delete"\}' "$delete_before" 60
  wait_kafka_has "[DELETE] id=${id}" "\"type\":\"DELETE\"" 45

  # ---------- Scenario D: Prometheus API checks ----------
  wait_prom_equals "cdc-consumer target is up" 'up{job="cdc-consumer"}' 1 60

  # ---------- Scenario E: Elasticsearch has recent docs ----------
  wait_es_min_docs 1 90

  echo "==============================="
  echo "✅ Smoke test PASSED"
  echo "==============================="
}

main
