#!/bin/bash

# PgPool Monitor Script - Active Failover Detection
# Monitors PostgreSQL nodes and updates PgPool configuration dynamically
# Runs every 5 seconds to detect primary/standby changes

set -e

# Configuration
MONITOR_INTERVAL=${MONITOR_INTERVAL:-5}
# Use environment-driven config paths if provided by entrypoint
PGPOOL_CONF="${PGPOOL_CONF_PATH:-/etc/pgpool-II/pgpool.conf}"
PGPOOL_LOG_DIR=${PGPOOL_LOG_DIR:-/var/log/pgpool}
mkdir -p "$PGPOOL_LOG_DIR" || true
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] PgPool Monitor"

# PostgreSQL connection details
PG_USER="${SR_CHECK_USER:-repmgr}"
PG_PASSWORD="${REPMGR_PASSWORD:-}"
PG_DATABASE="${SR_CHECK_DATABASE:-postgres}"
PG_CONNECT_TIMEOUT=5

# PCP (pgpool control) credentials - used to reload config at runtime
PCP_USER=${PCP_USER:-pcp_admin}
PCP_PASSWORD=${PCP_PASSWORD:-}
PCP_HOST=${PCP_HOST:-localhost}
PCP_PORT=${PCP_PORT:-9898}

# Backend configuration (from environment)
IFS=',' read -ra BACKENDS <<< "${PGPOOL_BACKENDS:-pg-1:5432,pg-2:5432,pg-3:5432}"
BACKEND_COUNT=${#BACKENDS[@]}

echo "$LOG_PREFIX Starting PgPool monitor (interval: ${MONITOR_INTERVAL}s)"

# Function to check if a node is in recovery (standby)
# Prefer repmgr metadata when available: query repmgr.nodes on the node's repmgr DB
query_repmgr_primary_on() {
    local host=$1 port=${2:-5432}
    if [ -z "${REPMGR_PASSWORD:-}" ]; then
        return 1
    fi
    PGPASSWORD="$REPMGR_PASSWORD" psql -h "$host" -p "$port" -U repmgr -d repmgr -tAc \
        "SELECT node_name FROM repmgr.nodes WHERE type='primary' AND active='t' LIMIT 1;" 2>/dev/null | tr -d '[:space:]' || true
}

node_role() {
    # Returns one of: primary | standby | error
    local host=$1
    local port=$2

    local result
    result=$(PGPASSWORD="$PG_PASSWORD" psql \
        -h "$host" \
        -p "$port" \
        -U "$PG_USER" \
        -d "$PG_DATABASE" \
        -tAc "SELECT pg_is_in_recovery();" \
        --connect-timeout="$PG_CONNECT_TIMEOUT" 2>/dev/null) || true

    result=$(echo "$result" | tr -d '[:space:]')

    if [ "$result" = "t" ]; then
        echo "standby"
        return 0
    elif [ "$result" = "f" ]; then
        echo "primary"
        return 0
    else
        echo "error"
        return 2
    fi
}

# Function to get current primary from PgPool config
get_current_primary() {
    # Determine current primary as defined in pgpool.conf by looking for backend_flag or custom marker.
    # Fallback: return the first backend hostname:port
    for i in $(seq 0 $((BACKEND_COUNT - 1))); do
        hostname=$(grep "^backend_hostname${i} = " "$PGPOOL_CONF" | awk -F"'" '{print $2}') || hostname=""
        port=$(grep "^backend_port${i} = " "$PGPOOL_CONF" | awk '{print $3}') || port=""
        flag=$(grep "^backend_flag${i} = " "$PGPOOL_CONF" | awk -F"'" '{print $2}') || flag=""

        # If flag contains PRIMARY (custom), return it. Otherwise continue.
        if [ "$flag" = "PRIMARY" ]; then
            echo "${hostname}:${port}"
            return 0
        fi
    done

    # fallback: return first backend
    if [ ${BACKEND_COUNT} -gt 0 ]; then
        first=${BACKENDS[0]}
        echo "$first"
    else
        echo "none"
    fi
}

# Function to update PgPool configuration
update_pgpool_config() {
    local primary_host=$1
    local primary_port=$2
    local config_changed=false

    echo "$LOG_PREFIX Updating PgPool configuration - Primary: ${primary_host}:${primary_port}"

    for i in $(seq 0 $((BACKEND_COUNT - 1))); do
        backend="${BACKENDS[$i]}"
        backend_host=${backend%%:*}
        backend_port=${backend##*:}

        # desired role
        if [ "$backend_host" = "$primary_host" ] && [ "$backend_port" = "$primary_port" ]; then
            desired_role="primary"
        else
            desired_role="standby"
        fi

        # current role as stored in pgpool.conf via backend_flag (we use PRIMARY/REPLICA marker)
        current_flag=$(grep "^backend_flag${i} = " "$PGPOOL_CONF" | awk -F"'" '{print $2}' || true)
        if [ "$current_flag" = "PRIMARY" ]; then
            current_role="primary"
        else
            current_role="standby"
        fi

        if [ "$current_role" != "$desired_role" ]; then
            # update backend_flag to reflect desired role
            if grep -q "^backend_flag${i} = " "$PGPOOL_CONF"; then
                # Use PRIMARY/REPLICA flags as marker
                if [ "$desired_role" = "primary" ]; then
                    sed -i "s|^backend_flag${i} = .*|backend_flag${i} = 'PRIMARY'|" "$PGPOOL_CONF" || true
                else
                    sed -i "s|^backend_flag${i} = .*|backend_flag${i} = 'REPLICA'|" "$PGPOOL_CONF" || true
                fi
            else
                if [ "$desired_role" = "primary" ]; then
                    echo "backend_flag${i} = 'PRIMARY'" >> "$PGPOOL_CONF"
                else
                    echo "backend_flag${i} = 'REPLICA'" >> "$PGPOOL_CONF"
                fi
            fi

            echo "$LOG_PREFIX Updated backend_flag${i}: ${current_flag} -> $( [ "$desired_role" = "primary" ] && echo PRIMARY || echo REPLICA )"
            config_changed=true
        fi
    done

    if [ "$config_changed" = true ]; then
        echo "$LOG_PREFIX Configuration changed, reloading PgPool via PCP..."
        # Helper: try PCP reload, with optional password, and fall back to local SIGHUP if local reload fails
        reload_pcp_local() {
            local host=$1 port=$2
            echo "$LOG_PREFIX Attempting pcp_reload_config on ${host}:${port}"
            if pcp_reload_config -h "$host" -p "$port" -U "${PCP_USER:-pcp_admin}" -w 2>/dev/null; then
                echo "$LOG_PREFIX ✓ PgPool configuration reloaded successfully via PCP"
                return 0
            fi
            # We rely on non-interactive .pcppass for passwordless PCP auth. Avoid piping passwords.
            # If pcp_reload_config with -w fails, fall back to local SIGHUP below.

            echo "$LOG_PREFIX ✗ PCP reload failed on ${host}:${port}"
            # If this is the local host, try local SIGHUP fallback
            local local_host
            local_host=$(hostname)
            if [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ] || [ "$host" = "$local_host" ]; then
                PIDFILE=/var/run/pgpool/pgpool.pid
                # Try PID file first, then fallback to ps lookup
                pgpool_pid=""
                if [ -f "$PIDFILE" ]; then
                    pgpool_pid=$(cat "$PIDFILE" 2>/dev/null || true)
                fi
                if [ -z "$pgpool_pid" ]; then
                    pgpool_pid=$(ps -eo pid,cmd | awk '/pgpool -n -f/ && !/awk/ {print $1; exit}' || true)
                fi
                if [ -n "$pgpool_pid" ] && ps -p "$pgpool_pid" > /dev/null 2>&1; then
                    if command -v gosu >/dev/null 2>&1; then
                        gosu postgres kill -HUP "$pgpool_pid" && echo "$LOG_PREFIX Sent SIGHUP to pgpool (pid=$pgpool_pid)" || echo "$LOG_PREFIX Failed to send SIGHUP via gosu postgres"
                    else
                        kill -HUP "$pgpool_pid" && echo "$LOG_PREFIX Sent SIGHUP to pgpool (pid=$pgpool_pid)" || echo "$LOG_PREFIX Failed to send SIGHUP to pgpool (pid=$pgpool_pid)"
                    fi
                    return 0
                else
                    echo "$LOG_PREFIX Could not determine running pgpool PID (tried PIDFILE=$PIDFILE and ps lookup); cannot SIGHUP"
                fi
            fi
            return 1
        }

        if reload_pcp_local "$PCP_HOST" "$PCP_PORT"; then
            echo "$LOG_PREFIX ✓ PgPool reloaded"
        else
            echo "$LOG_PREFIX ✗ Failed to reload PgPool via PCP or local SIGHUP"
        fi
    else
        echo "$LOG_PREFIX No configuration changes needed"
    fi
}

# Main monitoring loop
while true; do
    echo "$LOG_PREFIX Checking cluster status..."

    # Discover current primary
    primary_found=false
    primary_host=""
    primary_port=""

    # First, try to use repmgr metadata (authoritative) to find registered primary.
    # Query each backend's repmgr DB for the node registered as primary.
    for backend in "${BACKENDS[@]}"; do
        host=${backend%%:*}
        port=${backend##*:}
        echo "$LOG_PREFIX Querying repmgr on ${host}:${port} for registered primary..."
        primary_node=$(query_repmgr_primary_on "$host" "$port" || true)
        if [ -n "$primary_node" ]; then
            # repmgr reports a primary node_name (usually hostname)
            echo "$LOG_PREFIX repmgr reports primary: $primary_node"
            primary_found=true
            primary_host="$primary_node"
            primary_port=5432
            break
        fi
    done

    # If repmgr metadata didn't yield a primary, fall back to direct pg_is_in_recovery checks
    if [ "$primary_found" != true ]; then
        for backend in "${BACKENDS[@]}"; do
            host=${backend%%:*}
            port=${backend##*:}

            echo "$LOG_PREFIX Checking ${host}:${port}..."

            role=$(node_role "$host" "$port")
            rc=$?
            if [ "$role" = "primary" ]; then
                echo "$LOG_PREFIX   ${host}:${port} is PRIMARY"
                primary_found=true
                primary_host="$host"
                primary_port="$port"
                break
            elif [ "$role" = "standby" ]; then
                echo "$LOG_PREFIX   ${host}:${port} is STANDBY"
            else
                echo "$LOG_PREFIX   ${host}:${port} is UNREACHABLE or ERROR"
            fi
        done
    fi

    # Update configuration if primary found
    if [ "$primary_found" = true ]; then
        current_primary=$(get_current_primary)
        new_primary="${primary_host}:${primary_port}"

        if [ "$current_primary" != "$new_primary" ]; then
            echo "$LOG_PREFIX Primary changed: ${current_primary} -> ${new_primary}"
            update_pgpool_config "$primary_host" "$primary_port"
        else
            echo "$LOG_PREFIX Primary unchanged: ${current_primary}"
        fi
    else
        echo "$LOG_PREFIX No primary found in cluster"
    fi

    echo "$LOG_PREFIX Sleeping ${MONITOR_INTERVAL}s..."
    sleep "$MONITOR_INTERVAL"
done