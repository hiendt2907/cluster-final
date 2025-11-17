#!/bin/bash
# pgpool_reconfig.sh - Detect primary PostgreSQL node and update pgpool backend configuration
set -euo pipefail

PGPOOL_LOG_DIR=${PGPOOL_LOG_DIR:-/var/log/pgpool}
LOG_FILE="$PGPOOL_LOG_DIR/reconfig.log"
STATE_FILE="/tmp/pgpool_primary_state"

# Create log directory
mkdir -p "$PGPOOL_LOG_DIR"

log() {
    echo "[$(date)] $*" | tee -a "$LOG_FILE"
}

# Function to get current primary node
get_primary_node() {
    local backends=${PGPOOL_BACKENDS:-"pg-1:5432,pg-2:5432,pg-3:5432"}
    IFS=',' read -ra nodes <<< "$backends"
    
    for node in "${nodes[@]}"; do
        host=${node%%:*}
        port=${node##*:}
        if [ -z "$port" ] || [ "$port" = "$host" ]; then port=5432; fi
        
        # Check if node is reachable and primary
        if PGPASSWORD=${REPMGR_PASSWORD:-supersecret_repmgr_password} psql -h "$host" -p "$port" -U ${REPMGR_USER:-repmgr} -d ${SR_CHECK_DATABASE:-postgres} -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
            echo "${host}:${port}"
            return 0
        fi
    done
    return 1
}

# Function to update pgpool backends
update_pgpool_backends() {
    local primary="$1"
    local primary_host=${primary%%:*}
    local primary_port=${primary##*:}
    
    log "Updating pgpool backends - Primary: $primary"
    
    # Use configurable pgpool conf path
    PGPOOL_CONF_PATH=${PGPOOL_CONF_PATH:-/etc/pgpool-II/pgpool.conf}

    # Update pgpool.conf backends
    sed -i "s#backend_hostname0 = .*#backend_hostname0 = '${primary_host}'#" "$PGPOOL_CONF_PATH"
    sed -i "s#backend_port0 = .*#backend_port0 = ${primary_port}#" "$PGPOOL_CONF_PATH"
    sed -i "s#backend_weight0 = .*#backend_weight0 = 1#" "$PGPOOL_CONF_PATH"
    
    # Set other backends as read-only with weight 1
    local backends=${PGPOOL_BACKENDS:-"stg-pg-1,stg-pg-2,stg-pg-3"}
    IFS=',' read -ra nodes <<< "$backends"
    local idx=1
    for node in "${nodes[@]}"; do
        host=${node%%:*}
        if [ "$host" != "$primary_host" ]; then
            port=${node##*:}
            if [ -z "$port" ] || [ "$port" = "$host" ]; then port=5432; fi
            
            sed -i "s#backend_hostname${idx} = .*#backend_hostname${idx} = '${host}'#" "$PGPOOL_CONF_PATH"
            sed -i "s#backend_port${idx} = .*#backend_port${idx} = ${port}#" "$PGPOOL_CONF_PATH"
            sed -i "s#backend_weight${idx} = .*#backend_weight${idx} = 1#" "$PGPOOL_CONF_PATH"
            idx=$((idx + 1))
        fi
    done
    
    log "Pgpool configuration updated"
}

# Function to reload pgpool
reload_pgpool() {
    log "Reloading pgpool configuration"
    PCP_USER=${PCP_USER:-pcp_admin}
    PCP_PASSWORD=${PCP_PASSWORD:-}
    PCP_HOST=${PCP_HOST:-localhost}
    PCP_PORT=${PCP_PORT:-9898}

    # Prefer non-interactive .pcppass file for PCP auth. Use -w to avoid prompts
    if pcp_reload_config -h "$PCP_HOST" -p "$PCP_PORT" -U "${PCP_USER:-pcp_admin}" -w >/dev/null 2>&1; then
        log "Pgpool reloaded successfully (pcp_reload_config)"
        return 0
    else
        log "Failed to reload pgpool via pcp_reload_config; ensure /root/.pcppass or /var/lib/postgresql/.pcppass exists and has correct creds"
        return 1
    fi
}

# Main logic
main() {
    local current_primary
    local previous_primary=""
    
    # Read previous state
    if [ -f "$STATE_FILE" ]; then
        previous_primary=$(cat "$STATE_FILE")
    fi
    
    # Get current primary
    if ! current_primary=$(get_primary_node); then
        log "ERROR: Could not determine primary node"
        exit 1
    fi
    
    log "Current primary: $current_primary, Previous: ${previous_primary:-none}"
    
    # Check if primary changed
    if [ "$current_primary" != "$previous_primary" ]; then
        log "Primary changed from $previous_primary to $current_primary"
        
        # Update configuration
        update_pgpool_backends "$current_primary"
        reload_pgpool
        
        # Save new state
        echo "$current_primary" > "$STATE_FILE"
        
        log "Reconfiguration completed successfully"
    else
        log "Primary unchanged"
    fi
}

main "$@"