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
curl -fsSL https://raw.githubusercontent.com/JimBouse/uisp-test/refs/heads/master/setup.sh | sudo bash
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
- Polls the UISP PostgreSQL database every 5 minutes (configurable)
- Identifies offline devices and gathers their details
- Generates a CSV report: `/container-data/unms_status.csv`
- Maintains polling logs in `/container-data/logs/poll-unms.log`
- Automatically refreshes the PostgreSQL password every 5 minutes

## Verification

After installation, verify the setup:

```bash
# Check container status
docker ps | grep uisp-tester

# View the generated CSV
cat /opt/uisp-test/container-data/unms_status.csv

# Check the polling logs
tail -f /opt/uisp-test/container-data/logs/poll-unms.log

# Verify password was injected
docker exec uisp-tester cat /container-data/pgpass.txt
```

## Configuration

### Environment Variables

Inside the container, the polling script uses:
- `DB_HOST` — PostgreSQL host (default: `unms-postgres`)
- `DB_PORT` — PostgreSQL port (default: `5432`)
- `DB_NAME` — Database name (default: `unms`)
- `DB_USER` — Database user (default: `unms`)
- `DB_PASS` — Auto-injected from `/container-data/pgpass.txt`

### Polling Frequency

The polling script runs on a schedule defined by cron in the container. Modify `/etc/cron.d/inject-pgpass` on the host to adjust frequency (default: every 5 minutes).

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

This is normal in a dev environment with no devices. Check the logs:

```bash
tail -50 /opt/uisp-test/container-data/logs/poll-unms.log
```

### PostgreSQL connection errors

Verify database connectivity from the container:

```bash
docker exec uisp-tester psql -h unms-postgres -U unms -d unms -c "SELECT 1"
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

## License

See repository for license information.
