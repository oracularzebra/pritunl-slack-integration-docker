#!/bin/sh
set -e

CONFIG_PATH="${CONFIG_PATH:-/app/config.json}"
POLLER_INTERVAL="${POLLER_INTERVAL:-10}"

echo "Starting Pritunl Slack Integration..."
echo "Config path: $CONFIG_PATH"
echo "Poller interval: ${POLLER_INTERVAL}s"

cleanup() {
    echo "Shutting down..."
    kill $GUNICORN_PID 2>/dev/null
    wait $GUNICORN_PID 2>/dev/null
    exit 0
}
trap cleanup TERM INT

export CONFIG_PATH

gunicorn -b 0.0.0.0:5001 \
    --access-logfile - \
    --error-logfile - \
    --log-level info \
    --timeout 30 \
    webhook_server:app &
GUNICORN_PID=$!

sleep 2

while true; do
    python update_routes.py --config "$CONFIG_PATH" 2>&1
    sleep "$POLLER_INTERVAL"
done
