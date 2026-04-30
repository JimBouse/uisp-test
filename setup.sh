#!/bin/bash
set -euo pipefail

# === 1. Must be root =====================================================
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" >&2
   exit 1
fi

# === 2. Configuration ===================================================
COMPOSE_DIR="/opt/uisp-test"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
HOST_DATA_DIR="$COMPOSE_DIR/container-data"
TARGET_IN_CONTAINER="/container-data/pgpass.txt"
POLL_SCRIPT_IN_CONTAINER="/container-data/poll_unms_status.py"
POLL_SCRIPT_HOST="$HOST_DATA_DIR/poll_unms_status.py"
HOST_TARGET="$HOST_DATA_DIR/pgpass.txt"
INJECTOR_SCRIPT="/root/inject-pgpass.sh"
LOG_FILE="/var/log/inject-pgpass.log"
CRON_FILE="/etc/cron.d/inject-pgpass"
REPO_URL="https://github.com/JimBouse/uisp-test.git"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CANONICAL_SCRIPT="$COMPOSE_DIR/setup.sh"

# Source of secret
SRC_COMPOSE="/home/unms/app/docker-compose.yml"

INSTALL_USER="${SUDO_USER:-root}"
INSTALL_GROUP="$(id -gn "$INSTALL_USER" 2>/dev/null || echo root)"

cd /

# === 3. Bootstrap for fresh installs ====================================
if [[ "${1:-}" != "--no-bootstrap" && "$SCRIPT_PATH" != "$CANONICAL_SCRIPT" ]]; then
  echo "[+] Bootstrap mode detected"

  if ! command -v git >/dev/null 2>&1; then
    echo "[+] Installing git..."
    apt-get update
    apt-get install -y git
  fi

  if [[ ! -f "$CANONICAL_SCRIPT" ]]; then
    rm -rf "$COMPOSE_DIR"
    git clone "$REPO_URL" "$COMPOSE_DIR"
  fi

  echo "[+] Re-running installer from $CANONICAL_SCRIPT"
  exec bash "$CANONICAL_SCRIPT" --no-bootstrap
fi

# === 4. Ensure Docker + Compose are available ===========================
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "[+] Docker + Compose plugin found"
    return
  fi

  echo "[+] Installing Docker engine + Compose plugin..."
  apt-get update
  apt-get install -y docker.io docker-compose-plugin
  systemctl enable --now docker
}

ensure_docker

if [[ ! -f "$SRC_COMPOSE" ]]; then
  echo "[ERROR] Expected UISP compose file not found: $SRC_COMPOSE"
  echo "[ERROR] Install UISP first, then rerun this installer"
  exit 1
fi

# === 5. Create directories ==============================================
echo "[+] Creating directories..."
mkdir -p "$HOST_DATA_DIR"
mkdir -p "$(dirname "$INJECTOR_SCRIPT")"

# === 6. Validate Dockerfile + docker-compose.yml ========================
TEMP_DIR=$(mktemp -d)
EXPECTED_DOCKERFILE="$TEMP_DIR/Dockerfile.expected"
EXPECTED_COMPOSE="$TEMP_DIR/docker-compose.yml.expected"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

cat > "$EXPECTED_DOCKERFILE" <<'EOF'
# /opt/uisp-test/Dockerfile
FROM ubuntu:24.04

# Install tools and Python
RUN apt-get update && apt-get install -y wget \
    curl \
    jq \
    bash \
    cron \
    postgresql-client \
    dnsutils \
    net-tools \
    iputils-ping \
    openssl \
    ca-certificates \
    tzdata \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Python libraries for polling script
RUN apt-get update && apt-get install -y python3-psycopg2 python3-pandas && rm -rf /var/lib/apt/lists/*

# Timezone
ENV TZ=America/New_York
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Dirs
RUN mkdir -p /app /container-data /container-data/logs

# Copy files
COPY . /app/

# Scripts executable
RUN chmod +x /app/*.sh 2>/dev/null || true

WORKDIR /app

# MOTD
RUN echo '# uisp-tester ready!' > /etc/motd && \
    echo '# psql, curl, jq, dig, ping' >> /etc/motd && \
    echo '# Data: /container-data' >> /etc/motd

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["sleep", "infinity"]
EOF

cat > "$EXPECTED_COMPOSE" <<'EOF'
# /opt/uisp-test/docker-compose.yml
services:
  uisp-tester:
    build: .
    container_name: uisp-tester
    restart: unless-stopped
    volumes:
      - ./container-data:/container-data   # ← Now consistent
    networks:
      unms_public: {}
      unms_internal: {}
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://unms-api:8081/nms/api/v2.1/nms/version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

networks:
  unms_public:
    external: true
  unms_internal:
    external: true
EOF

check_or_prompt_replace() {
  local target_file="$1"
  local expected_file="$2"
  local label="$3"

  normalize_for_compare() {
    # Normalize line endings and ensure a trailing newline to avoid false mismatches.
    sed -e 's/\r$//' -e '$a\' "$1"
  }

  if [[ ! -f "$target_file" ]]; then
    echo "[WARN] $label missing: $target_file"
    cp "$expected_file" "$target_file"
    echo "[+] Created $label using expected template"
    return
  fi

  if diff -q <(normalize_for_compare "$target_file") <(normalize_for_compare "$expected_file") >/dev/null; then
    echo "[+] $label checked and in proper format"
    return
  fi

  echo "[WARN] $label differs from expected template"
  if [[ "$label" == "Dockerfile" ]]; then
    echo "[INFO] Required Dockerfile settings:"
    echo "  - Base image: ubuntu:24.04"
    echo "  - Includes psql/network tools/python3/cron"
    echo "  - Includes python3-psycopg2 and python3-pandas"
    echo "  - ENTRYPOINT is /app/entrypoint.sh"
    echo "  - CMD is sleep infinity"
  else
    echo "[INFO] Required docker-compose.yml settings:"
    echo "  - Service name: uisp-tester"
    echo "  - Uses local build context (build: .)"
    echo "  - Volume: ./container-data:/container-data"
    echo "  - Networks: unms_public and unms_internal"
    echo "  - Healthcheck against http://unms-api:8081/nms/api/v2.1/nms/version"
  fi

  while true; do
    echo "[INFO] Choose action for $label:"
    echo "  [R] Replace with expected template"
    echo "  [V] View full diff"
    echo "  [A] Abort setup"
    read -r -p "Enter R, V, or A: " REPLY
    case "$REPLY" in
      [Rr])
        cp "$expected_file" "$target_file"
        echo "[+] Replaced $label"
        break
        ;;
      [Vv])
        echo "[INFO] Diff (current -> expected):"
        diff -u "$target_file" "$expected_file" || true
        ;;
      [Aa]|"")
        echo "[ERROR] $label is not in required format; setup cannot continue"
        exit 1
        ;;
      *)
        echo "[WARN] Invalid choice. Please enter R, V, or A."
        ;;
    esac
  done

  if ! diff -q <(normalize_for_compare "$target_file") <(normalize_for_compare "$expected_file") >/dev/null; then
    echo "[ERROR] $label still differs after attempted replacement; setup cannot continue"
    exit 1
  fi
}

check_or_prompt_replace "$COMPOSE_DIR/Dockerfile" "$EXPECTED_DOCKERFILE" "Dockerfile"
check_or_prompt_replace "$COMPOSE_FILE" "$EXPECTED_COMPOSE" "docker-compose.yml"

# === 7. Create injector script ==========================================
echo "[+] Creating injector script: $INJECTOR_SCRIPT"
cat > "$INJECTOR_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

PGPASS=\$(grep -m1 'UNMS_POSTGRES_PASSWORD=' '$SRC_COMPOSE' |
         sed -E 's/.*UNMS_POSTGRES_PASSWORD=([^[:space:]]+).*/\1/')

if [[ -z "\$PGPASS" ]]; then
  echo "[\$(date)] ERROR: UNMS_POSTGRES_PASSWORD not found in $SRC_COMPOSE" >> $LOG_FILE
  exit 1
fi

mkdir -p "$HOST_DATA_DIR"
printf '%s\n' "\$PGPASS" > "$HOST_TARGET"
chmod 600 "$HOST_TARGET"

echo "[\$(date)] Injected pgpass (len \${#PGPASS}) → $HOST_TARGET" >> $LOG_FILE
EOF
chmod +x "$INJECTOR_SCRIPT"

# === 8. Install cron job ================================================
echo "[+] Installing cron job..."
cat > "$CRON_FILE" <<EOF
*/5 * * * * root $INJECTOR_SCRIPT >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"

# === 9. Ensure poll script exists =======================================
if [[ ! -f "$POLL_SCRIPT_HOST" ]]; then
  echo "[WARN] Missing poll script at $POLL_SCRIPT_HOST"
  echo "[+] Creating default poll script..."
  cat > "$POLL_SCRIPT_HOST" <<'EOF'
#!/usr/bin/env python3
import os
from datetime import datetime

import pandas as pd
import psycopg2

DB_HOST = os.getenv('DB_HOST', 'unms-postgres')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'unms')
DB_USER = os.getenv('DB_USER', 'unms')
DB_PASS = None

pgpass_path = os.path.expanduser('~/.pgpass')
if os.path.exists(pgpass_path):
  with open(pgpass_path) as f:
    for line in f:
      parts = line.strip().split(':')
      if len(parts) == 5 and parts[0] == DB_HOST and parts[2] == DB_NAME and parts[3] == DB_USER:
        DB_PASS = parts[4]
        break

if DB_PASS is None:
  DB_PASS = os.getenv('DB_PASS', '')

QUERY = """
SELECT
  COALESCE(ser.address_gps_lat, s.latitude) lat,
  COALESCE(ser.address_gps_lon, s.longitude) lon,
  regexp_replace(s.name, '\\.[a-zA-Z0-9,!?]', '', 'g') as name,
  s.updated_at as offline_since,
  ser.service_id,
  coalesce(d.data->>'port', 'Unknown') as upstream_port,
  coalesce(p.hostname, 'Unknown') as upstream_hostname,
  coalesce(split_part(p.ip::varchar, '/', 1), 'Unknown') as upstream_ip
FROM
  unms.site s,
  ucrm.service ser,
  ucrm.service_attribute sa,
  unms.device d,
  unms.device p
WHERE
  d.parent_id = p.device_id AND
  LOWER(d.mac::text) = LOWER(sa.value) AND
  s.ucrm_id::integer = ser.service_id AND
  ser.service_id = sa.service_id AND
  ser.status = 1 AND
  sa.attribute_id = 2 AND
  s.status = 'disconnected' AND
  s.type = 'endpoint' AND
  ser.client_id NOT IN (SELECT client_id FROM ucrm.client WHERE has_overdue_invoice = true) AND
  ser.service_id NOT IN (SELECT service_id FROM ucrm.service_attribute WHERE attribute_id = 36 AND value::int = 1) AND
  s.updated_at > NOW() - INTERVAL '30 days'
ORDER BY s.updated_at DESC
"""


def fetch_data():
  conn = psycopg2.connect(
    host=DB_HOST,
    port=DB_PORT,
    dbname=DB_NAME,
    user=DB_USER,
    password=DB_PASS,
  )
  df = pd.read_sql_query(QUERY, conn)
  conn.close()
  return df


def main():
  print(f"[{datetime.now()}] Fetching data...")
  df = fetch_data()
  df.to_csv('/container-data/unms_status.csv', index=False)
  print(df)


if __name__ == '__main__':
  main()
EOF
  chmod +x "$POLL_SCRIPT_HOST"
fi

# === 10. Run injection immediately =======================================
echo "[+] Running first injection..."
"$INJECTOR_SCRIPT"

# === 11. Build and start the container ==================================
echo "[+] Building and starting uisp-tester container..."
cd "$COMPOSE_DIR"
docker compose up -d --build uisp-tester

# === 12. Post-deploy self-test ==========================================
run_self_test() {
  local failures=0
  local health=""

  echo "[+] Running post-deploy self-test..."

  if docker ps --format '{{.Names}}' | grep -qx 'uisp-tester'; then
    echo "[PASS] Container exists: uisp-tester"
  else
    echo "[FAIL] Container not found: uisp-tester"
    failures=$((failures + 1))
  fi

  # Allow healthcheck to transition from "starting" to "healthy".
  for _ in {1..30}; do
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' uisp-tester 2>/dev/null || echo "missing")
    if [[ "$health" == "healthy" || "$health" == "none" ]]; then
      break
    fi
    sleep 3
  done

  if [[ "$health" == "healthy" || "$health" == "none" ]]; then
    echo "[PASS] Container health state: $health"
  else
    echo "[FAIL] Container health state: $health"
    failures=$((failures + 1))
  fi

  if docker exec uisp-tester bash -lc 'wget --spider -q http://unms-api:8081/nms/api/v2.1/nms/version'; then
    echo "[PASS] API endpoint reachable from container"
  else
    echo "[FAIL] API endpoint unreachable from container"
    failures=$((failures + 1))
  fi

  if docker exec uisp-tester bash -lc "psql -h unms-postgres -U unms -d unms -tAc 'SELECT 1' | grep -qx 1"; then
    echo "[PASS] PostgreSQL connectivity check"
  else
    echo "[FAIL] PostgreSQL connectivity check"
    failures=$((failures + 1))
  fi

  if docker exec uisp-tester bash -lc 'python3 /container-data/poll_unms_status.py >/tmp/poll-selftest.log 2>&1'; then
    echo "[PASS] Poll script execution"
  else
    echo "[FAIL] Poll script execution"
    docker exec uisp-tester bash -lc 'tail -n 40 /tmp/poll-selftest.log || true'
    failures=$((failures + 1))
  fi

  if docker exec uisp-tester bash -lc 'test -f /container-data/unms_status.csv'; then
    echo "[PASS] Output file present: /container-data/unms_status.csv"
  else
    echo "[FAIL] Output file missing: /container-data/unms_status.csv"
    failures=$((failures + 1))
  fi

  if [[ $failures -gt 0 ]]; then
    echo "[ERROR] Self-test failed with $failures issue(s)."
    exit 1
  fi

  echo "[+] Self-test passed"
}

run_self_test

# === 13. Ensure invoking user can manage workspace ======================
if [[ "$INSTALL_USER" != "root" ]]; then
  echo "[+] Granting workspace access to $INSTALL_USER:$INSTALL_GROUP"
  chown -R "$INSTALL_USER:$INSTALL_GROUP" "$COMPOSE_DIR"
fi

# === 14. Final status ====================================================
echo
echo "Installation complete!"
echo "  Container: uisp-tester"
echo "  Password file (in container): $TARGET_IN_CONTAINER"
echo "  Poll script (in container): $POLL_SCRIPT_IN_CONTAINER"
echo "  Password file (on host): $HOST_TARGET"
echo "  Cron: every 5 minutes → $CRON_FILE"
echo "  Log: $LOG_FILE"
echo
echo "Verify:"
echo "  docker exec uisp-tester cat $TARGET_IN_CONTAINER"
echo

# === 15. Setup logrotate for inject-pgpass.log ==========================
echo "[+] Configuring logrotate for inject-pgpass.log..."
cat > /etc/logrotate.d/inject-pgpass <<'EOF'
/var/log/inject-pgpass.log {
    daily
    rotate 1
    missingok
    notifempty
    compress
    delaycompress
    create 640 root root
    dateext
}
EOF
