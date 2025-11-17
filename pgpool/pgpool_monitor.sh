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
LOG_PREFIX="PgPool Monitor"

# Logging helpers: only emit messages for errors or failover events (per request)
log_error() {
    # stderr for errors
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] ${LOG_PREFIX} ERROR: $*" >&2
}

log_failover() {
    # stdout for failover/important events
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] ${LOG_PREFIX} FAILOVER: $*"
}

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

# Intentionally quiet on startup. We only log on errors or failovers.

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
        # Use backend_application_name as a safe marker field (we'll store e.g. host_PRIMARY)
        appname=$(grep "^backend_application_name${i} = " "$PGPOOL_CONF" | awk -F"'" '{print $2}') || appname=""

        # If application name contains PRIMARY marker, return this backend as current primary
        case "$appname" in
            *PRIMARY*)
                echo "${hostname}:${port}"
                return 0
                ;;
        esac
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

    # Only produce logs when configuration actually changes or errors occur

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

        # current role as stored in pgpool.conf via backend_application_name marker
        current_appname=$(grep "^backend_application_name${i} = " "$PGPOOL_CONF" | awk -F"'" '{print $2}' || true)
        if echo "$current_appname" | grep -q "PRIMARY" >/dev/null 2>&1; then
            current_role="primary"
        else
            current_role="standby"
        fi

        if [ "$current_role" != "$desired_role" ]; then
            # update backend_application_name to reflect desired role (safe, documented field)
            new_appname="${backend_host}"
            if [ "$desired_role" = "primary" ]; then
                new_appname="${backend_host}_PRIMARY"
            else
                new_appname="${backend_host}_REPLICA"
            fi

            if grep -q "^backend_application_name${i} = " "$PGPOOL_CONF"; then
                sed -i "s|^backend_application_name${i} = .*|backend_application_name${i} = '${new_appname}'|" "$PGPOOL_CONF" || true
            else
                echo "backend_application_name${i} = '${new_appname}'" >> "$PGPOOL_CONF"
            fi

            # record the intended change; treat this as part of a failover/change
            log_failover "Updated backend_application_name${i}: ${current_appname} -> ${new_appname}"
            config_changed=true
        fi
    done

    if [ "$config_changed" = true ]; then
        log_failover "Configuration changed, reloading PgPool via PCP (primary=${primary_host}:${primary_port})"
        # Helper: try PCP reload, with optional password, and fall back to local SIGHUP if local reload fails
        reload_pcp_local() {
            local host=$1 port=$2
            # trying PCP reload; errors will be logged
            # (do not produce routine logs besides success/failure)
            if pcp_reload_config -h "$host" -p "$port" -U "${PCP_USER:-pcp_admin}" -w 2>/dev/null; then
                log_failover "PgPool configuration reloaded successfully via PCP (${host}:${port})"
                return 0
            fi
            # We rely on non-interactive .pcppass for passwordless PCP auth. Avoid piping passwords.
            # If pcp_reload_config with -w fails, fall back to local SIGHUP below.

            log_error "PCP reload failed on ${host}:${port}"
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
                        gosu postgres kill -HUP "$pgpool_pid" || log_error "Failed to send SIGHUP via gosu postgres to pid=$pgpool_pid"
                    else
                        kill -HUP "$pgpool_pid" || log_error "Failed to send SIGHUP to pgpool (pid=$pgpool_pid)"
                    fi
                    # on successful SIGHUP we consider this part of the failover flow and log above when config_changed
                    return 0
                else
                    log_error "Could not determine running pgpool PID (tried PIDFILE=$PIDFILE and ps lookup); cannot SIGHUP"
                fi
            fi
            return 1
        }

        if reload_pcp_local "$PCP_HOST" "$PCP_PORT"; then
            # success already logged inside reload_pcp_local
            :
        else
            log_error "Failed to reload PgPool via PCP or local SIGHUP"
        fi
    else
        # intentionally silent when nothing changed
    fi
}

# Main monitoring loop
while true; do
    # silent loop; only log on errors or when primary changes (failover)

    # Discover current primary
    primary_found=false
    primary_host=""
    primary_port=""

    # First, try to use repmgr metadata (authoritative) to find registered primary.
    # Query each backend's repmgr DB for the node registered as primary.
    for backend in "${BACKENDS[@]}"; do
        host=${backend%%:*}
        port=${backend##*:}
        # query repmgr for authoritative primary; errors below will be logged
        primary_node=$(query_repmgr_primary_on "$host" "$port" || true)
        if [ -n "$primary_node" ]; then
            # repmgr reports a primary node_name (usually hostname)
            # treat this as authoritative change if different
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

            role=$(node_role "$host" "$port")
            rc=$?
            if [ "$role" = "primary" ]; then
                # primary found => this is a change if different from stored
                primary_found=true
                primary_host="$host"
                primary_port="$port"
                break
            elif [ "$role" = "standby" ]; then
                # nothing to log for standbys
            else
                log_error "${host}:${port} is UNREACHABLE or ERROR"
            fi
        done
    fi

    # Update configuration if primary found
    if [ "$primary_found" = true ]; then
        current_primary=$(get_current_primary)
        new_primary="${primary_host}:${primary_port}"

        if [ "$current_primary" != "$new_primary" ]; then
            log_failover "Primary changed: ${current_primary} -> ${new_primary}"
            update_pgpool_config "$primary_host" "$primary_port"
        fi
    else
        log_error "No primary found in cluster"
    fi
    # Hourly cluster show logging: write repmgr cluster show output once per hour
    now_epoch=$(date +%s)
    if [ -z "${LAST_CLUSTER_SHOW_TS:-}" ]; then
        LAST_CLUSTER_SHOW_TS=0
    fi
    if [ $((now_epoch - LAST_CLUSTER_SHOW_TS)) -ge 3600 ]; then
        # append timestamped repmgr cluster show to a file for monitoring
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        CLUSTER_SHOW_FILE="$PGPOOL_LOG_DIR/repmgr_cluster_show.log"
        {
            echo "[$ts] repmgr cluster show dump"
            if command -v repmgr >/dev/null 2>&1; then
                repmgr -f /etc/repmgr/repmgr.conf cluster show 2>&1 || echo "repmgr cluster show failed"
            else
                echo "repmgr binary not found"
            fi
            echo
        } >> "$CLUSTER_SHOW_FILE" || log_error "Failed to write cluster show to $CLUSTER_SHOW_FILE"
        LAST_CLUSTER_SHOW_TS=$now_epoch
    fi

    sleep "$MONITOR_INTERVAL"
done