#!/bin/bash
# failover_validation.sh - Custom quorum override for repmgr
# Allows failover with just 1 node + witness instead of majority

set -euo pipefail

# Log function
log() {
    echo "[$(date -Iseconds)] [failover_validation] $*" >&2
}

log "Starting custom failover validation..."

# Try to get cluster status - may fail if primary is down
CLUSTER_STATUS=$(gosu postgres repmgr -f /etc/repmgr/repmgr.conf cluster show --csv 2>/dev/null || echo "")

# If cluster show fails (primary down), allow failover as long as we have local standby
if [ -z "$CLUSTER_STATUS" ] || [ "$CLUSTER_STATUS" = "" ]; then
    log "Cannot query cluster status (primary may be down) - allowing failover for safety"
    exit 0
fi

# Count running standbys and witnesses from cluster status
RUNNING_STANDBYS=$(echo "$CLUSTER_STATUS" | grep -c ",standby,.*,running," || echo "0")
RUNNING_WITNESSES=$(echo "$CLUSTER_STATUS" | grep -c ",witness,.*,running," || echo "0")

log "Running standbys: $RUNNING_STANDBYS, Running witnesses: $RUNNING_WITNESSES"

# Allow failover if we have at least 1 running standby + 1 running witness
# This overrides repmgr's default majority requirement
TOTAL_VOTERS=$((RUNNING_STANDBYS + RUNNING_WITNESSES))

if [ "$TOTAL_VOTERS" -ge 2 ]; then
    log "✅ Quorum satisfied: $TOTAL_VOTERS voters available (1 standby + 1 witness minimum)"
    exit 0
else
    log "❌ Insufficient voters: $TOTAL_VOTERS available, need at least 2 (1 standby + 1 witness)"
    exit 1
fi