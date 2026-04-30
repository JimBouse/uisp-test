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

exec "$@"