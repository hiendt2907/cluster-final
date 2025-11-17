#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/scenarios/utils.sh"

log "Promote hook triggered - updating cluster state immediately"

# Update cluster state immediately after promotion
if command -v repmgr >/dev/null 2>&1; then
  new_state=""
  if write_cluster_state_to_var new_state; then
    echo "$new_state" > "/tmp/cluster_state.json.tmp"
    chmod 600 "/tmp/cluster_state.json.tmp" || true
    chown postgres:postgres "/tmp/cluster_state.json.tmp" 2>/dev/null || true
    mv -f "/tmp/cluster_state.json.tmp" "$CLUSTER_STATE_FILE"
    sync
    chmod 600 "$CLUSTER_STATE_FILE" 2>/dev/null || true
    chown postgres:postgres "$CLUSTER_STATE_FILE" 2>/dev/null || true
    log "Cluster state updated after promotion"
  else
    warn "Failed to update cluster state after promotion"
  fi
else
  warn "repmgr not available in promote hook"
fi