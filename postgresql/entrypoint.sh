#!/usr/bin/env bash
# entrypoint.sh — PostgreSQL HA with repmgr; supports last-known-primary bootstrap after full-cluster outage
set -euo pipefail
IFS=$'\n\t'

: "${PGDATA:=/var/lib/postgresql/data}"
: "${REPMGR_DB:=repmgr}"
: "${REPMGR_USER:=repmgr}"
: "${REPMGR_PASSWORD:?ERROR: REPMGR_PASSWORD not set}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:?ERROR: POSTGRES_PASSWORD not set}"
: "${APP_READONLY_PASSWORD:?ERROR: APP_READONLY_PASSWORD not set}"
: "${APP_READWRITE_PASSWORD:?ERROR: APP_READWRITE_PASSWORD not set}"
: "${PG_PORT:=5432}"
: "${REPMGR_CONF:=/etc/repmgr/repmgr.conf}"
: "${IS_WITNESS:=false}"
: "${PRIMARY_HINT:=pg-1}"
: "${RETRY_INTERVAL:=5}"          # seconds between retries
: "${RETRY_ROUNDS:=3}"          # total retries (180 * 5s ≈ 15 minutes)
: "${LAST_PRIMARY_FILE:="$PGDATA/last_known_primary"}"

# NODE_NAME and NODE_ID are REQUIRED (must be set via environment variables)
if [ -z "${NODE_NAME:-}" ]; then
  echo "[FATAL] NODE_NAME environment variable is not set. Please set it (e.g., pg-1, pg-2, witness)"
  exit 1
fi

if [ -z "${NODE_ID:-}" ]; then
  echo "[FATAL] NODE_ID environment variable is not set. Please set it (e.g., 1, 2, 3, 99)"
  exit 1
fi

log() { echo "[$(date -Iseconds)] [entrypoint] $*"; }
pgdata_has_db() { [ -f "$PGDATA/PG_VERSION" ]; }

ensure_dirs() {
  mkdir -p /etc/repmgr
  chown -R postgres:postgres /etc/repmgr
  mkdir -p "$PGDATA"
  # WAL archive directory to support safe standby rewind / point-in-time recovery
  mkdir -p /var/lib/postgresql/wal_archive
  chown -R postgres:postgres /var/lib/postgresql/wal_archive
  chown -R postgres:postgres "$PGDATA"
}

write_pgpass() {
  local pgpass="/var/lib/postgresql/.pgpass"
  # Escape special characters in password for .pgpass format
  # According to PostgreSQL docs, \ and : must be escaped
  local escaped_password="${REPMGR_PASSWORD//\\/\\\\}"  # Escape backslash first
  escaped_password="${escaped_password//:/\\:}"          # Then escape colon
  # Use printf to preserve backslashes
  printf '*:*:*:%s:%s\n' "$REPMGR_USER" "$escaped_password" > "$pgpass"
  chmod 600 "$pgpass"
  chown postgres:postgres "$pgpass"
  log "Generated $pgpass for user postgres"
}

# Atomic write for last-known-primary (tmp+mv)
write_last_primary() {
  local host="$1"
  local tmp="${LAST_PRIMARY_FILE}.tmp"
  printf "%s\n" "$host" > "$tmp"
  chmod 600 "$tmp" || true
  chown postgres:postgres "$tmp" || true
  mv -f "$tmp" "$LAST_PRIMARY_FILE"
  sync
  chmod 600 "$LAST_PRIMARY_FILE" || true
  chown postgres:postgres "$LAST_PRIMARY_FILE" || true
  log "Recorded last-known-primary: $host"
}

read_last_primary() {
  if [[ -s "$LAST_PRIMARY_FILE" ]]; then
    tail -n 1 "$LAST_PRIMARY_FILE"
  else
    echo ""
  fi
}

wait_for_port() {
  local host=$1 port=${2:-5432} timeout=${3:-10}
  for _ in $(seq 1 "$timeout"); do
    if gosu postgres pg_isready -h "$host" -p "$port" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

is_primary() {
  local host=$1 port=${2:-5432}
  # Use .pgpass file which has properly escaped password
  gosu postgres psql -h "$host" -p "$port" -U "$REPMGR_USER" -d "$REPMGR_DB" -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q t
}

# Dùng khi init cluster lần đầu
find_primary() {
  IFS=',' read -ra peers <<<"$PEERS"
  for p in "${peers[@]}"; do
    local host=${p%:*}; local port=${p#*:}; [ "$host" = "$port" ] && port=5432
    if wait_for_port "$host" "$port" 3; then
      if is_primary "$host" "$port"; then
        echo "${host}:${port}"; return 0
      fi
    fi
  done
  return 1
}

# Dùng khi fallback (node cũ quay lại)
find_new_primary() {
  IFS=',' read -ra peers <<<"$PEERS"
  for p in "${peers[@]}"; do
    local host=${p%:*}; local port=${p#*:}; [ "$host" = "$port" ] && port=5432
    [ "$host" = "$NODE_NAME" ] && continue
    if wait_for_port "$host" "$port" 3; then
      if is_primary "$host" "$port"; then
        echo "${host}:${port}"; return 0
      fi
    fi
  done
  return 1
}

write_postgresql_conf() {
  cat > "$PGDATA/postgresql.conf" <<EOF
# Network
listen_addresses = '*'
port = ${PG_PORT}
max_connections = 1000            # Increased for high concurrency (from default 100)

# Replication - Optimized for fast failover (<10s)
wal_level = replica
max_wal_senders = 16              # Support more standbys + archiving
wal_keep_size = '10GB'            # Increased to prevent WAL removal during lag spikes
max_replication_slots = 16
hot_standby = on
hot_standby_feedback = on
wal_log_hints = on
shared_preload_libraries = 'repmgr'

# WAL archiving - help avoid missing WALs during standby rejoin/rewind
archive_mode = on
# Archive to local directory on the same volume; in production use remote archive (S3/NFS).
archive_command = 'test -f /var/lib/postgresql/wal_archive/%f || cp %p /var/lib/postgresql/wal_archive/%f'
archive_timeout = 60

# WAL Performance - Critical for <10s failover
wal_compression = on              # Compress WAL to reduce I/O
wal_buffers = 64MB                # Increased from default 16MB
max_wal_size = 8GB                # Allow larger WAL before checkpoint
min_wal_size = 2GB
checkpoint_timeout = 15min        # More frequent checkpoints (down from 30min)
checkpoint_completion_target = 0.9

# Synchronous replication - Ensure data integrity
# Set to 'off' for async (faster writes), 'remote_write' for durability without flush wait
# 'on' for strongest guarantee but slower writes
synchronous_commit = remote_write  # Wait for WAL write to standby, not fsync (balanced)
# synchronous_standby_names = 'FIRST 1 (pg-2, pg-3, pg-4)'  # Uncomment for sync replication

# Logging - Minimal for normal operation, errors only
log_connections = off
log_disconnections = off
log_line_prefix = '%t [%p]: '
log_statement = 'none'
log_min_duration_statement = 5000
log_min_error_statement = error
log_min_messages = warning
log_checkpoints = on
log_lock_waits = on
log_autovacuum_min_duration = 0
log_replication_commands = on     # Log replication events for failover debugging

# Password Encryption (SCRAM-SHA-256 is more secure than md5)
password_encryption = 'scram-sha-256'

# SSL/TLS (if certificates exist)
ssl = off
# ssl_cert_file = 'server.crt'
# ssl_key_file = 'server.key'
# ssl_ca_file = 'root.crt'

# Performance - Tuned for 32 vCPU / 32 GB RAM
shared_buffers = 8GB              # 25% of RAM (up from 256MB)
work_mem = 64MB                   # Per-operation memory (up from 16MB)
maintenance_work_mem = 2GB        # For VACUUM, CREATE INDEX (up from 128MB)
effective_cache_size = 24GB       # 75% of RAM for query planner estimates
effective_io_concurrency = 200    # For SSD/NVMe
random_page_cost = 1.1            # SSD-optimized

# Parallel query execution (leverage 32 vCPUs)
max_worker_processes = 32         # Match vCPU count
max_parallel_workers_per_gather = 8  # Per query parallelism
max_parallel_workers = 32         # Total parallel workers
max_parallel_maintenance_workers = 8 # For parallel CREATE INDEX, VACUUM

# Autovacuum - Aggressive for high-write workloads
autovacuum = on
autovacuum_max_workers = 8        # More workers for 32 vCPU
autovacuum_naptime = 10s          # Check more frequently (down from 1min)
autovacuum_vacuum_scale_factor = 0.05     # Vacuum when 5% of table is dead (down from 20%)
autovacuum_analyze_scale_factor = 0.025   # Analyze when 2.5% changed

# Connection management
tcp_keepalives_idle = 60          # Send keepalive after 60s idle
tcp_keepalives_interval = 10      # Retry every 10s
tcp_keepalives_count = 6          # Drop after 6 failed keepalives

# Statement timeout (prevent runaway queries)
statement_timeout = 300000
EOF
}

write_pg_hba() {
  cat > "$PGDATA/pg_hba.conf" <<'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Local connections: allow trust for any local Unix socket client
local   all             all                                     trust

# Local TCP connections (loopback) are trusted for all users
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

# Allow admin/replication users from any IP to form the cluster.
# This is intentionally broad to support dynamic IPs on platforms like Railway.
host    all             postgres        0.0.0.0/0               trust
host    replication     postgres        0.0.0.0/0               trust
host    all             repmgr          0.0.0.0/0               trust
host    replication     repmgr          0.0.0.0/0               trust
host    all             postgres        ::/0                    trust
host    replication     postgres        ::/0                    trust
host    all             repmgr          ::/0                    trust
host    replication     repmgr          ::/0                    trust

# Application users MUST use SCRAM-SHA-256 for strong password encryption
host    all             app_readonly    0.0.0.0/0               scram-sha-256
host    all             app_readwrite   0.0.0.0/0               scram-sha-256
host    all             app_readonly    ::/0                    scram-sha-256
host    all             app_readwrite   ::/0                    scram-sha-256
EOF
}

write_repmgr_conf() {
  cat > "$REPMGR_CONF" <<EOF
node_id=${NODE_ID}
node_name='${NODE_NAME}'
conninfo='host=${NODE_NAME} port=${PG_PORT} user=${REPMGR_USER} dbname=${REPMGR_DB} password=${REPMGR_PASSWORD} connect_timeout=5'
data_directory='${PGDATA}'


log_level=INFO
log_facility=STDERR
use_replication_slots=yes

# Service control commands
service_start_command='gosu postgres pg_ctl -D ${PGDATA} -w start'
service_stop_command='gosu postgres pg_ctl -D ${PGDATA} -m fast stop'
service_restart_command='gosu postgres pg_ctl -D ${PGDATA} -w restart -m fast'
service_reload_command='gosu postgres pg_ctl -D ${PGDATA} reload'

# Monitoring - Optimized for <10s failover detection
monitor_interval_secs=2           # Check every 2s (down from 5s)
connection_check_type=ping        # Fast ping check
reconnect_attempts=3              # Try 3 times (down from 6)
reconnect_interval=2              # Wait 2s between attempts (down from 5s)
                                  # Total detection time: 2s * 3 = 6s worst case

# Failover configuration - Aggressive for <10s total failover
failover=automatic
promote_command='/usr/local/bin/promote_guard.sh'  # Use promotion guard
follow_command='repmgr standby follow -f /etc/repmgr/repmgr.conf --log-to-file --upstream-node-id=%n'

# Promotion settings
priority=$((200 - NODE_ID))       # Higher priority = preferred for promotion
location='default'

# Failover coordination
failover_validation_command=''    # Optional: Add fencing script here
election_rerun_interval=5         # Re-run election if no winner in 5s (down from 15s)
sibling_nodes_disconnect_timeout=10  # Wait 10s for siblings to disconnect from failed primary

# Child process monitoring (repmgrd daemon management)
repmgrd_service_start_command='repmgrd -f /etc/repmgr/repmgr.conf --daemonize=false'
repmgrd_pid_file='/tmp/repmgrd.pid'

# Witness node settings (only used if this IS a witness)
witness_sync_interval=15          # Sync witness metadata every 15s
EOF
}

safe_clear_pgdata() {
  if [ -d "$PGDATA" ]; then
    gosu postgres pg_ctl -D "$PGDATA" -m fast stop || true
    rm -rf "$PGDATA"/*
  fi
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
}

wait_for_metadata() {
  local timeout=${1:-30}
  for _ in $(seq 1 "$timeout"); do
    if gosu postgres psql -h "$NODE_NAME" -p "$PG_PORT" -U "$REPMGR_USER" -d "$REPMGR_DB" -tAc \
      "SELECT 1 FROM repmgr.nodes WHERE node_id = ${NODE_ID}" | grep -q 1; then
      log "Metadata for node ${NODE_ID} is visible locally."
      return 0
    fi
    sleep 1
  done
  log "Timeout waiting for metadata to replicate."
  return 1
}

init_primary() {
  log "Initializing primary (fresh PGDATA)..."
  safe_clear_pgdata
  gosu postgres initdb -D "$PGDATA" --data-checksums
  write_pg_hba
  write_postgresql_conf
  gosu postgres pg_ctl -D "$PGDATA" -w start

  # Create repmgr role + database
  # Idempotent: only created if missing
  gosu postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname='${REPMGR_USER}'" | grep -q 1 \
    || gosu postgres psql -U "$POSTGRES_USER" -c "CREATE ROLE ${REPMGR_USER} WITH LOGIN REPLICATION SUPERUSER PASSWORD '${REPMGR_PASSWORD}';"

  gosu postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname='${REPMGR_DB}'" | grep -q 1 \
    || gosu postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE ${REPMGR_DB} OWNER ${REPMGR_USER};"

  log "Installing repmgr extension..."
  gosu postgres psql -U "$POSTGRES_USER" -d "$REPMGR_DB" -c "CREATE EXTENSION IF NOT EXISTS repmgr;"

  # Create application users with limited permissions
  log "Creating application users..."
  
  # Read-only user
  gosu postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname='app_readonly'" | grep -q 1 \
    || gosu postgres psql -U "$POSTGRES_USER" -c "CREATE USER app_readonly WITH PASSWORD '${APP_READONLY_PASSWORD:-$(openssl rand -base64 32)}';"
  
  gosu postgres psql -U "$POSTGRES_USER" <<-EOSQL
    GRANT CONNECT ON DATABASE postgres TO app_readonly;
    GRANT USAGE ON SCHEMA public TO app_readonly;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_readonly;
EOSQL
  
  # Read-write user
  gosu postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname='app_readwrite'" | grep -q 1 \
    || gosu postgres psql -U "$POSTGRES_USER" -c "CREATE USER app_readwrite WITH PASSWORD '${APP_READWRITE_PASSWORD:-$(openssl rand -base64 32)}';"
  
  gosu postgres psql -U "$POSTGRES_USER" <<-EOSQL
    GRANT CONNECT ON DATABASE postgres TO app_readwrite;
    GRANT USAGE ON SCHEMA public TO app_readwrite;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_readwrite;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;
EOSQL

  log "Application users created successfully"

  gosu postgres repmgr -f "$REPMGR_CONF" primary register --force
  write_last_primary "$NODE_NAME"
  log "Primary initialized."
}

clone_standby() {
  local primary="$1"
  local host=${primary%:*}
  local port=${primary#*:}
  log "Cloning standby from $host:$port"

  until wait_for_port "$host" "$port" 10; do sleep 2; done
  safe_clear_pgdata
  gosu postgres initdb -D "$PGDATA" --data-checksums
  write_pg_hba
  write_postgresql_conf
  write_repmgr_conf

  gosu postgres repmgr -h "$host" -p "$port" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" standby clone --force
  gosu postgres pg_ctl -D "$PGDATA" -w start
  gosu postgres repmgr -h "$host" -p "$port" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" standby register --force
  wait_for_metadata 30 || true
  write_last_primary "$host"  # Record current primary when joining as standby
  log "Standby registered."
}

attempt_rewind() {
  local primary="$1"
  local host=${primary%:*}
  local port=${primary#*:}
  log "Attempting pg_rewind from $host:$port"
  gosu postgres pg_ctl -D "$PGDATA" -m fast stop || true
  # Escape single quotes in password for connection string
  local escaped_password="${REPMGR_PASSWORD//\'/\'\'}"
  if gosu postgres pg_rewind --target-pgdata="$PGDATA" \
      --source-server="host=$host port=$port user=$REPMGR_USER dbname=$REPMGR_DB password='${escaped_password}'"; then
    log "pg_rewind successful"
    gosu postgres pg_ctl -D "$PGDATA" -w start
    write_last_primary "$host"
    return 0
  else
    log "pg_rewind failed"
    return 1
  fi
}

start_repmgrd() {
  log "Starting repmgrd..."
  gosu postgres repmgrd -f "$REPMGR_CONF" -d
  log "Starting monitor.sh..."
  /usr/local/bin/monitor.sh &
}

# ==== Main ====
ensure_dirs
write_pgpass
write_repmgr_conf

# Accept PRIMARY_HOST if provided (compose may set PRIMARY_HOST)
: "${PRIMARY_HOST:=}"
if [ -n "${PRIMARY_HOST}" ]; then
  PRIMARY_HINT="${PRIMARY_HOST}"
fi

# Validate NODE_ID is numeric (required for repmgr priority calculation)
if ! [[ "${NODE_ID}" =~ ^[0-9]+$ ]]; then
  log "[ERROR] NODE_ID must be a number. Got: '${NODE_ID}'"
  exit 1
fi

log "Node configuration: NAME=${NODE_NAME}, ID=${NODE_ID}"

# Witness node flow
if [ "$IS_WITNESS" = "true" ]; then
  # Witness uses its local PG for repmgr metadata only (can be no volume, but we still need a running PG)
  log "Witness: starting local PostgreSQL for repmgr metadata"
  safe_clear_pgdata
  gosu postgres initdb -D "$PGDATA" --data-checksums
  write_pg_hba
  write_postgresql_conf
  gosu postgres pg_ctl -D "$PGDATA" -w start

  # Resolve primary via last-known-primary or discovery
  lk_primary="$(read_last_primary)"
  if [ -n "$lk_primary" ]; then
    log "Witness prefers last-known-primary: $lk_primary"
    primary_hostport="${lk_primary}:5432"
  else
    primary_hint_host=${PRIMARY_HINT%:*}
    primary_hostport=$(find_primary || echo "${primary_hint_host}:5432")
  fi

  # Create repmgr role + database locally so repmgrd can start and witness register can use local metadata
  # Idempotent: only created if missing
  gosu postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname='${REPMGR_USER}'" | grep -q 1 \
    || gosu postgres psql -U "$POSTGRES_USER" -c "CREATE ROLE ${REPMGR_USER} WITH LOGIN REPLICATION SUPERUSER PASSWORD '${REPMGR_PASSWORD}';"
  gosu postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname='${REPMGR_DB}'" | grep -q 1 \
    || gosu postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE ${REPMGR_DB} OWNER ${REPMGR_USER};"
  log "Witness: ensured local repmgr role/db (user=${REPMGR_USER}, db=${REPMGR_DB})"


  log "Registering witness against ${primary_hostport%:*}"
  # Retry until primary responds
  for _ in $(seq 1 "$RETRY_ROUNDS"); do
    if wait_for_port "${primary_hostport%:*}" "${primary_hostport#*:}" 5; then
      gosu postgres repmgr -f "$REPMGR_CONF" witness register \
        -h "${primary_hostport%:*}" -p "${primary_hostport#*:}" \
        -U "$REPMGR_USER" -d "$REPMGR_DB" --force && break || true
    fi
    log "Witness waiting for primary..."
    sleep "$RETRY_INTERVAL"
  done

  start_repmgrd
  sleep infinity
fi

# Normal node flow
# Wait for volume mount to complete (Railway mounts volumes asynchronously)
log "Waiting up to 30s for volume mount and data availability..."
for i in {1..30}; do
  if pgdata_has_db; then
    log "Existing database found after ${i}s wait"
    break
  fi
  sleep 1
done

if ! pgdata_has_db; then
  # Fresh node init path
  current_primary=$(find_primary || true)

  if [ -n "$current_primary" ]; then
    clone_standby "$current_primary"
  else
    # No primary found; if this node is the hinted bootstrap (PRIMARY_HINT), allow init as primary
    if [ "$NODE_NAME" = "${PRIMARY_HINT%:*}" ]; then
      log "No primary detected; ${NODE_NAME} matches PRIMARY_HINT → init as primary"
      init_primary
    else
      log "No primary detected; ${NODE_NAME} is not PRIMARY_HINT - waiting for PRIMARY_HINT to bootstrap"
      hint_host=${PRIMARY_HINT%:*}
      while true; do
        sleep "$RETRY_INTERVAL"
        if wait_for_port "$hint_host" 5432 3 && is_primary "$hint_host" 5432; then
          current_primary="${hint_host}:5432"
          log "PRIMARY_HINT is now up as primary: $current_primary"
          clone_standby "$current_primary"
          break
        fi
        log "Waiting for PRIMARY_HINT '$hint_host' to become primary..."
      done
    fi
  fi
else
  # Node has previous data (fallback/rejoin or full-outage bootstrap using last-known-primary)
  current_primary=$(find_new_primary || true)

  if [ -n "$current_primary" ]; then
    # There is a reachable current primary → try rewind + rejoin/register
    if attempt_rewind "$current_primary"; then
      if gosu postgres repmgr \
          -h "${current_primary%:*}" -p "${current_primary#*:}" \
          -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" \
          node rejoin --force --force-rewind; then
        log "Node successfully rejoined cluster as standby."
        write_last_primary "${current_primary%:*}"  # Update last known primary
      else
        log "Node rejoin failed; attempting metadata normalize then register."
        gosu postgres repmgr -f "$REPMGR_CONF" \
          -h "${current_primary%:*}" -p "${current_primary#*:}" \
          -U "$REPMGR_USER" -d "$REPMGR_DB" \
          primary unregister --node-id="${NODE_ID}" --force || true

        if gosu postgres repmgr \
            -h "${current_primary%:*}" -p "${current_primary#*:}" \
            -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" \
            standby register --force; then
          log "Node registered as standby (fallback)."
          write_last_primary "${current_primary%:*}"  # Update last known primary
        else
          log "Standby register failed; fallback to full clone."
          clone_standby "$current_primary"
        fi
      fi

      wait_for_metadata 30 || true
    else
      log "pg_rewind failed; fallback to full clone."
      clone_standby "$current_primary"
    fi
  else
    # No reachable primary → use last-known-primary logic
    lk_primary="$(read_last_primary)"
    if [ -n "$lk_primary" ]; then
      log "No reachable primary; last-known-primary is '$lk_primary'"
      if [ "$NODE_NAME" = "$lk_primary" ]; then
        log "This node is the last-known-primary → will bootstrap as primary after timeout"
        # Wait a bit for peers; if none become primary, start local PG and register as primary
        for i in $(seq 1 "$RETRY_ROUNDS"); do
          sleep "$RETRY_INTERVAL"
          current_primary=$(find_new_primary || true)
          [ -n "$current_primary" ] && break
          log "Waiting before bootstrap as last-known-primary..."
        done
        if [ -z "$current_primary" ]; then
          # Bootstrap from existing data; do NOT initdb (preserve data)
          gosu postgres pg_ctl -D "$PGDATA" -w start
          gosu postgres repmgr -f "$REPMGR_CONF" primary register --force
          write_last_primary "$NODE_NAME"
          log "Bootstrapped this node as primary (last-known-primary)."
        else
          log "A primary appeared: $current_primary; will follow and rejoin"
          if attempt_rewind "$current_primary"; then
            gosu postgres repmgr -f "$REPMGR_CONF" node rejoin --force --force-rewind || true
            gosu postgres repmgr -f "$REPMGR_CONF" standby register --force || true
          else
            clone_standby "$current_primary"
          fi
        fi
      else
        # This node is NOT last-known-primary → wait (do not exit) until last-known-primary is up
        log "This node is not last-known-primary; will wait until '$lk_primary' becomes primary"
        for i in $(seq 1 "$RETRY_ROUNDS"); do
          sleep "$RETRY_INTERVAL"
          # Prefer checking last-known-primary host first
          if wait_for_port "$lk_primary" 5432 3 && is_primary "$lk_primary" 5432; then
            current_primary="${lk_primary}:5432"
            log "Last-known-primary is now up as primary: $current_primary"
            break
          fi
          # Otherwise try general discovery
          current_primary=$(find_new_primary || true)
          [ -n "$current_primary" ] && break
          log "Still waiting for last-known-primary '$lk_primary' or any primary..."
        done
        if [ -n "$current_primary" ]; then
          # Rejoin/clone to the discovered primary
          if attempt_rewind "$current_primary"; then
            gosu postgres repmgr -f "$REPMGR_CONF" node rejoin --force --force-rewind || true
            gosu postgres repmgr -f "$REPMGR_CONF" standby register --force || true
          else
            clone_standby "$current_primary"
          fi
        else
          # Keep waiting rather than exiting; rely on orchestrator to keep container running
          log "Primary still not found; continue waiting without exit to avoid split-brain"
          # Optionally sleep infinity to keep container alive until primary appears
          while true; do
            sleep "$RETRY_INTERVAL"
            current_primary=$(find_new_primary || true)
            if [ -n "$current_primary" ]; then
              log "Primary discovered during wait: $current_primary"
              if attempt_rewind "$current_primary"; then
                gosu postgres repmgr -f "$REPMGR_CONF" node rejoin --force --force-rewind || true
                gosu postgres repmgr -f "$REPMGR_CONF" standby register --force || true
              else
                clone_standby "$current_primary"
              fi
              break
            fi
          done
        fi
      fi
    else
      # No last-known-primary recorded; fall back to PRIMARY_HINT
      log "No last-known-primary recorded; falling back to PRIMARY_HINT='${PRIMARY_HINT}'"
      hint_host=${PRIMARY_HINT%:*}
      # Wait for hint host to come up as primary
      for i in $(seq 1 "$RETRY_ROUNDS"); do
        sleep "$RETRY_INTERVAL"
        if wait_for_port "$hint_host" 5432 3 && is_primary "$hint_host" 5432; then
          current_primary="${hint_host}:5432"
          log "Hint primary is up: $current_primary"
          break
        fi
        current_primary=$(find_new_primary || true)
        [ -n "$current_primary" ] && break
        log "Waiting for PRIMARY_HINT '$hint_host' or any primary..."
      done
      if [ -n "$current_primary" ]; then
        if attempt_rewind "$current_primary"; then
          gosu postgres repmgr -f "$REPMGR_CONF" node rejoin --force --force-rewind || true
          gosu postgres repmgr -f "$REPMGR_CONF" standby register --force || true
        else
          clone_standby "$current_primary"
        fi
      else
        log "Primary still not found; continue waiting without exit (no last-known-primary)"
        while true; do
          sleep "$RETRY_INTERVAL"
          current_primary=$(find_new_primary || true)
          if [ -n "$current_primary" ]; then
            log "Primary discovered during wait: $current_primary"
            if attempt_rewind "$current_primary"; then
              gosu postgres repmgr -f "$REPMGR_CONF" node rejoin --force --force-rewind || true
              gosu postgres repmgr -f "$REPMGR_CONF" standby register --force || true
            else
              clone_standby "$current_primary"
            fi
            break
          fi
        done
      fi
    fi
  fi
fi

start_repmgrd
sleep infinity