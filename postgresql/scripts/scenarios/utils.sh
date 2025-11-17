#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Common helpers used by scenario scripts (non-Docker / Railway-friendly)

REPMGR_CONF=${REPMGR_CONF:-/etc/repmgr/repmgr.conf}
REPMGR_USER=${REPMGR_USER:-repmgr}
REPMGR_DB=${REPMGR_DB:-repmgr}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-}
PGDATA=${PGDATA:-/var/lib/postgresql/data}
NODE_NAME=${NODE_NAME:-$(hostname)}
NODE_ID=${NODE_ID:-}
PRIMARY_HINT=${PRIMARY_HINT:-}
CLUSTER_STATE_FILE=${CLUSTER_STATE_FILE:-"$PGDATA/cluster_state.json"}

log() { printf '[%s] [INFO] %s\n' "$(date -Iseconds)" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(date -Iseconds)" "$*"; }
err() { printf '[%s] [ERROR] %s\n' "$(date -Iseconds)" "$*" >&2; }
die() { err "$*"; exit 1; }

require_cmds() {
  local missing=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required commands: ${missing[*]}. Install them or adjust PATH."
  fi
}

run_as_postgres() {
  # prefer gosu, fall back to sudo -u postgres, then su - postgres -c
  if command -v gosu >/dev/null 2>&1; then
    gosu postgres "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u postgres "$@"
  else
    su - postgres -c "$(printf '%q ' "$@")"
  fi
}

psql_local() {
  # run a psql command as postgres on local PGDATA
  run_as_postgres psql -U postgres -d postgres -tAc "$*"
}

get_current_primary() {
  # returns node name (as recorded by repmgr) or empty string
  if ! command -v repmgr >/dev/null 2>&1; then
    echo ""
    return
  fi
  local out
  # Run repmgr as the postgres user to avoid 'cannot be run as root' errors in containers
  out=$(run_as_postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true)
  if [ -z "$out" ]; then
    echo ""
    return
  fi
  while IFS='|' read -r id name role status rest; do
    name=$(echo "$name" | xargs)
    role=$(echo "$role" | xargs)
    status=$(echo "$status" | xargs)
    if [[ "$role" = "primary" && ( "$status" == *running* || "$status" == *"running as primary"* ) ]]; then
      echo "$name"
      return
    fi
  done <<< "$out"
  echo ""
}

wait_for_pg() {
  local host=${1:-localhost} port=${2:-5432} timeout=${3:-30}
  for _ in $(seq 1 "$timeout"); do
    if run_as_postgres pg_isready -h "$host" -p "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

check_replication_lag_seconds() {
  local sql
  sql="SELECT CASE WHEN pg_is_in_recovery() THEN EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int ELSE NULL END;"
  run_as_postgres psql -U postgres -d postgres -tAc "$sql" 2>/dev/null || echo "NULL"
}

attempt_pg_rewind() {
  local source_host=$1 source_port=${2:-5432}
  log "Attempting pg_rewind from ${source_host}:${source_port}..."
  if ! command -v pg_rewind >/dev/null 2>&1; then
    warn "pg_rewind not available; cannot attempt fast rejoin"
    return 1
  fi
  # stop postgres if running
  if run_as_postgres pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
    log "Stopping postgres before pg_rewind"
    run_as_postgres pg_ctl -D "$PGDATA" -m fast stop || true
  fi
  local esc_pw
  esc_pw=${REPMGR_PASSWORD//\'/\'\'}
  if run_as_postgres pg_rewind --target-pgdata="$PGDATA" --source-server="host=$source_host port=$source_port user=$REPMGR_USER dbname=$REPMGR_DB password='${esc_pw}'"; then
    log "pg_rewind succeeded"
    # Ensure server is stopped after pg_rewind (it may start it for recovery)
    log "Ensuring postgres is stopped after pg_rewind"
    run_as_postgres pg_ctl -D "$PGDATA" -m fast stop || log "Failed to stop postgres after pg_rewind"
      # Do NOT start postgres here; caller should perform registration/rejoin while
      # the server is stopped to avoid 'in production' errors from repmgr.
    return 0
  fi
  warn "pg_rewind failed"
  return 1
}

full_clone_from_primary() {
  local host=$1 port=${2:-5432}
  log "Full clone from ${host}:${port} initiated"
  # ensure primary reachable
  wait_for_pg "$host" "$port" 30 || { err "Primary $host:$port not reachable"; return 1; }
  run_as_postgres pg_ctl -D "$PGDATA" -m fast stop || true
  rm -rf "$PGDATA"/* || true
  mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"
  if run_as_postgres repmgr -h "$host" -p "$port" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" standby clone --force -D "$PGDATA"; then
    run_as_postgres pg_ctl -D "$PGDATA" -w start || true
    run_as_postgres repmgr -f "$REPMGR_CONF" standby register --force || true
    log "Full clone + register completed"
    return 0
  fi
  warn "Standby clone failed"
  return 1
}

repmgr_cleanup_node() {
  local node_id=$1 primary_host=${2:-}
  if [ -z "$primary_host" ]; then
    primary_host=$(get_current_primary)
  fi
  if [ -z "$primary_host" ]; then
    warn "No primary available to run metadata cleanup"
    return 1
  fi
  log "Attempting repmgr metadata cleanup for node_id=$node_id via primary=$primary_host"
  if run_as_postgres repmgr -h "$primary_host" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" cluster cleanup --node-id="$node_id"; then
    log "Metadata cleanup succeeded for node_id=$node_id"
    return 0
  fi
  warn "Metadata cleanup failed for node_id=$node_id"
  return 1
}

### Cluster state JSON helpers
write_cluster_state_to_var() {
  # Build cluster state JSON from repmgr output and return in variable
  local out
  out=$(repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true)
  if [ -z "$out" ]; then
    warn "repmgr cluster show returned empty; not writing cluster state"
    return 1
  fi

  local primary="" nodes_json=""
  while IFS='|' read -r id name role status rest; do
    id=$(echo "$id" | xargs)
    name=$(echo "$name" | xargs)
    role=$(echo "$role" | xargs)
    status=$(echo "$status" | xargs)
    if [ "$role" = "Role" ]; then continue; fi
    # JSON-escape name/status minimally
    esc_name=$(printf '%s' "$name" | sed 's/"/\\"/g')
    esc_status=$(printf '%s' "$status" | sed 's/"/\\"/g')
    nodes_json+="{\"id\":$id,\"name\":\"$esc_name\",\"role\":\"$role\",\"status\":\"$esc_status\"},"
    if [ "$role" = "primary" ]; then primary="$name"; fi
  done <<< "$out"

  # strip trailing comma
  nodes_json="${nodes_json%,}"
  local ts
  ts=$(date +%s)
  printf -v "$1" '{"primary":"%s","nodes":[%s],"updated":%s}\n' "$primary" "$nodes_json" "$ts"
  return 0
}

write_cluster_state() {
  local state
  if write_cluster_state_to_var state; then
    local tmp
    tmp="${CLUSTER_STATE_FILE}.tmp"
    printf '%s' "$state" >"$tmp"
    chmod 600 "$tmp" || true
    chown postgres:postgres "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$CLUSTER_STATE_FILE"
    sync
    chmod 600 "$CLUSTER_STATE_FILE" 2>/dev/null || true
    chown postgres:postgres "$CLUSTER_STATE_FILE" 2>/dev/null || true
    return 0
  fi
  return 1
}

read_cluster_state() {
  if [ -f "$CLUSTER_STATE_FILE" ]; then
    cat "$CLUSTER_STATE_FILE"
    return 0
  fi
  return 1
}

get_primary_from_state() {
  if [ ! -f "$CLUSTER_STATE_FILE" ]; then
    echo ""
    return 1
  fi
  # crude parse for "primary":"name"
  grep -o '"primary" *: *"[^"]*"' "$CLUSTER_STATE_FILE" 2>/dev/null | sed 's/.*:\s*"\([^"]*\)"/\1/' || echo ""
}

get_node_id_by_name() {
  local name=$1
  if [ ! -f "$CLUSTER_STATE_FILE" ]; then
    echo ""
    return 1
  fi
  # find the id value for the node name
  awk -v n="\"name\":\"$name\"" 'index($0,n){
    match($0, /\"id\":([0-9]+)/, a); if(a[1]) print a[1]; exit
  }' "$CLUSTER_STATE_FILE" || echo ""
}

cluster_state_exists() {
  [ -f "$CLUSTER_STATE_FILE" ] && return 0 || return 1
}


notify_pgpool_fast_refresh() {
  # Try to nudge pgpool (pcp tools) to refresh quickly if available
  if command -v pcp_node_info >/dev/null 2>&1; then
    if [ -f /var/lib/postgresql/.pcppass ]; then
      log "Triggering PCP node refresh (if pgpool PCP tools present)"
      # try a best-effort refresh for node 0..3
      for i in 0 1 2 3; do
        pcp_node_info -h localhost -p 9898 -U admin -w "$i" >/dev/null 2>&1 || true
      done
    else
      warn "pcp tools present but /var/lib/postgresql/.pcppass missing - cannot authenticate"
    fi
  else
    log "pcp tools not available; skipping pgpool nudging"
  fi
}

### End of utils
