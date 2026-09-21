#!/bin/bash
# Installs and runs the official open-source Postgres image on Docker.
# No Broadcom account needed - use this instead of install-tanzu-postgres.sh
# when a customer doesn't have Tanzu registry access. Mirrors the manual
# steps in tanzu-postgres-docker-guide.md. Safe to re-run.
set -euo pipefail

# ---- defaults (override with flags or env vars) ----
CONTAINER_NAME="${CONTAINER_NAME:-postgres-oss}"
HOST_PORT="${HOST_PORT:-5432}"
PG_VERSION="${PG_VERSION:-latest}"
PG_USER="${PG_USER:-appuser}"
PG_DB="${PG_DB:-${PG_USER}}"
PG_PASSWORD="${PG_PASSWORD:-}"
DATA_DIR="${DATA_DIR:-/data/postgres-oss}"
IMAGE="postgres:${PG_VERSION}"
WITH_DOCKER=0
FRESH=0
declare -a TUNING_ARGS=()

usage() {
  cat <<EOF
Usage: $0 [options]

Installs Docker (if requested), pulls the official open-source Postgres
image from Docker Hub (no login needed), and starts it as a container.

Options:
  --name NAME           Container name (default: ${CONTAINER_NAME})
  --port PORT           Host port to map to Postgres' 5432 (default: ${HOST_PORT})
  --version VERSION     Image tag to pull (default: ${PG_VERSION})
  --pg-user USER        Postgres superuser to create (default: ${PG_USER})
  --pg-db DB            Default database name (default: same as --pg-user)
  --pg-password PASS    Postgres password (default: auto-generated, printed at the end) -
                         the official image refuses to start without one either way
  --data-dir PATH       Host directory for Postgres data (default: ${DATA_DIR})
  --set KEY=VALUE       Extra postgresql.conf tuning, passed as "-c KEY=VALUE" to the
                         container (e.g. --set max_connections=200). Repeatable. Unlike
                         Tanzu's env vars, these apply on every restart, not just the
                         first initdb.
  --with-docker         Install Docker first if it's not already present
  --fresh               Wipe --data-dir before starting, so --pg-user/--pg-password/
                         --pg-db actually take effect. Use this if you've run the
                         script before against the same data dir with different values.
  -h, --help            Show this help and exit

Examples:
  sudo ./install-postgres-opensource.sh --with-docker
  sudo ./install-postgres-opensource.sh --pg-password 'S3cret!' --set max_connections=200
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    --port) HOST_PORT="$2"; shift 2 ;;
    --version) PG_VERSION="$2"; IMAGE="postgres:${PG_VERSION}"; shift 2 ;;
    --pg-user) PG_USER="$2"; shift 2 ;;
    --pg-db) PG_DB="$2"; shift 2 ;;
    --pg-password) PG_PASSWORD="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --set) TUNING_ARGS+=(-c "$2"); shift 2 ;;
    --with-docker) WITH_DOCKER=1; shift ;;
    --fresh) FRESH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This needs root. Try: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Open-source Postgres on Docker =="
echo

# ---- Step 1: Docker present? ----
echo "Step 1/6: Checking for Docker..."
if ! command -v docker >/dev/null 2>&1 || ! systemctl is-active --quiet docker 2>/dev/null; then
  if [[ "$WITH_DOCKER" -eq 1 ]]; then
    echo "Docker isn't installed/running - installing it now (--with-docker was set)."
    if [[ -x "${SCRIPT_DIR}/install-docker-rocky9.sh" ]]; then
      "${SCRIPT_DIR}/install-docker-rocky9.sh"
    else
      echo "Couldn't find install-docker-rocky9.sh next to this script. Install Docker manually first."
      exit 1
    fi
  else
    echo "Docker isn't installed or isn't running."
    echo "Run ./install-docker-rocky9.sh first, or re-run this script with --with-docker."
    exit 1
  fi
else
  echo "Docker is present: $(docker --version)"
fi

# ---- Step 2: Pull image ----
echo
echo "Step 2/6: Pulling ${IMAGE} (public image, no login needed)..."
docker pull "$IMAGE"

# ---- Step 3: Data directory ----
echo
echo "Step 3/6: Preparing data directory ${DATA_DIR}..."
if [[ "$FRESH" -eq 1 && -d "$DATA_DIR" ]]; then
  echo "--fresh was set - wiping ${DATA_DIR}."
  rm -rf "${DATA_DIR:?}"/*
fi
mkdir -p "$DATA_DIR"
# The official image drops privileges to its internal "postgres" user (UID 999)
# before touching the data dir - a root-owned directory fails with a permission
# error on startup. This is different from the Tanzu image, which is fine with root.
chown 999:999 "$DATA_DIR"
chmod 700 "$DATA_DIR"
PRE_EXISTING_DATA=0
if [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
  PRE_EXISTING_DATA=1
  echo "Note: ${DATA_DIR} already has data in it from a previous run."
  echo "Postgres will keep using whatever user/db/password that data was initialized with -"
  echo "--pg-user/--pg-password/--pg-db below will be ignored. Re-run with --fresh if you want a clean start."
fi

# ---- Step 4: Firewall ----
echo
echo "Step 4/6: Checking firewalld..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "firewalld is active - opening port ${HOST_PORT}/tcp."
  firewall-cmd --permanent --add-port="${HOST_PORT}/tcp"
  firewall-cmd --reload
else
  echo "firewalld is not running - nothing to open here. (If you're behind a cloud/network firewall, open ${HOST_PORT}/tcp there separately.)"
fi

# ---- Step 5: Run the container ----
echo
echo "Step 5/6: Starting the container..."
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "A container named '${CONTAINER_NAME}' already exists - removing it first so we start clean."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

GENERATED_PASSWORD=0
if [[ -z "$PG_PASSWORD" ]]; then
  PG_PASSWORD="$(openssl rand -base64 12)"
  GENERATED_PASSWORD=1
fi

docker run -d \
  --name "$CONTAINER_NAME" \
  -e POSTGRES_USER="$PG_USER" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -e POSTGRES_DB="$PG_DB" \
  -v "${DATA_DIR}:/var/lib/postgresql" \
  -p "${HOST_PORT}:5432" \
  --restart unless-stopped \
  "$IMAGE" "${TUNING_ARGS[@]}" >/dev/null

echo "Container '${CONTAINER_NAME}' started."

# ---- Step 6: Verify ----
echo
echo "Step 6/6: Verifying..."
echo -n "Waiting for Postgres to accept connections"
for i in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" pg_isready -U "$PG_USER" >/dev/null 2>&1; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
  if [[ "$i" -eq 30 ]]; then
    echo
    echo "Postgres didn't come up within 30s. Check: docker logs ${CONTAINER_NAME}"
    exit 1
  fi
done

docker exec "$CONTAINER_NAME" psql -U "$PG_USER" -d "$PG_DB" -c "SHOW max_connections;"

echo
echo "== Done =="
echo "Container:  ${CONTAINER_NAME}"
echo "Connect:    psql -h <this-host> -p ${HOST_PORT} -U ${PG_USER} -d ${PG_DB}"
echo "User:       ${PG_USER}"
if [[ "$PRE_EXISTING_DATA" -eq 1 ]]; then
  echo "Password:   unchanged - ${DATA_DIR} had existing data, so this run's password/user settings were ignored."
  echo "            Use whatever credentials that data was originally initialized with, or re-run with --fresh."
elif [[ "$GENERATED_PASSWORD" -eq 1 ]]; then
  echo "Password:   ${PG_PASSWORD}   (auto-generated - save this, it won't be shown again)"
else
  echo "Password:   (the one you provided with --pg-password)"
fi
echo "Data dir:   ${DATA_DIR}"
echo
echo "To stop it:            docker stop ${CONTAINER_NAME}"
echo "To remove it (keeps data): docker rm ${CONTAINER_NAME}"
echo "To wipe everything:    docker rm -f ${CONTAINER_NAME} && rm -rf ${DATA_DIR}"
