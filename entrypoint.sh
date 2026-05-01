#!/bin/bash
echo "============================================"
echo "  uisp-tester started"
echo "  $(date)"
echo "============================================"
cat /etc/motd

# Init
if [ ! -f /container-data/.initialized ]; then
  echo "[INIT] First run - setting up..."
  mkdir -p /container-data/logs
  touch /container-data/.initialized
fi

# === PGPass Setup ===
if [ -f /container-data/pgpass.txt ]; then
  echo "[PG] Found pgpass.txt - password ready for Python scripts"
else
  echo "[WARN] No pgpass.txt in container-data/ - Python scripts may fail"
fi

# Start UISP Helper web server
if [ -f /container-data/uisp-helper-server.py ]; then
  echo "[HELPER] Starting UISP Helper web server on port 9443..."
  mkdir -p /container-data/logs
  /usr/bin/python3 /container-data/uisp-helper-server.py >> /container-data/logs/uisp-helper.log 2>&1 &
  echo "[HELPER] Web server started (PID: $!)"
else
  echo "[WARN] uisp-helper-server.py not found - web server will not start"
fi

# Background monitor (optional)
[ -f /app/monitor-unms.sh ] && /app/monitor-unms.sh >> /container-data/logs/unms.log 2>&1 &

# Polling is now on-demand via /offline-devices endpoint
# The polling script runs with 10-second cache TTL when endpoint is hit
if [ -f /container-data/poll_unms_status.py ]; then
  echo "[POLLING] On-demand polling enabled"
  echo "[POLLING] Call /offline-devices or /offline-devices.json to trigger poll (10s cache)"
else
  echo "[WARN] poll_unms_status.py not found"
fi

exec "$@"