#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Periodically update $PGDATA/cluster_state.json from repmgr every 30min or on change.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/utils.sh"

INTERVAL=${INTERVAL:-5}  # 5 seconds for faster updates

# Initial update on startup
if command -v repmgr >/dev/null 2>&1; then
  new_state=""
  if write_cluster_state_to_var new_state; then
    old_state=""
    if [ -f "$CLUSTER_STATE_FILE" ]; then
      old_state=$(cat "$CLUSTER_STATE_FILE")
    fi
    if [ "$new_state" != "$old_state" ]; then
      echo "$new_state" > "/tmp/cluster_state.json.tmp"
      chmod 600 "/tmp/cluster_state.json.tmp" || true
      chown postgres:postgres "/tmp/cluster_state.json.tmp" 2>/dev/null || true
      mv -f "/tmp/cluster_state.json.tmp" "$CLUSTER_STATE_FILE"
      sync
      chmod 600 "$CLUSTER_STATE_FILE" 2>/dev/null || true
      chown postgres:postgres "$CLUSTER_STATE_FILE" 2>/dev/null || true
    fi
  fi
fi

while true; do
  if command -v repmgr >/dev/null 2>&1; then
    # Get new state
    new_state=""
    if write_cluster_state_to_var new_state; then
      # Read old state
      old_state=""
      if [ -f "$CLUSTER_STATE_FILE" ]; then
        old_state=$(cat "$CLUSTER_STATE_FILE")
      fi
      # If changed, write to /tmp first then mv
      if [ "$new_state" != "$old_state" ]; then
        echo "$new_state" > "/tmp/cluster_state.json.tmp"
        chmod 600 "/tmp/cluster_state.json.tmp" || true
        chown postgres:postgres "/tmp/cluster_state.json.tmp" 2>/dev/null || true
        mv -f "/tmp/cluster_state.json.tmp" "$CLUSTER_STATE_FILE"
        sync
        chmod 600 "$CLUSTER_STATE_FILE" 2>/dev/null || true
        chown postgres:postgres "$CLUSTER_STATE_FILE" 2>/dev/null || true
      fi
    fi
  fi
  sleep "$INTERVAL"
done
