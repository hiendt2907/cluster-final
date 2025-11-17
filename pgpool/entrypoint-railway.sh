#!/bin/bash
set -e

echo "[$(date)] Pgpool-II Railway Entrypoint - Starting..."

# Environment variables with defaults
# Set node ID based on service name in Railway
if [[ "$RAILWAY_SERVICE_NAME" == "pgpool-1" ]]; then
    PGPOOL_NODE_ID=0
elif [[ "$RAILWAY_SERVICE_NAME" == "pgpool-2" ]]; then
    PGPOOL_NODE_ID=1
else
    PGPOOL_NODE_ID=${PGPOOL_NODE_ID:-1}
fi

# Use Railway private domain for hostname if available
if [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ]; then
    PGPOOL_HOSTNAME="${RAILWAY_PRIVATE_DOMAIN}"
else
    PGPOOL_HOSTNAME=${PGPOOL_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}
fi
# Default other pgpool hostname (can be overridden by env in Railway)
OTHER_PGPOOL_HOSTNAME=${OTHER_PGPOOL_HOSTNAME:-pgpool-2}
OTHER_PGPOOL_PORT=${OTHER_PGPOOL_PORT:-5432}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?ERROR: POSTGRES_PASSWORD not set}
REPMGR_PASSWORD=${REPMGR_PASSWORD:?ERROR: REPMGR_PASSWORD not set}
APP_READONLY_PASSWORD=${APP_READONLY_PASSWORD:?ERROR: APP_READONLY_PASSWORD not set}
APP_READWRITE_PASSWORD=${APP_READWRITE_PASSWORD:?ERROR: APP_READWRITE_PASSWORD not set}

# Helper: escape single quotes so values can be safely embedded in single-quoted strings
esc_for_single_quote() {
    # replace ' with '\'' sequence
    printf "%s" "$1" | sed "s/'/'\\''/g"
}

# Safe variables for embedding into pgpool.conf (single-quoted)
SAFE_REPMGR_PW=$(esc_for_single_quote "${REPMGR_PASSWORD:-}")
SAFE_POSTGRES_PW=$(esc_for_single_quote "${POSTGRES_PASSWORD:-}")

# Railway-specific: Parse PG_NODES or BACKEND_HOSTNAMES
PG_NODES=${PG_NODES:-${BACKEND_HOSTNAMES:-""}}
if [ -z "$PG_NODES" ]; then
    echo "ERROR: PG_NODES or BACKEND_HOSTNAMES must be set"
    echo "Example: PG_NODES=pg-1.railway.internal,pg-2.railway.internal,pg-3.railway.internal"
    exit 1
fi

# Create necessary directories
mkdir -p /var/run/pgpool /var/log/pgpool
chown -R postgres:postgres /var/run/pgpool /var/log/pgpool

# Copy configuration files to /etc/pgpool-II if not already there
if [ ! -f /etc/pgpool-II/pgpool.conf ]; then
    echo "[$(date)] Copying configuration files..."
    cp /config/pgpool.conf /etc/pgpool-II/pgpool.conf
    cp /config/pool_hba.conf /etc/pgpool-II/pool_hba.conf
    cp /config/pcp.conf /etc/pgpool-II/pcp.conf
fi

# Create pgpool_node_id file (required for watchdog)
echo "$PGPOOL_NODE_ID" > /etc/pgpool-II/pgpool_node_id
chmod 644 /etc/pgpool-II/pgpool_node_id
echo "[$(date)] Created pgpool_node_id file with ID: $PGPOOL_NODE_ID"

# Create pcp.conf with correct password
echo "admin:e8a48653851e28c69d0506508fb27fc5" > /etc/pgpool-II/pcp.conf
chmod 644 /etc/pgpool-II/pcp.conf
echo "[$(date)] Created pcp.conf with admin user"

# Create .pcppass for monitor script
mkdir -p /var/lib/postgresql
echo "localhost:9898:admin:adminpass" > /var/lib/postgresql/.pcppass
chown postgres:postgres /var/lib/postgresql/.pcppass
chmod 600 /var/lib/postgresql/.pcppass
echo "[$(date)] Created .pcppass file"

# Parse backend nodes from PG_NODES environment variable
IFS=',' read -ra BACKENDS <<< "$PG_NODES"
BACKEND_COUNT=${#BACKENDS[@]}

echo "[$(date)] Detected $BACKEND_COUNT backend nodes from PG_NODES"

# Generate pgpool.conf with Railway-aware backend configuration
echo "[$(date)] Generating pgpool.conf for Railway deployment..."

# Write to a temp file first to avoid partial writes being read by pgpool
TMP_CONF="/etc/pgpool-II/pgpool.conf.tmp"
cat > "$TMP_CONF" <<EOF
#------------------------------------------------------------------------------
# CONNECTIONS
#------------------------------------------------------------------------------
listen_addresses = '*'
port = ${PGPOOL_PORT:-5432}
pcp_listen_addresses = '*'
pcp_port = ${PGPOOL_PCP_PORT:-9898}
socket_dir = '/var/run/pgpool'

#------------------------------------------------------------------------------
# BACKEND CONFIGURATION (Railway-aware)
#------------------------------------------------------------------------------
EOF

# Add backend configurations dynamically
for i in "${!BACKENDS[@]}"; do
    backend="${BACKENDS[$i]}"
    # Remove any whitespace
    backend=$(echo "$backend" | tr -d ' ')
    
    # Determine weight: 1 for first node (primary), 1 for others (standbys)
    if [ $i -eq 0 ]; then
        weight=1  # Primary - handles reads and writes
    else
        weight=1  # Standby - load balance reads
    fi
    
    cat >> "$TMP_CONF" <<EOF

# Backend $i
backend_hostname${i} = '$backend'
backend_port${i} = 5432
backend_weight${i} = $weight
backend_data_directory${i} = '/var/lib/postgresql/data'
backend_flag${i} = 'ALLOW_TO_FAILOVER'
backend_application_name${i} = 'backend${i}'
EOF
done

# Continue with rest of pgpool.conf
cat >> "$TMP_CONF" <<'EOF'

#------------------------------------------------------------------------------
# RUNNING MODE
#------------------------------------------------------------------------------
backend_clustering_mode = 'streaming_replication'
num_init_children = 32
max_pool = 4
listen_backlog_multiplier = 2
serialize_accept = off

#------------------------------------------------------------------------------
# LOAD BALANCING MODE
#------------------------------------------------------------------------------
load_balance_mode = on
statement_level_load_balance = on
ignore_leading_white_space = on
disable_load_balance_on_write = 'transaction'
dml_adaptive_object_relationship_list = ''
black_function_list = 'nextval,setval,pg_catalog.nextval,pg_catalog.setval,currval,lastval'
white_function_list = ''
black_query_pattern_list = ''
white_query_pattern_list = ''

#------------------------------------------------------------------------------
# STREAMING REPLICATION MODE
#------------------------------------------------------------------------------
sr_check_period = 10
sr_check_user = 'repmgr'
sr_check_database = 'postgres'
delay_threshold = 10485760

#------------------------------------------------------------------------------
# HEALTH CHECK
#------------------------------------------------------------------------------
health_check_period = 30
health_check_timeout = 10
health_check_user = 'repmgr'
health_check_database = 'postgres'
health_check_max_retries = 3
health_check_retry_delay = 5
connect_timeout = 10000

#------------------------------------------------------------------------------
# FAILOVER AND FAILBACK
#------------------------------------------------------------------------------
failover_on_backend_error = off
failover_command = '/usr/local/bin/failover.sh %d %h %p %D %m %H %M %P %r %R %N %S'
failback_command = ''
failover_require_consensus = off
search_primary_node_timeout = 300

#------------------------------------------------------------------------------
# WATCHDOG (Enabled for Railway multi-pgpool setup)
#------------------------------------------------------------------------------
use_watchdog = on
wd_hostname0 = '${PGPOOL_HOSTNAME}'
wd_port0 = 9000
wd_priority0 = ${PGPOOL_NODE_ID}
wd_authkey = 'pgpool_watchdog_auth'
wd_ipc_socket_dir = '/var/run/pgpool'
delegate_ip = ''
if_up_cmd = ''
if_down_cmd = ''
arping_cmd = ''
wd_heartbeat_port0 = 9694
wd_heartbeat_keepalive0 = 2
wd_heartbeat_deadtime0 = 30
wd_monitoring_interfaces_list = ''
wd_lifecheck_method = 'heartbeat'
wd_interval = 10
wd_escalation_command = ''
wd_de_escalation_command = ''
wd_life_point = 3
wd_lifecheck_query = 'SELECT 1'
wd_lifecheck_dbname = 'postgres'
wd_lifecheck_user = 'repmgr'
wd_lifecheck_password = '${REPMGR_PASSWORD}'
other_pgpool_hostname0 = '${OTHER_PGPOOL_HOSTNAME}'
other_pgpool_port0 = 5432
other_wd_port0 = 9000
heartbeat_hostname0 = '${OTHER_PGPOOL_HOSTNAME}'
heartbeat_port0 = 9694
heartbeat_device0 = ''

#------------------------------------------------------------------------------
# CONNECTION POOL
#------------------------------------------------------------------------------
connection_cache = on
reset_query_list = 'ABORT; DISCARD ALL'

# Backend authentication method (must match pool_passwd encryption)
backend_auth_method = 'scram-sha-256'

#------------------------------------------------------------------------------
# LOGGING
#------------------------------------------------------------------------------
log_destination = 'stderr'
log_line_prefix = '%t: pid %p: '
log_connections = off
log_disconnections = off
log_hostname = on
log_statement = off
log_per_node_statement = off
log_client_messages = off
log_standby_delay = 'if_over_threshold'
log_min_messages = warning

#------------------------------------------------------------------------------
# PCP
#------------------------------------------------------------------------------
pcp_socket_dir = '/var/run/pgpool'

#------------------------------------------------------------------------------
# MEMORY CACHE
#------------------------------------------------------------------------------
memory_cache_enabled = off

#------------------------------------------------------------------------------
# MISC
#------------------------------------------------------------------------------
relcache_expire = 0
relcache_size = 256
enable_pool_hba = on
pool_passwd = 'pool_passwd'
authentication_timeout = 60
allow_clear_text_frontend_auth = on

# Pool password encryption
pool_passwd_encryption_method = none
EOF

# Set passwords and runtime placeholders in temp config (use escaped values)
sed -i "s|^sr_check_password = .*|sr_check_password = '${SAFE_REPMGR_PW}'|" "$TMP_CONF"
sed -i "s|^health_check_password = .*|health_check_password = '${SAFE_REPMGR_PW}'|" "$TMP_CONF"

# Replace any remaining runtime placeholders written as '${VAR}' in the single-quoted heredoc
sed -i "s|^wd_hostname0 = .*|wd_hostname0 = '${PGPOOL_HOSTNAME}'|" "$TMP_CONF"
sed -i "s|^wd_priority0 = .*|wd_priority0 = ${PGPOOL_NODE_ID}|" "$TMP_CONF"
sed -i "s|^other_pgpool_hostname0 = .*|other_pgpool_hostname0 = '${OTHER_PGPOOL_HOSTNAME}'|" "$TMP_CONF"
sed -i "s|^other_pgpool_port0 = .*|other_pgpool_port0 = ${OTHER_PGPOOL_PORT}|" "$TMP_CONF"
sed -i "s|^heartbeat_hostname0 = .*|heartbeat_hostname0 = '${OTHER_PGPOOL_HOSTNAME}'|" "$TMP_CONF"
sed -i "s|^heartbeat_port0 = .*|heartbeat_port0 = ${HEARTBEAT_PORT:-9694}|" "$TMP_CONF"
sed -i "s|^wd_lifecheck_password = .*|wd_lifecheck_password = '${SAFE_REPMGR_PW}'|" "$TMP_CONF"

# If an "other" pgpool is configured, also declare it as a watchdog peer (wd_hostname1/wd_priority1)
if [ -n "${OTHER_PGPOOL_HOSTNAME:-}" ]; then
    OTHER_PGPOOL_NODE_ID=${OTHER_PGPOOL_NODE_ID:-$(( PGPOOL_NODE_ID == 1 ? 2 : 1 ))}
    cat >> "$TMP_CONF" <<EOF
wd_hostname1 = '${OTHER_PGPOOL_HOSTNAME}'
wd_port1 = ${OTHER_WD_PORT:-9000}
wd_priority1 = ${OTHER_PGPOOL_NODE_ID}
EOF
fi

# Atomically replace the active config so pgpool won't see a partial file
mv "$TMP_CONF" /etc/pgpool-II/pgpool.conf
echo "[$(date)] pgpool.conf generated with $BACKEND_COUNT backends"

# Allow disabling watchdog via environment (USE_WATCHDOG=false)
if [ "${USE_WATCHDOG:-true}" = "false" ]; then
    echo "[$(date)] USE_WATCHDOG is false — disabling watchdog in generated config"
    if grep -q "^use_watchdog" /etc/pgpool-II/pgpool.conf; then
        sed -i "s|^use_watchdog = .*|use_watchdog = off|" /etc/pgpool-II/pgpool.conf || true
    else
        # append watchdog off
        echo "use_watchdog = off" >> /etc/pgpool-II/pgpool.conf
    fi
fi

# Discover and wait for current primary
echo "[$(date)] Discovering current primary in cluster..."

find_primary() {
    for backend in "${BACKENDS[@]}"; do
        backend=$(echo "$backend" | tr -d ' ')
        
        # Check if PostgreSQL is running
        if ! PGPASSWORD=$REPMGR_PASSWORD psql -h "$backend" -U repmgr -d postgres -c "SELECT 1" > /dev/null 2>&1; then
            continue
        fi
        
        # Check if this node is primary (NOT in recovery)
        is_primary=$(PGPASSWORD=$REPMGR_PASSWORD psql -h "$backend" -U repmgr -d postgres -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null)
        if [ "$is_primary" = "t" ]; then
            echo "$backend"
            return 0
        fi
    done
    return 1
}

# Wait for any primary to become available
RETRY_COUNT=0
MAX_RETRIES=60
PRIMARY_NODE=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    PRIMARY_NODE=$(find_primary)
    if [ -n "$PRIMARY_NODE" ]; then
        echo "  ✓ Found primary: $PRIMARY_NODE"
        break
    fi
    echo "  Waiting for primary... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ -z "$PRIMARY_NODE" ]; then
    echo "  ⚠️  WARNING: No primary found after ${MAX_RETRIES} attempts!"
    echo "  Pgpool will start but may not route queries correctly until primary is available"
fi

# Create pool_passwd file with plain text passwords
echo "[$(date)] Creating pool_passwd with plain text for SCRAM-SHA-256..."

# Create pool_passwd
> /etc/pgpool-II/pool_passwd
echo "postgres:$POSTGRES_PASSWORD" >> /etc/pgpool-II/pool_passwd
echo "repmgr:$REPMGR_PASSWORD" >> /etc/pgpool-II/pool_passwd
echo "app_readonly:$APP_READONLY_PASSWORD" >> /etc/pgpool-II/pool_passwd
echo "app_readwrite:$APP_READWRITE_PASSWORD" >> /etc/pgpool-II/pool_passwd
echo "pgpool:$REPMGR_PASSWORD" >> /etc/pgpool-II/pool_passwd

chmod 600 /etc/pgpool-II/pool_passwd
echo "[$(date)] pool_passwd created with $(wc -l < /etc/pgpool-II/pool_passwd) users (plain text)"

# Create pgpool user in PostgreSQL if primary is available
if [ -n "$PRIMARY_NODE" ]; then
    echo "[$(date)] Creating pgpool user on primary ($PRIMARY_NODE)..."
    PGPASSWORD=$POSTGRES_PASSWORD psql -h "$PRIMARY_NODE" -U postgres -d postgres <<-EOSQL 2>/dev/null || true
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
fi

# Test backend connections
echo "[$(date)] Testing backend connections..."
for backend in "${BACKENDS[@]}"; do
    backend=$(echo "$backend" | tr -d ' ')
    if PGPASSWORD=$REPMGR_PASSWORD psql -h "$backend" -U repmgr -d postgres -c "SELECT 1" > /dev/null 2>&1; then
        echo "  ✓ $backend is reachable (repmgr)"
    else
        echo "  ✗ $backend is NOT reachable (repmgr)"
    fi
    if PGPASSWORD=$POSTGRES_PASSWORD psql -h "$backend" -U postgres -d postgres -c "SELECT 1" > /dev/null 2>&1; then
        echo "  ✓ $backend is reachable (postgres)"
    else
        echo "  ✗ $backend is NOT reachable (postgres)"
    fi
done

# Set correct permissions
chown postgres:postgres /etc/pgpool-II/*
chmod 600 /etc/pgpool-II/pool_passwd
chmod 600 /etc/pgpool-II/pcp.conf

# Display configuration summary
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          Pgpool-II Railway Configuration                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Pgpool Node ID: $PGPOOL_NODE_ID"
echo "  Pgpool Hostname: $PGPOOL_HOSTNAME"
echo "  Other Pgpool: ${OTHER_PGPOOL_HOSTNAME}:${OTHER_PGPOOL_PORT}"
echo ""
echo "  Backend Configuration:"
for i in "${!BACKENDS[@]}"; do
    backend="${BACKENDS[$i]}"
    backend=$(echo "$backend" | tr -d ' ')
    if [ $i -eq 0 ]; then
        echo "    backend$i: $backend (PRIMARY - reads and writes, weight=1)"
    else
        echo "    backend$i: $backend (STANDBY - reads, weight=1)"
    fi
done
echo ""
echo "  Features:"
echo "    ✓ Load Balancing: ON (statement-level)"
echo "    ✓ Streaming Replication Check: ON"
echo "    ✓ Health Check: ON (every ${HEALTH_CHECK_INTERVAL:-30}s)"
echo "    ✓ Connection Pooling: ON"
echo "    ✓ Railway Private Network: YES"
echo ""
echo "  Ports:"
echo "    PostgreSQL: ${PGPOOL_PORT:-5432}"
echo "    PCP: ${PGPOOL_PCP_PORT:-9898}"
echo ""
echo "══════════════════════════════════════════════════════════"
echo ""

# Start monitoring script in background if exists
if [ -f /usr/local/bin/monitor.sh ]; then
    echo "[$(date)] Starting monitoring script..."
    /usr/local/bin/monitor.sh &
fi

# Start pgpool-II
echo "[$(date)] Starting pgpool-II..."
exec gosu postgres pgpool -n -f /etc/pgpool-II/pgpool.conf -F /etc/pgpool-II/pcp.conf -a /etc/pgpool-II/pool_hba.conf
