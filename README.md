# UISP Tester

A Docker-based utility container that polls the UISP (Ubiquiti Intelligent Service Platform) system for offline devices and generates status reports.

## Prerequisites

- UISP system already installed and running on the host
- Docker and Docker Compose installed (installer will install if missing)
- Root/sudo access
- Linux system

## Installation

Run this one-line installer:

```bash
curl -fsSL https://raw.githubusercontent.com/JimBouse/uisp-test/refs/heads/master/setup.sh > /tmp/uisp-helper-setup.sh && sudo bash /tmp/uisp-helper-setup.sh
```

### What the installer does:

1. **Clones the repository** — if not already present at `/opt/uisp-test`
2. **Installs Docker** — if not already installed
3. **Validates configuration** — ensures Dockerfile and docker-compose.yml are properly configured
4. **Creates password injector** — extracts PostgreSQL password from UISP every 5 minutes
5. **Builds container** — builds the uisp-tester Docker image
6. **Starts container** — runs the container with Docker Compose
7. **Runs self-tests** — validates container health, API connectivity, database access, and polling functionality
8. **Sets up log rotation** — configures logrotate for cleaner log management

## What it does

The uisp-tester container:
- Runs an HTTPS web server on port 9443 (serves uisp-helper tools)
- Provides on-demand polling of UISP offline devices (triggered by API requests)
- Caches polling results for 10 seconds to avoid excessive database queries
- Identifies offline devices and gathers their details
- Generates a CSV report: `/container-data/unms_status.csv`
- Automatically refreshes the PostgreSQL password from UISP

## Web Server

The uisp-helper web server provides:

**Port:** 9443 HTTPS
**SSL Certificate:** Uses UNMS Let's Encrypt certificates

**Available Endpoints:**
- `GET /` - HTML status page
- `GET /status` - JSON server status
- `GET /offline-devices` - CSV file of offline devices
- `GET /offline-devices.json` - JSON format offline devices

**Examples:**
```bash
# Get JSON status
curl -k https://your-host:9443/status

# Download offline devices as CSV
curl -k https://your-host:9443/offline-devices -o devices.csv

# Get JSON data
curl -k https://your-host:9443/offline-devices.json
```

**Access:**
```
https://your-host:9443/
```

## Verification

After installation, verify the setup:

```bash
# Check container status
docker ps | grep uisp-tester

# Verify password was injected
docker exec uisp-tester cat /container-data/pgpass.txt

# Test the web server
curl -k https://localhost:9443/status

# Trigger polling and get offline devices (will cache for 10 seconds)
curl -k https://localhost:9443/offline-devices.json | python3 -m json.tool

# View the generated CSV
cat /opt/uisp-test/container-data/unms_status.csv

# View HTML status page (in browser)
https://your-host:9443/
```

## Configuration

### Environment Variables

No special environment variables needed. The container automatically:
- Detects PostgreSQL credentials from UISP
- Loads UNMS Let's Encrypt certificates
- Configures polling on-demand with 10-second cache TTL

### Polling Behavior

Polling is **on-demand** and **cached**:
- When you hit `/offline-devices` or `/offline-devices.json`, the polling script executes
- Results are cached for **10 seconds**
- Subsequent requests within 10 seconds return cached data (fast)
- After 10 seconds, the next request triggers a fresh poll
- This avoids hammering the database with frequent requests

**No data appears until the first API request is made to the `/offline-devices*` endpoints.**

## Output

**Location:** `/opt/uisp-test/container-data/unms_status.csv`

**Columns:**
- `lat` — Device latitude
- `lon` — Device longitude
- `name` — Device name
- `offline_since` — When the device went offline
- `service_id` — UISP service ID
- `upstream_port` — Upstream connection port
- `upstream_hostname` — Upstream device hostname
- `upstream_ip` — Upstream device IP address

## Logs

**Polling logs:** `/opt/uisp-test/container-data/logs/poll-unms.log`

**Password injection logs:** `/var/log/inject-pgpass.log`

## Troubleshooting

### No data in CSV

CSV is generated on-demand. To trigger polling:

```bash
# Trigger polling with API request
curl -k https://localhost:9443/offline-devices.json

# Then check the CSV file
cat /opt/uisp-test/container-data/unms_status.csv

# Or if running remotely
curl -k https://your-host:9443/offline-devices.json
```

If the CSV is still empty, you likely have no offline devices in your UISP system (normal).

### No API response

Verify the container is running:

```bash
docker ps | grep uisp-tester
```

If not running, check logs:

```bash
docker logs uisp-tester
```

Make sure port 9443 is accessible and SSL certificate is loaded.
```

### API unreachable

Verify the container can reach the UISP API:

```bash
docker exec uisp-tester wget --spider -q http://unms-api:8081/nms/api/v2.1/nms/version
echo $?  # 0 = success
```

## Network

The container connects to UISP networks:
- `unms_public` — for API access
- `unms_internal` — for database access

These networks are created by UISP and must exist before the container starts.

## Uninstallation

To completely remove the uisp-tester container and all associated resources:

### 1. Stop and remove the container

```bash
docker compose -f /opt/uisp-test/docker-compose.yml down
```

### 2. Remove the cron job

```bash
sudo rm /etc/cron.d/inject-pgpass
```

### 3. Remove the injector script (optional)

```bash
sudo rm /root/inject-pgpass.sh
```

### 4. Remove the logs (optional)

```bash
sudo rm /var/log/inject-pgpass.log
sudo rm -rf /opt/uisp-test/container-data/logs/
```

### 5. Remove the entire workspace (optional)

```bash
sudo rm -rf /opt/uisp-test
```

**Note:** Only remove the workspace directory if you no longer need the polling data, configuration files, and CSV reports.

## License

See repository for license information.
