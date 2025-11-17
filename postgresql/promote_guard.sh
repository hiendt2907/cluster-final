#!/bin/bash
# Promotion Guard Script with Fencing & Race Condition Prevention
# Called by repmgr before promoting a standby to primary
# Ensures only ONE primary exists at any time (split-brain prevention)

set -euo pipefail

# Logging
log() { echo "[$(date -Iseconds)] [promote_guard] $*" >&2; }
log_error() { echo "[$(date -Iseconds)] [promote_guard ERROR] $*" >&2; }

# Environment variables (set by repmgr or container)
REPMGR_CONF="${REPMGR_CONF:-/etc/repmgr/repmgr.conf}"
REPMGR_PROMOTE_MAX_LAG_SECS="${REPMGR_PROMOTE_MAX_LAG_SECS:-5}"  # Stricter: max 5s lag
REPMGR_FORCE_PROMOTE_FILE="${REPMGR_FORCE_PROMOTE_FILE:-/tmp/force_promote_override}"

# Fencing lock file (distributed lock via shared volume or database)
PROMOTION_LOCK_FILE="${PROMOTION_LOCK_FILE:-/var/lib/postgresql/data/promotion.lock}"
PROMOTION_LOCK_TIMEOUT=30  # Max seconds to wait for lock

log "Promotion guard invoked for node $(hostname)"
log "Config: MAX_LAG=${REPMGR_PROMOTE_MAX_LAG_SECS}s, LOCK_TIMEOUT=${PROMOTION_LOCK_TIMEOUT}s"

# Step 1: Check for force-promote override
if [ -f "$REPMGR_FORCE_PROMOTE_FILE" ]; then
    log "⚠️  Force-promote file detected: $REPMGR_FORCE_PROMOTE_FILE"
    log "Bypassing all checks and promoting immediately (manual override)"
    rm -f "$REPMGR_FORCE_PROMOTE_FILE"  # Remove to prevent accidental reuse
    exec repmgr standby promote -f "$REPMGR_CONF" --log-to-file
fi

# Step 2: Acquire promotion lock (fencing mechanism)
# This prevents split-brain: only one node can hold the lock at a time
log "Attempting to acquire promotion lock..."
lock_acquired=false
lock_start=$(date +%s)

while true; do
    # Try to create lock file atomically (mkdir is atomic on most filesystems)
    if mkdir "$PROMOTION_LOCK_FILE" 2>/dev/null; then
        log "✓ Acquired promotion lock: $PROMOTION_LOCK_FILE"
        lock_acquired=true
        trap 'rm -rf "$PROMOTION_LOCK_FILE"' EXIT  # Release lock on exit
        break
    fi
    
    # Check lock timeout
    now=$(date +%s)
    elapsed=$((now - lock_start))
    if [ "$elapsed" -ge "$PROMOTION_LOCK_TIMEOUT" ]; then
        log_error "✗ Failed to acquire promotion lock after ${PROMOTION_LOCK_TIMEOUT}s"
        log_error "Another node may be promoting or lock is stale"
        log_error "Manual intervention required: check cluster status and remove stale lock if needed"
        exit 1
    fi
    
    log "Lock held by another node, waiting... (${elapsed}/${PROMOTION_LOCK_TIMEOUT}s)"
    sleep 2
done

# Step 3: Verify no other primary exists (double-check split-brain)
log "Verifying no existing primary in cluster..."
existing_primary=$(repmgr -f "$REPMGR_CONF" cluster show --csv 2>/dev/null | grep ',primary,' | cut -d, -f2 || true)

if [ -n "$existing_primary" ]; then
    log_error "✗ Existing primary detected: $existing_primary"
    log_error "Refusing to promote - potential split-brain scenario"
    log_error "Investigate why old primary is still reporting as primary"
    exit 1
fi

log "✓ No existing primary found, safe to proceed"

# Step 4: Check replication lag
log "Checking replication lag..."

# Query current replay lag in seconds
lag_query="
SELECT CASE 
    WHEN pg_is_in_recovery() THEN 
        EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int
    ELSE 
        NULL 
END AS lag_seconds;
"

lag=$(psql -U postgres -d postgres -tAc "$lag_query" 2>/dev/null || echo "NULL")

if [ "$lag" = "NULL" ] || [ -z "$lag" ]; then
    # Not in recovery or query failed - this is unexpected
    log_error "✗ Unable to determine replication lag (not in recovery or query failed)"
    log_error "Current state: $(psql -U postgres -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo 'unknown')"
    
    # Conservative: refuse promotion if we can't verify lag
    log_error "Refusing promotion due to uncertainty"
    exit 1
fi

log "Current replication lag: ${lag}s (threshold: ${REPMGR_PROMOTE_MAX_LAG_SECS}s)"

if [ "$lag" -gt "$REPMGR_PROMOTE_MAX_LAG_SECS" ]; then
    log_error "✗ Replication lag ${lag}s exceeds threshold ${REPMGR_PROMOTE_MAX_LAG_SECS}s"
    
    # Check if this is the highest-priority standby available
    log "Checking if this is the best available candidate..."
    my_priority=$(grep '^priority=' "$REPMGR_CONF" | cut -d= -f2)
    my_node_id=$(grep '^node_id=' "$REPMGR_CONF" | cut -d= -f2)
    
    # Get all standbys and their priorities
    all_standbys=$(repmgr -f "$REPMGR_CONF" cluster show --csv 2>/dev/null | grep ',standby,' || true)
    
    if [ -z "$all_standbys" ]; then
        log "⚠️  No other standbys detected - promoting anyway to avoid cluster lockout"
        log "WARNING: Data loss possible due to high lag"
    else
        # Parse standbys and find highest priority
        highest_priority=-999
        while IFS=, read -r node_id node_name role status upstream priority_str rest; do
            priority=${priority_str:-0}
            if [ "$priority" -gt "$highest_priority" ]; then
                highest_priority=$priority
            fi
        done <<< "$all_standbys"
        
        if [ "$my_priority" -ge "$highest_priority" ]; then
            log "⚠️  This node has highest priority ($my_priority) among available standbys"
            log "Promoting despite lag to avoid cluster lockout"
            log "WARNING: Potential data loss of ~${lag}s of transactions"
        else
            log_error "✗ Higher priority standby exists - refusing promotion"
            log_error "Expected a higher-priority node to promote"
            exit 1
        fi
    fi
else
    log "✓ Replication lag ${lag}s is within acceptable threshold"
fi

# Step 5: Final pre-promote check - ensure PostgreSQL is ready
log "Verifying PostgreSQL is ready for promotion..."
if ! psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    log_error "✗ PostgreSQL not responding to queries"
    exit 1
fi

if ! psql -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q 't'; then
    log_error "✗ Node is not in recovery mode - cannot promote"
    exit 1
fi

log "✓ PostgreSQL is ready for promotion"

# Step 6: Perform promotion
log "═══════════════════════════════════════════════════════════"
log "✓ All checks passed - PROMOTING TO PRIMARY"
log "═══════════════════════════════════════════════════════════"

# Execute repmgr promote command
exec repmgr standby promote -f "$REPMGR_CONF" --log-to-file

# Note: exec replaces this process, so code below never runs
# Lock cleanup happens via EXIT trap
