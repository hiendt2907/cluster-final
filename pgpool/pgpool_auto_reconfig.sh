#!/bin/bash
# pgpool_auto_reconfig.sh - Monitor PostgreSQL primary changes and trigger reconfiguration
set -euo pipefail

LOG_FILE="/var/log/pgpool/auto_reconfig.log"
STATE_FILE="/tmp/pgpool_primary_state"

# Create log directory
mkdir -p /var/log/pgpool

log() {
    echo "[$(date)] $*" >> "$LOG_FILE"
}

# Function to get current primary
get_current_primary() {
    local backends=${PGPOOL_BACKENDS:-"stg-pg-1,stg-pg-2,stg-pg-3"}
    IFS=',' read -ra nodes <<< "$backends"
    
    for node in "${nodes[@]}"; do
        host=${node%%:*}
        port=${node##*:}
        if [ -z "$port" ] || [ "$port" = "$host" ]; then port=5432; fi
        
        # Check if node is primary
        if PGPASSWORD=${REPMGR_PASSWORD:-supersecret_repmgr_password} psql -h "$host" -p "$port" -U repmgr -d postgres -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
            echo "${host}:${port}"
            return 0
        fi
    done
    return 1
}

# Main monitoring loop
main() {
    log "Starting pgpool auto-reconfiguration monitor"
    
    local previous_primary=""
    
    while true; do
        local current_primary
        
        # Get current primary
        if current_primary=$(get_current_primary 2>/dev/null); then
            # Check if changed
            if [ "$current_primary" != "$previous_primary" ]; then
                log "Primary changed: ${previous_primary:-none} -> $current_primary"
                
                # Trigger reconfiguration
                if /usr/local/bin/pgpool_reconfig.sh; then
                    log "Reconfiguration triggered successfully"
                    previous_primary="$current_primary"
                else
                    log "ERROR: Reconfiguration failed"
                fi
            fi
        else
            log "WARNING: Could not determine current primary"
        fi
        
        # Sleep before next check
        sleep 30
    done
}

main "$@"