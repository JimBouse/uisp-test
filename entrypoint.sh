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
  echo "[PG] Found pgpass.txt - installing for psql..."
  PGPASS=$(head -n 1 /container-data/pgpass.txt | tr -d '\r\n')
  echo "unms-postgres:5432:unms:unms:$PGPASS" > /root/.pgpass
  chmod 600 /root/.pgpass
  echo "[PG] psql auto-login ready: psql -h unms-postgres -U unms unms"
else
  echo "[WARN] No pgpass.txt in container-data/ - psql will prompt for password"
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