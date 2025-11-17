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
REPMGR_PROMOTE_MAX_LAG_SECS="${REPMGR_PROMOTE_MAX_LAG_SECS:-30}"  # Increased: max 30s lag (was 5s)
REPMGR_FORCE_PROMOTE_FILE="${REPMGR_FORCE_PROMOTE_FILE:-/tmp/force_promote_override}"
REPMGR_PROMOTE_MIN_VISIBLE="${REPMGR_PROMOTE_MIN_VISIBLE:-2}"  # require at least N visible nodes (including candidate)
# Backwards-compat override: if true, previous behavior allowing promotion despite high lag is enabled
REPMGR_ALLOW_PROMOTE_WITH_HIGH_LAG="${REPMGR_ALLOW_PROMOTE_WITH_HIGH_LAG:-false}"

# Fencing lock file (distributed lock via shared volume or database)
PROMOTION_LOCK_FILE="${PROMOTION_LOCK_FILE:-/var/lib/postgresql/data/promotion.lock}"
PROMOTION_LOCK_TIMEOUT=60  # Max seconds to wait for lock (increased from 30)

log "Promotion guard invoked for node $(hostname)"
log "Config: MAX_LAG=${REPMGR_PROMOTE_MAX_LAG_SECS}s, LOCK_TIMEOUT=${PROMOTION_LOCK_TIMEOUT}s"

# Step 1: Check for force-promote override
if [ -f "$REPMGR_FORCE_PROMOTE_FILE" ]; then
    log "⚠️  Force-promote file detected: $REPMGR_FORCE_PROMOTE_FILE"
    log "Bypassing all checks and promoting immediately (manual override)"
    rm -f "$REPMGR_FORCE_PROMOTE_FILE"  # Remove to prevent accidental reuse
    exec gosu postgres repmgr standby promote -f "$REPMGR_CONF" --log-to-file
fi

# Step 2: Acquire promotion lock (fencing mechanism)
# This prevents split-brain: only one node can hold the lock at a time
log "Attempting to acquire promotion lock..."

# First, check if lock exists and is stale (older than 5 minutes)
if [ -d "$PROMOTION_LOCK_FILE" ]; then
    lock_age=$(($(date +%s) - $(stat -c %Y "$PROMOTION_LOCK_FILE" 2>/dev/null || echo 0)))
    if [ "$lock_age" -gt 300 ]; then  # 5 minutes
        log "⚠️  Found stale lock (age: ${lock_age}s > 300s), removing..."
        rm -rf "$PROMOTION_LOCK_FILE" 2>/dev/null || true
    fi
fi

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
existing_primary=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --csv 2>/dev/null | grep ',primary,' | cut -d, -f2 || true)

if [ -n "$existing_primary" ]; then
    log "Existing primary detected: $existing_primary - checking if reachable..."
    # Check if primary is reachable
    if psql -h "$existing_primary" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
        log_error "✗ Existing primary $existing_primary is reachable"
        log_error "Refusing to promote - potential split-brain scenario"
        exit 1
    else
        log "✓ Existing primary $existing_primary is unreachable - safe to promote"
    fi
else
    log "✓ No existing primary found, safe to proceed"
fi

# Step 4: Final pre-promote check - ensure PostgreSQL is ready
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

# Check visible nodes in cluster to ensure quorum/visibility
visible_nodes=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --csv 2>/dev/null | grep -E ',standby,.*,running,' | cut -d, -f2 || true)
visible_count=$(echo "$visible_nodes" | wc -l)
log "Visible standby nodes in cluster: ${visible_count} (list: $(echo "$visible_nodes" | tr '\n' ' '))"

# Query current replay lag in seconds for comparison
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
    log_error "✗ Unable to determine replication lag for this node (not in recovery or query failed)"
    exit 1
fi

log "This node replication lag: ${lag}s"

if [ "$visible_count" -eq 1 ]; then
    log "✓ Only 1 standby node visible - promoting immediately without further lag checks"
elif [ "$visible_count" -gt 1 ]; then
    log "Multiple standby nodes visible - comparing replication lag to select best candidate"
    
    # Query lag for all visible nodes
    min_lag=999999
    best_node=""
    current_node_lag="$lag"
    
    for node in $visible_nodes; do
        if [ "$node" = "$HOSTNAME" ]; then
            node_lag="$lag"
        else
            # Query lag from remote node
            node_lag=$(psql -h "$node" -U postgres -d postgres -tAc "$lag_query" 2>/dev/null || echo "NULL")
        fi
        
        if [ "$node_lag" != "NULL" ] && [ -n "$node_lag" ]; then
            log "Node $node lag: ${node_lag}s"
            if [ "$node_lag" -lt "$min_lag" ]; then
                min_lag="$node_lag"
                best_node="$node"
            fi
        else
            log "Unable to determine lag for node $node - excluding from comparison"
        fi
    done
    
    if [ -z "$best_node" ]; then
        log_error "✗ Unable to determine lag for any node - cannot select best candidate"
        exit 1
    fi
    
    log "Best candidate: $best_node with lag ${min_lag}s"
    
    if [ "$HOSTNAME" != "$best_node" ]; then
        log_error "✗ This node ($HOSTNAME) is not the best candidate (lag: ${current_node_lag}s vs best: ${min_lag}s)"
        log_error "Refusing promotion - waiting for $best_node to promote"
        exit 1
    else
        log "✓ This node ($HOSTNAME) has the lowest lag (${min_lag}s) - proceeding with promotion"
    fi
else
    log_error "✗ No visible standby nodes found"
    exit 1
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
exec gosu postgres repmgr standby promote -f "$REPMGR_CONF" --log-to-file

# Note: exec replaces this process, so code below never runs
# Lock cleanup happens via EXIT trap
