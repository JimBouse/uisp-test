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

# === 4. Validate Dockerfile + docker-compose.yml ========================
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

# === 10. Post-deploy self-test ==========================================
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

# === 11. Final status ===================================================
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

# === 12. Setup logrotate for inject-pgpass.log ==========================
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
