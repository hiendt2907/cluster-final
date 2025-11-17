#!/bin/bash
set -e

echo "[$(date)] Pgpool-II Entrypoint - Starting..."

# Environment variables with defaults
PGPOOL_NODE_ID=${PGPOOL_NODE_ID:-1}
# Pgpool Resource Configuration
: "${PGPOOL_NUM_INIT_CHILDREN:=500}"
: "${PGPOOL_MAX_POOL:=10}"
: "${PGPOOL_LISTEN_BACKLOG_MULTIPLIER:=2}"

# Export PGPOOL variables for envsubst
export PGPOOL_NUM_INIT_CHILDREN PGPOOL_MAX_POOL PGPOOL_LISTEN_BACKLOG_MULTIPLIER
# Determine local pgpool hostname deterministically from node id when not
# explicitly provided. Relying on `hostname` was causing inconsistent values
# inside containers (docker networking / compose can differ), so map node id ->
# service name which matches the docker-compose `hostname`/`container_name`.
if [ -z "${PGPOOL_HOSTNAME:-}" ]; then
  if [ "$PGPOOL_NODE_ID" -eq 1 ]; then
    PGPOOL_HOSTNAME=pgpool-1
  else
    PGPOOL_HOSTNAME=pgpool-2
  fi
fi

# If OTHER_PGPOOL_HOSTNAME not provided, derive it from the node id (1<->2)
if [ -z "${OTHER_PGPOOL_HOSTNAME:-}" ]; then
  if [ "$PGPOOL_NODE_ID" -eq 1 ]; then
    OTHER_PGPOOL_HOSTNAME=pgpool-2
  else
    OTHER_PGPOOL_HOSTNAME=pgpool-1
  fi
fi
OTHER_PGPOOL_PORT=${OTHER_PGPOOL_PORT:-9898}

# Export hostnames so background processes (monitor) inherit them
export PGPOOL_HOSTNAME OTHER_PGPOOL_HOSTNAME
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?ERROR: POSTGRES_PASSWORD not set}
REPMGR_PASSWORD=${REPMGR_PASSWORD:?ERROR: REPMGR_PASSWORD not set}
APP_READONLY_PASSWORD=${APP_READONLY_PASSWORD:?ERROR: APP_READONLY_PASSWORD not set}
APP_READWRITE_PASSWORD=${APP_READWRITE_PASSWORD:?ERROR: APP_READWRITE_PASSWORD not set}

# Export key credentials so monitoring helper scripts (launched as background
# processes) inherit them from the environment.
export POSTGRES_PASSWORD REPMGR_PASSWORD

# PCP (pcp/pcppass) credentials (parameterized)
PCP_USER=${PCP_USER:-admin}
PCP_PASSWORD=${PCP_PASSWORD:-adminpass}
PCP_HOST=${PCP_HOST:-localhost}
PCP_PORT=${PCP_PORT:-9898}

# Backend nodes for PostgreSQL cluster discovery
PGPOOL_BACKENDS=${PGPOOL_BACKENDS:-"pg-1,pg-2,pg-3"}
# Ensure child/background helpers inherit the backend list
export PGPOOL_BACKENDS

# Provide simple environment variable defaults for pgpool.conf template
# Use simple $VAR substitutions in the template (envsubst will replace them).
export BACKEND0_HOST=${BACKEND0_HOST:-pg-1}
export BACKEND0_PORT=${BACKEND0_PORT:-5432}
export BACKEND0_DATA_DIR=${BACKEND0_DATA_DIR:-/var/lib/postgresql/data}
export BACKEND0_FLAG=${BACKEND0_FLAG:-ALLOW_TO_FAILOVER}
export BACKEND0_NAME=${BACKEND0_NAME:-pg-1}

export BACKEND1_HOST=${BACKEND1_HOST:-pg-2}
export BACKEND1_PORT=${BACKEND1_PORT:-5432}
export BACKEND1_DATA_DIR=${BACKEND1_DATA_DIR:-/var/lib/postgresql/data}
export BACKEND1_FLAG=${BACKEND1_FLAG:-ALLOW_TO_FAILOVER}
export BACKEND1_NAME=${BACKEND1_NAME:-pg-2}

export BACKEND2_HOST=${BACKEND2_HOST:-pg-3}
export BACKEND2_PORT=${BACKEND2_PORT:-5432}
export BACKEND2_DATA_DIR=${BACKEND2_DATA_DIR:-/var/lib/postgresql/data}
export BACKEND2_FLAG=${BACKEND2_FLAG:-ALLOW_TO_FAILOVER}
export BACKEND2_NAME=${BACKEND2_NAME:-pg-3}

# Runtime check configuration defaults
export SR_CHECK_USER=${SR_CHECK_USER:-repmgr}
export SR_CHECK_DATABASE=${SR_CHECK_DATABASE:-postgres}
export HEALTH_CHECK_USER=${HEALTH_CHECK_USER:-repmgr}
export HEALTH_CHECK_DATABASE=${HEALTH_CHECK_DATABASE:-postgres}

# Watchdog defaults: allow enabling via USE_WATCHDOG=on
export USE_WATCHDOG=${USE_WATCHDOG:-off}
export WD_HOSTNAME0=${WD_HOSTNAME0:-localhost}
export WD_PORT0=${WD_PORT0:-9000}
export WD_PRIORITY0=${WD_PRIORITY0:-1}
export WD_NODE_ID0=${WD_NODE_ID0:-1}
export WD_HOSTNAME1=${WD_HOSTNAME1:-pgpool-2}
export WD_PORT1=${WD_PORT1:-9000}
export WD_PRIORITY1=${WD_PRIORITY1:-2}
export WD_NODE_ID1=${WD_NODE_ID1:-2}
export WD_AUTHKEY=${WD_AUTHKEY:-pgpool_watchdog_auth}
export WD_IPC_SOCKET_DIR=${WD_IPC_SOCKET_DIR:-/var/run/pgpool}
export PCP_SOCKET_DIR=${PCP_SOCKET_DIR:-/var/run/pgpool}

# Pgpool peers for watchdog (separate from backends)
# Can be set via PGPOOL_PEERS (preferred) or PEERS (legacy). Example:
#   PGPOOL_PEERS="pgpool-1,pgpool-2,pgpool-3"
PGPOOL_PEERS=${PGPOOL_PEERS:-${PEERS:-"pgpool-1,pgpool-2"}}

# Create necessary directories
mkdir -p /var/run/pgpool /var/log/pgpool
chown -R postgres:postgres /var/run/pgpool /var/log/pgpool

# Allow configurable config paths so the entrypoint is not hardcoded to /etc/pgpool-II
# You can override these with environment variables or mount a custom config dir
PGPOOL_CONF_DIR=${PGPOOL_CONF_DIR:-/etc/pgpool-II}
PGPOOL_CONF_PATH=${PGPOOL_CONF_PATH:-$PGPOOL_CONF_DIR/pgpool.conf}
PCP_CONF_PATH=${PCP_CONF_PATH:-$PGPOOL_CONF_DIR/pcp.conf}
POOL_HBA_PATH=${POOL_HBA_PATH:-$PGPOOL_CONF_DIR/pool_hba.conf}

mkdir -p "$PGPOOL_CONF_DIR"

# Clean up any stale PID file immediately
echo "[$(date)] Cleaning up any stale PID file..."
rm -f /var/run/pgpool/pgpool.pid

# Function to generate watchdog configuration dynamically
generate_watchdog_config() {
  local pgpool_conf="$PGPOOL_CONF_PATH"
  local peers="$PGPOOL_PEERS"

  echo "[$(date)] Generating watchdog configuration from PGPOOL_PEERS: $peers"

  # Remove existing watchdog, heartbeat, and other_pgpool lines
  sed -i '/^wd_hostname[0-9]* = /d' "$pgpool_conf"
  sed -i '/^wd_port[0-9]* = /d' "$pgpool_conf"
  sed -i '/^wd_priority[0-9]* = /d' "$pgpool_conf"
  sed -i '/^wd_node_id[0-9]* = /d' "$pgpool_conf"
  sed -i '/^heartbeat_hostname[0-9]* = /d' "$pgpool_conf"
  sed -i '/^heartbeat_port[0-9]* = /d' "$pgpool_conf"
  sed -i '/^other_pgpool_hostname[0-9]* = /d' "$pgpool_conf"
  sed -i '/^other_pgpool_port[0-9]* = /d' "$pgpool_conf"

  # Split peers into array
  IFS=',' read -r -a peer_list <<< "$peers"

  # Generate watchdog configuration with local node first, using 0-based node ids
  # Sort peers so local node comes first (index 0)
  local sorted_peers=()
  local other_peers=()
  
  for peer in "${peer_list[@]}"; do
    peer="$(echo "$peer" | tr -d '[:space:]')"
    peer_id="${peer##*-}"
    if [ "$peer_id" -eq "$PGPOOL_NODE_ID" ]; then
      sorted_peers=("$peer" "${sorted_peers[@]}")
    else
      other_peers+=("$peer")
    fi
  done
  sorted_peers+=("${other_peers[@]}")
  
  # Now generate config with local node at index 0
  local idx=0
  for peer in "${sorted_peers[@]}"; do
    peer_id="${peer##*-}"
    
    # Use hostname for all nodes (Docker handles resolution)
    case "$peer" in
      "pgpool-1") host_addr="pgpool-1" ;;
      "pgpool-2") host_addr="pgpool-2" ;;
      "pgpool-3") host_addr="pgpool-3" ;;
      *) 
        # Fallback to getent for unknown services
        host_addr=$(getent hosts "$peer" | awk '{print $1}' | head -1)
        if [ -z "$host_addr" ]; then
          echo "[$(date)] Warning: Could not resolve IP for $peer, using hostname"
          host_addr="$peer"
        fi
        ;;
    esac
    
    # Use localhost for local watchdog, IP for heartbeat
    if [ "$peer_id" -eq "$PGPOOL_NODE_ID" ]; then
      host_addr="localhost"
    else
      # Use hostname for other nodes
      host_addr="$peer"
    fi
    
    echo "wd_hostname${idx} = '${host_addr}'" >> "$pgpool_conf"
    echo "wd_port${idx} = 9000" >> "$pgpool_conf"
    echo "wd_priority${idx} = ${peer_id}" >> "$pgpool_conf"
    echo "wd_node_id${idx} = ${peer_id}" >> "$pgpool_conf"

    # Append heartbeat lines
    echo "heartbeat_hostname${idx} = '${host_addr}'" >> "$pgpool_conf"
    echo "heartbeat_port${idx} = 9694" >> "$pgpool_conf"

    idx=$((idx + 1))
  done

  # Generate other_pgpool configuration for monitoring other nodes
  local other_idx=0
  for peer in "${sorted_peers[@]}"; do
    peer_id="${peer##*-}"
    if [ "$peer_id" -ne "$PGPOOL_NODE_ID" ]; then
      # Use hostname for other nodes
      local ip_addr
      case "$peer" in
        "pgpool-1") ip_addr="pgpool-1" ;;
        "pgpool-2") ip_addr="pgpool-2" ;;
        "pgpool-3") ip_addr="pgpool-3" ;;
        *) 
          ip_addr=$(getent hosts "$peer" | awk '{print $1}' | head -1)
          if [ -z "$ip_addr" ]; then
            ip_addr="$peer"
          fi
          ;;
      esac
      
      echo "other_pgpool_hostname${other_idx} = '${ip_addr}'" >> "$pgpool_conf"
      echo "other_pgpool_port${other_idx} = ${OTHER_PGPOOL_PORT}" >> "$pgpool_conf"
      other_idx=$((other_idx + 1))
    fi
  done

  echo "[$(date)] Watchdog configuration generated successfully"
}

# Copy default configuration templates into the config dir only if the
# target files are not present. This allows mounting a custom config dir.
if [ ! -f "$PGPOOL_CONF_PATH" ]; then
  echo "[$(date)] Copying default pgpool.conf into $PGPOOL_CONF_PATH..."
  cp /config/pgpool.conf "$PGPOOL_CONF_PATH"
fi
if [ ! -f "$POOL_HBA_PATH" ]; then
  echo "[$(date)] Copying default pool_hba.conf into $POOL_HBA_PATH..."
  cp /config/pool_hba.conf "$POOL_HBA_PATH"
fi
if [ ! -f "$PCP_CONF_PATH" ]; then
  echo "[$(date)] Copying default pcp.conf into $PCP_CONF_PATH (will be regenerated below)..."
  cp /config/pcp.conf "$PCP_CONF_PATH"
fi

# Expand environment variables in pgpool.conf
echo "[$(date)] Expanding environment variables in $PGPOOL_CONF_PATH..."
envsubst < "$PGPOOL_CONF_PATH" > "$PGPOOL_CONF_PATH.tmp" && mv "$PGPOOL_CONF_PATH.tmp" "$PGPOOL_CONF_PATH"

# Create pgpool_node_id file (required for watchdog) BEFORE generating config
PGPOOL_NODE_INDEX=${PGPOOL_NODE_ID}
echo "$PGPOOL_NODE_INDEX" > "$PGPOOL_CONF_DIR/pgpool_node_id"
chmod 644 "$PGPOOL_CONF_DIR/pgpool_node_id"
echo "[$(date)] Created pgpool_node_id file with INDEX: $PGPOOL_NODE_INDEX (from PGPOOL_NODE_ID=$PGPOOL_NODE_ID)"

# Watchdog is disabled in template for stability

# Watchdog is already enabled in the template

# Create server-side pcp.conf with MD5(password+username) entries (pcp expects md5<hash>)
mkdir -p "$PGPOOL_CONF_DIR"
# Compute MD5 of password+username as required by pcp.conf format
if [ -n "${PCP_USER:-}" ] && [ -n "${PCP_PASSWORD:-}" ]; then
  HASH=$(printf "%s%s" "${PCP_PASSWORD}" "${PCP_USER}" | md5sum | awk '{print $1}')
  echo "${PCP_USER}:md5${HASH}" > "$PCP_CONF_PATH"
  chown postgres:postgres "$PCP_CONF_PATH" || true
  chmod 600 "$PCP_CONF_PATH"
  echo "[$(date)] Created $PCP_CONF_PATH with user ${PCP_USER} (md5 entry)"
else
  echo "[$(date)] WARNING: PCP_USER or PCP_PASSWORD not set; leaving $PCP_CONF_PATH as-is"
fi

# Create .pcppass for monitor script (used by internal monitor helpers)
mkdir -p /var/lib/postgresql
if [ -n "${PCP_USER:-}" ] && [ -n "${PCP_PASSWORD:-}" ]; then
  echo "${PCP_HOST}:${PCP_PORT}:${PCP_USER}:${PCP_PASSWORD}" > /var/lib/postgresql/.pcppass
  chown postgres:postgres /var/lib/postgresql/.pcppass
  chmod 600 /var/lib/postgresql/.pcppass
  echo "[$(date)] Created /var/lib/postgresql/.pcppass file"

  # Also create /root/.pcppass so hooks executed as root can authenticate too
  echo "${PCP_HOST}:${PCP_PORT}:${PCP_USER}:${PCP_PASSWORD}" > /root/.pcppass
  chmod 600 /root/.pcppass
  chown root:root /root/.pcppass || true
  echo "[$(date)] Created /root/.pcppass file"
else
  echo "[$(date)] WARNING: PCP_USER or PCP_PASSWORD not set; not creating .pcppass files"
fi

# Update pgpool.conf with runtime values
echo "[$(date)] Configuring pgpool.conf with runtime values..."

# Update passwords in pgpool.conf (escape special characters for sed)
# Escape backslash, ampersand, forward slash, and hash for sed
REPMGR_PASSWORD_ESCAPED="${REPMGR_PASSWORD//\\/\\\\}"  # Escape backslash
REPMGR_PASSWORD_ESCAPED="${REPMGR_PASSWORD_ESCAPED//&/\\&}"  # Escape ampersand
REPMGR_PASSWORD_ESCAPED="${REPMGR_PASSWORD_ESCAPED//#/\\#}"  # Escape hash
REPMGR_PASSWORD_ESCAPED="${REPMGR_PASSWORD_ESCAPED//\'/\\\'}"  # Escape single quote

sed -i "s#sr_check_user = .*#sr_check_user = 'repmgr'#" "$PGPOOL_CONF_PATH"
sed -i "s#sr_check_password = .*#sr_check_password = '${REPMGR_PASSWORD_ESCAPED}'#" "$PGPOOL_CONF_PATH"
sed -i "s#health_check_user = .*#health_check_user = 'repmgr'#" "$PGPOOL_CONF_PATH"
sed -i "s#health_check_password = .*#health_check_password = '${REPMGR_PASSWORD_ESCAPED}'#" "$PGPOOL_CONF_PATH"
sed -i "s#wd_lifecheck_user = .*#wd_lifecheck_user = 'repmgr'#" "$PGPOOL_CONF_PATH"
sed -i "s#wd_lifecheck_password = .*#wd_lifecheck_password = '${REPMGR_PASSWORD_ESCAPED}'#" "$PGPOOL_CONF_PATH"

# Update backend hostnames from PGPOOL_BACKENDS environment variable
echo "[$(date)] Configuring backend hostnames from PGPOOL_BACKENDS: $PGPOOL_BACKENDS"
IFS=',' read -ra backends_arr <<< "$PGPOOL_BACKENDS"
backend_idx=0
for backend in "${backends_arr[@]}"; do
  backend_host=${backend%%:*}
  backend_port=${backend##*:}
  if [ -z "$backend_port" ] || [ "$backend_port" = "$backend_host" ]; then backend_port=5432; fi
  
  # Update backend_hostname and backend_port in pgpool.conf
  sed -i "s#backend_hostname${backend_idx} = .*#backend_hostname${backend_idx} = '${backend_host}'#" "$PGPOOL_CONF_PATH"
  sed -i "s#backend_port${backend_idx} = .*#backend_port${backend_idx} = ${backend_port}#" "$PGPOOL_CONF_PATH"
  
  echo "  ✓ Backend $backend_idx: ${backend_host}:${backend_port}"
  backend_idx=$((backend_idx + 1))
done

# Discover and wait for current primary (dynamic discovery)
echo "[$(date)] Discovering current primary in cluster..."

find_primary() {
  IFS=',' read -ra peers_arr <<< "$PGPOOL_BACKENDS"
  for p in "${peers_arr[@]}"; do
    host=${p%%:*}
    port=${p##*:}
    if [ -z "$port" ] || [ "$port" = "$host" ]; then port=5432; fi

    # Check if PostgreSQL is running
    if ! PGPASSWORD=$REPMGR_PASSWORD psql -h "$host" -p "$port" -U repmgr -d postgres -c "SELECT 1" > /dev/null 2>&1; then
      continue
    fi

    # Check if this node is primary (NOT in recovery)
    is_primary=$(PGPASSWORD=$REPMGR_PASSWORD psql -h "$host" -p "$port" -U repmgr -d postgres -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null)
    if [ "$is_primary" = "t" ]; then
      echo "${host}:${port}"
      return 0
    fi
  done
  return 1
}

# Wait for any primary to become available
# Retry behavior: if MAX_RETRIES is 0 we wait forever; otherwise we try MAX_RETRIES then switch to
# a background infinite retry loop (so the container does not exit). This ensures pgpool won't exit
# if the cluster is still forming.
RETRY_COUNT=0
MAX_RETRIES=${MAX_RETRIES:-60}
PRIMARY_NODE=""
PRIMARY_HOST=""
PRIMARY_PORT=5432

echo "[$(date)] Waiting for primary node to be discoverable (will keep retrying until found)"
while true; do
  PRIMARY_NODE=$(find_primary || true)
  if [ -n "$PRIMARY_NODE" ]; then
    # normalize host:port
    PRIMARY_HOST=${PRIMARY_NODE%%:*}
    PRIMARY_PORT=${PRIMARY_NODE##*:}
    echo "  ✓ Found primary: ${PRIMARY_HOST}:${PRIMARY_PORT}"
    break
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "  Waiting for primary... (attempt $RETRY_COUNT)"
  # If a finite max was configured and we've exceeded it, keep the container alive but continue
  # retrying in a slower, indefinite loop so the process doesn't exit.
  if [ "$MAX_RETRIES" -ne 0 ] && [ $RETRY_COUNT -ge "$MAX_RETRIES" ]; then
    echo "  ⚠ Reached configured MAX_RETRIES ($MAX_RETRIES) without finding a primary."
    echo "  Will stay in background retry loop until a primary appears (no exit)."
    # Enter a slower indefinite retry loop
    while [ -z "$PRIMARY_NODE" ]; do
      sleep 10
      PRIMARY_NODE=$(find_primary || true)
      if [ -n "$PRIMARY_NODE" ]; then
        echo "  ✓ Found primary (after extended wait): $PRIMARY_NODE"
        break 2
      fi
      echo "  Still waiting for primary..."
    done
  fi

  sleep 5
done

echo "[$(date)] Primary node is: ${PRIMARY_HOST}:${PRIMARY_PORT} - proceeding with setup..."

# Create pool_passwd file with user credentials
# For SCRAM-SHA-256, pgpool needs to query backend, so we use text format
echo "[$(date)] Creating pool_passwd with text format for SCRAM-SHA-256..."

# Create pool_passwd in text format (username:password)
# Pgpool will handle SCRAM authentication with backends
cat > "$PGPOOL_CONF_DIR/pool_passwd" <<EOF
postgres:$POSTGRES_PASSWORD
repmgr:$REPMGR_PASSWORD
app_readonly:$APP_READONLY_PASSWORD
app_readwrite:$APP_READWRITE_PASSWORD
pgpool:$REPMGR_PASSWORD
EOF

# set perms and ownership
chmod 600 "$PGPOOL_CONF_DIR/pool_passwd"
echo "[$(date)] pool_passwd created with $(wc -l < \"$PGPOOL_CONF_DIR/pool_passwd\") users"

# Set correct permissions
chown postgres:postgres "$PGPOOL_CONF_DIR"/* || true
chmod 600 "$PGPOOL_CONF_DIR/pool_passwd" || true
chmod 600 "$PCP_CONF_PATH" || true

# Wait for repmgr cluster metadata to be visible on the primary so pgpool
# can rely on cluster membership (prevents pgpool from starting before
# repmgr has registered nodes). Configurable via CLUSTER_MIN_NODES and
# CLUSTER_WAIT_RETRIES/CLUSTER_WAIT_INTERVAL.
CLUSTER_MIN_NODES=${CLUSTER_MIN_NODES:-1}
CLUSTER_WAIT_RETRIES=${CLUSTER_WAIT_RETRIES:-24}
CLUSTER_WAIT_INTERVAL=${CLUSTER_WAIT_INTERVAL:-5}
echo "[$(date)] Waiting for repmgr cluster metadata on $PRIMARY_NODE (need >= $CLUSTER_MIN_NODES nodes)"
cluster_ok=0
retry=0
while [ $retry -lt "$CLUSTER_WAIT_RETRIES" ]; do
  nodes=$(PGPASSWORD=$REPMGR_PASSWORD psql -h $PRIMARY_HOST -p $PRIMARY_PORT -U repmgr -d repmgr -tAc "SELECT count(*) FROM repmgr.nodes;" 2>/dev/null || echo "")
  nodes=$(echo "$nodes" | tr -d '[:space:]')
  if [ -n "$nodes" ] && [ "$nodes" -ge "$CLUSTER_MIN_NODES" ]; then
    echo "  ✓ repmgr cluster visible with $nodes node(s)"
    cluster_ok=1
    break
  fi
  retry=$((retry + 1))
  echo "  Waiting for repmgr metadata... (attempt $retry/$CLUSTER_WAIT_RETRIES)"
  sleep $CLUSTER_WAIT_INTERVAL
done
if [ $cluster_ok -ne 1 ]; then
  echo "  ⚠ Warning: timeout waiting for repmgr cluster metadata on $PRIMARY_NODE (need >= $CLUSTER_MIN_NODES)."
  echo "  Will continue to wait until repmgr metadata shows the required number of nodes to avoid starting pgpool too early."
  # Enter indefinite wait loop (don't exit the container) until cluster metadata reaches minimum nodes
  while true; do
    nodes=$(PGPASSWORD=$REPMGR_PASSWORD psql -h $PRIMARY_HOST -p $PRIMARY_PORT -U repmgr -d repmgr -tAc "SELECT count(*) FROM repmgr.nodes;" 2>/dev/null || echo "")
    nodes=$(echo "$nodes" | tr -d '[:space:]')
    if [ -n "$nodes" ] && [ "$nodes" -ge "$CLUSTER_MIN_NODES" ]; then
      echo "  ✓ repmgr cluster visible with $nodes node(s) (proceeding)"
      break
    fi
    echo "  Waiting for repmgr metadata to show >= $CLUSTER_MIN_NODES nodes (currently: ${nodes:-0})..."
    sleep $CLUSTER_WAIT_INTERVAL
  done
fi

# Create pgpool user in PostgreSQL if not exists (on primary node)
echo "[$(date)] Creating pgpool user on primary (${PRIMARY_HOST}:${PRIMARY_PORT})..."
PGPASSWORD=$POSTGRES_PASSWORD psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d postgres <<-EOSQL 2>/dev/null || true
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgpool') THEN
            CREATE USER pgpool WITH PASSWORD '${REPMGR_PASSWORD}';
        END IF;
    END
    \$\$;
    
    GRANT pg_monitor TO pgpool;
    GRANT CONNECT ON DATABASE postgres TO pgpool;
EOSQL

echo "[$(date)] Pgpool user created/verified on $PRIMARY_NODE"

# Test backend connections
echo "[$(date)] Testing backend connections..."
IFS=',' read -ra peers_arr <<< "$PGPOOL_BACKENDS"
for p in "${peers_arr[@]}"; do
  host=${p%%:*}
  port=${p##*:}
  if [ -z "$port" ] || [ "$port" = "$host" ]; then port=5432; fi
  if PGPASSWORD=$REPMGR_PASSWORD psql -h "$host" -p "$port" -U repmgr -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    echo "  ✓ ${host}:${port} is reachable"
  else
    echo "  ✗ ${host}:${port} is NOT reachable (may come online later)"
  fi
done

# Display configuration summary
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          Pgpool-II Configuration Summary                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Pgpool Node ID: $PGPOOL_NODE_ID"
echo "  Pgpool Hostname: $PGPOOL_HOSTNAME"
echo "  Watchdog Priority: $PGPOOL_NODE_ID"
echo "  Other Pgpool: ${OTHER_PGPOOL_HOSTNAME}:${OTHER_PGPOOL_PORT}"
echo ""
echo "  Backend Configuration:"
echo "    pg-1 (Primary):  weight=1 (writes + reads)"
echo "    pg-2 (Standby):  weight=1 (reads)"
echo "    pg-3 (Standby):  weight=1 (reads)"
echo "    pg-4 (Standby):  weight=1 (reads)"
echo ""
echo "  Features:"
echo "    ✓ Load Balancing: ON (statement-level)"
echo "    ✓ Streaming Replication Check: ON"
echo "    ✓ Health Check: ON (every 10s)"
echo "    ✓ Watchdog: ON (pgpool HA)"
echo "    ✓ Connection Pooling: ON"
echo ""
echo "  Ports:"
echo "    PostgreSQL: 5432"
echo "    PCP: 9898"
echo "    Watchdog: 9000"
echo "    Heartbeat: 9694"
echo ""
echo "══════════════════════════════════════════════════════════"
echo ""

# Start monitoring script in background if exists
if [ -f /usr/local/bin/monitor.sh ]; then
    echo "[$(date)] Starting monitoring script..."
    /usr/local/bin/monitor.sh &
fi

# Start pgpool auto-reconfiguration monitor in background
if [ -f /usr/local/bin/pgpool_monitor.sh ]; then
    echo "[$(date)] Starting pgpool active monitor (every 5s)..."
    # Run every 5 seconds in background
    /usr/local/bin/pgpool_monitor.sh &
fi

# Debug dump to help diagnose watchdog hostname/node-id mismatches
echo "[$(date)] Debug: dumping watchdog configuration and host info to /tmp/pgpool-debug.txt"
{
  echo "--- $PGPOOL_CONF_PATH (excerpt: wd_hostname / wd_node_id) ---"
  grep -E "^wd_hostname|^wd_node_id|^heartbeat_hostname|^other_pgpool_hostname" "$PGPOOL_CONF_PATH" || true
  echo "--- system hostname / fqdn ---"
  hostname || true
  hostname -f 2>/dev/null || true
  echo "--- /etc/hosts ---"
  cat /etc/hosts || true
  echo "--- end debug ---"
} > /tmp/pgpool-debug.txt 2>&1 || true
echo "[$(date)] Debug written to /tmp/pgpool-debug.txt"

# Show the debug file so its contents appear in the container logs (helps diagnosis)
echo "[$(date)] Showing debug file contents to logs:"
cat /tmp/pgpool-debug.txt || true

# Start pgpool-II
echo "[$(date)] Starting pgpool-II..."
exec gosu postgres pgpool -n -f "$PGPOOL_CONF_PATH" -F "$PCP_CONF_PATH" -a "$POOL_HBA_PATH"
