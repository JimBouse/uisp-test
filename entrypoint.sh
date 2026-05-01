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
install_pgpass() {
  if [ -f /container-data/pgpass.txt ]; then
    PGPASS=$(head -n 1 /container-data/pgpass.txt | tr -d '\r\n')
    printf 'unms-postgres:5432:unms:unms:%s\n' "$PGPASS" > /root/.pgpass
    chmod 600 /root/.pgpass
  fi
}

if [ -f /container-data/pgpass.txt ]; then
  echo "[PG] Found pgpass.txt - installing for psql..."
  install_pgpass
  echo "[PG] psql auto-login ready: psql -h unms-postgres -U unms unms"
else
  echo "[WARN] No pgpass.txt in container-data/ - psql will prompt for password"
fi

# Watch pgpass.txt for changes and refresh ~/.pgpass immediately
(
  while inotifywait -e close_write /container-data/pgpass.txt 2>/dev/null; do
    install_pgpass
    echo "[PG] pgpass.txt changed - ~/.pgpass refreshed"
  done
) &

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

# Schedule polling script with cron (optional)
if [ -f /container-data/poll_unms_status.py ]; then
  echo "[CRON] Configuring poll_unms_status.py schedule..."
  cat > /etc/cron.d/poll-unms-status <<'EOF'
*/5 * * * * root /usr/bin/python3 /container-data/poll_unms_status.py >> /container-data/logs/poll-unms.log 2>&1
EOF
  chmod 644 /etc/cron.d/poll-unms-status
  touch /container-data/logs/poll-unms.log

  if command -v cron >/dev/null 2>&1; then
    cron
    echo "[CRON] Started: every 5 minutes -> /container-data/poll_unms_status.py"
  else
    echo "[WARN] cron binary not found - polling schedule not started"
  fi
fi

exec "$@"