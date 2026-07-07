#!/bin/sh

CONFIG_PATH="${CONFIG_PATH:-/app/config.json}"
POLLER_INTERVAL="${POLLER_INTERVAL:-10}"
LOG_DIR="${LOG_DIR:-/var/log/pritunl-docker}"

mkdir -p "$LOG_DIR"
export LOG_DIR

cleanup() {
    echo "Shutting down..."
    kill $GUNICORN_PID 2>/dev/null
    wait $GUNICORN_PID 2>/dev/null
    exit 0
}
trap cleanup TERM INT

export CONFIG_PATH

gunicorn -b 0.0.0.0:5001 \
    --access-logfile /var/log/pritunl-docker/webhook-access.log \
    --error-logfile /var/log/pritunl-docker/webhook-error.log \
    --log-level info \
    --timeout 30 \
    webhook_server:app &
GUNICORN_PID=$!

sleep 2

if ! kill -0 $GUNICORN_PID 2>/dev/null; then
    echo "gunicorn failed to start" >&2
    exit 1
fi
echo "gunicorn started (PID: $GUNICORN_PID)"
echo "Starting poller loop (interval: ${POLLER_INTERVAL}s)"

while true; do
    python update_routes.py --config "$CONFIG_PATH" >> /var/log/pritunl-docker/route-updater.log 2>&1 || true
    sleep "$POLLER_INTERVAL"
done
