#!/usr/bin/env bash
# Register the Iceberg sink (POST) to a Kafka Connect worker.
# Default matches docker-compose: connect service is localhost:8084
#
# If POST fails with "Failed to find any class ... IcebergSinkConnector":
# - Ensure Iceberg is on CONNECT_PLUGIN_PATH (see docker-compose.yml).
# - Kafka 7.x may use plugin.discovery=service_load; Iceberg JARs need hybrid/scan mode.
#   Add to the Connect container: CONNECT_PLUGIN_DISCOVERY=hybrid_warn then restart Connect.
# - curl http://localhost:8084/connector-plugins | grep -i iceberg  must list IcebergSinkConnector.
# - Task FAILED with Mkdirs ... file:/Users/.../iceberg-warehouse: Spark on macOS put that path in
#   Iceberg metadata; run ./scripts/sync-connect-warehouse-host-path.sh then
#   docker compose up -d --force-recreate connect
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONNECT_URL="${KAFKA_CONNECT_URL:-http://localhost:8084}"
JSON="${ROOT}/connectors/register-iceberg-sink.json"

if [[ ! -f "$JSON" ]]; then
  echo "Missing $JSON" >&2
  exit 1
fi

echo "Kafka Connect: $CONNECT_URL"
echo "Registering connector from $JSON"

# Re-register: delete if it already exists
if curl -fsS -o /dev/null "$CONNECT_URL/connectors/iceberg-sink" 2>/dev/null; then
  echo "Deleting existing connector iceberg-sink..."
  curl -sS -X DELETE "$CONNECT_URL/connectors/iceberg-sink"
  sleep 1
fi

echo "Creating connector..."
curl -sS -X POST \
  -H "Content-Type: application/json" \
  --data-binary "@$JSON" \
  "$CONNECT_URL/connectors"

echo
echo "Status (Connect may not expose status for a few seconds after create):"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if out="$(curl -fsS "$CONNECT_URL/connectors/iceberg-sink/status" 2>/dev/null)"; then
    echo "$out"
    exit 0
  fi
  sleep 1
done
echo "Still no /status for iceberg-sink after ~10s. Is Connect up at $CONNECT_URL ?" >&2
curl -sS "$CONNECT_URL/connectors/iceberg-sink/status" || true
echo
