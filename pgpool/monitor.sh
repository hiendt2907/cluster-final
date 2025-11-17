#!/usr/bin/env bash
# Monitor pgpool-II health and backend status (minimal logging)

PREV_BACKEND_STATUS=""

while true; do
    sleep 60
    
    # Check pgpool process
    if ! pgrep -x pgpool > /dev/null 2>&1; then
        echo "[$(date -Iseconds)] [CRITICAL] ⚠️  pgpool process not running!"
        exit 1
    fi
    
        # Simple health check - try to connect to pgpool
        # Use POSTGRES_PASSWORD (from env) to avoid interactive password prompt
        # Prefer checking actual Postgres backends instead of only localhost to avoid
        # race conditions where PgPool is up but backends are still registering.
    REPMGR_PW=${REPMGR_PASSWORD:-${POSTGRES_PASSWORD:-}}
    # Prefer PGPOOL_BACKENDS (set by entrypoint). Fall back to legacy PG_BACKENDS
    BACKENDS_VAR=${PGPOOL_BACKENDS:-${PG_BACKENDS:-"localhost:5432"}}
        IFS=',' read -ra BACKENDS <<< "$BACKENDS_VAR"

        ok=0
        for backend in "${BACKENDS[@]}"; do
            host=$(echo "$backend" | cut -d: -f1)
            port=$(echo "$backend" | cut -s -d: -f2)
            if [ -z "$port" ]; then port=5432; fi

            # Try a few times per backend before moving to next
            attempt=0
            max_attempts=3
            while [ $attempt -lt $max_attempts ]; do
                if timeout 2 bash -c "PGPASSWORD='$REPMGR_PW' psql -h '$host' -p $port -U repmgr -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
                    echo "[$(date -Iseconds)] [INFO] ✓ Backend $host:$port reachable"
                    ok=1
                    break 2
                fi
                attempt=$((attempt + 1))
                sleep 1
            done
        done

        if [ $ok -ne 1 ]; then
            echo "[$(date -Iseconds)] [WARNING] ⚠️  Cannot reach any configured backend (checked: ${BACKENDS_VAR})"
        fi
    
    # Log that monitoring is working (reduced frequency)
    if [ $(($(date +%s) % 300)) -eq 0 ]; then  # Every 5 minutes
        echo "[$(date -Iseconds)] [INFO] ✓ PgPool monitoring active"
    fi
done
