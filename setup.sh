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
HOST_DATA_DIR="$COMPOSE_DIR/uisp-tester-data"
TARGET_IN_CONTAINER="/container-data/pgpass.txt"
HOST_TARGET="$HOST_DATA_DIR/pgpass.txt"
INJECTOR_SCRIPT="/root/inject-pgpass.sh"
LOG_FILE="/var/log/inject-pgpass.log"
CRON_FILE="/etc/cron.d/inject-pgpass"

# Source of secret
SRC_COMPOSE="/home/unms/app/docker-compose.yml"

# === 3. Create directories ==============================================
echo "[+] Creating directories..."
mkdir -p "$HOST_DATA_DIR"
mkdir -p "$(dirname "$INJECTOR_SCRIPT")"

# === 4. Create Dockerfile ===============================================
echo "[+] Writing Dockerfile..."
cat > "$COMPOSE_DIR/Dockerfile" <<'EOF'
FROM ubuntu:24.04

# Install tools and Python
RUN apt-get update && apt-get install -y wget curl jq bash postgresql-client dnsutils net-tools iputils-ping openssl ca-certificates tzdata python3 python3-pip python3-psycopg2 python3-pandas && rm -rf /var/lib/apt/lists/*

WORKDIR /container-data
EOF

# === 5. Create docker-compose.yml for uisp-tester =======================
echo "[+] Writing docker-compose.yml..."
cat > "$COMPOSE_FILE" <<'EOF'
services:
  uisp-tester:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: uisp-tester
    command: sleep infinity
    restart: unless-stopped
    volumes:
      - ./uisp-tester-data:/container-data
    networks:
      unms_public: {}
      unms_internal: {}
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://unms-api:8081/health"]
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

# === 6. Create injector script ==========================================
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

# === 7. Install cron job ================================================
echo "[+] Installing cron job..."
cat > "$CRON_FILE" <<EOF
*/5 * * * * root $INJECTOR_SCRIPT >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"

# === 8. Build and start the container ===================================
echo "[+] Building and starting uisp-tester container..."
cd "$COMPOSE_DIR"
docker compose up -d --build uisp-tester

# === 9. Run injection immediately =======================================
echo "[+] Running first injection..."
"$INJECTOR_SCRIPT"

# === 10. Final status ===================================================
echo
echo "Installation complete!"
echo "  Container: uisp-tester"
echo "  Password file (in container): $TARGET_IN_CONTAINER"
echo "  Password file (on host): $HOST_TARGET"
echo "  Cron: every 5 minutes → $CRON_FILE"
echo "  Log: $LOG_FILE"
echo
echo "Verify:"
echo "  docker exec uisp-tester cat $TARGET_IN_CONTAINER"
echo

# === 11. Setup logrotate for inject-pgpass.log ==========================
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
