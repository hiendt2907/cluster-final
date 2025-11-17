#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

: "${REPMGR_CONF:=/etc/repmgr/repmgr.conf}"
: "${NODE_NAME:=$(hostname)}"
: "${PGDATA:=/var/lib/postgresql/data}"
: "${EVENT_INTERVAL:=15}"
: "${HEALTH_INTERVAL:=15}"
: "${REFRESH_INTERVAL:=5}"
: "${FOLLOW_MAX_RETRIES:=5}"
: "${FOLLOW_BACKOFF_BASE:=2}"
: "${FOLLOW_COOLDOWN:=600}"

: "${CLUSTER_READY_WAIT:=30}"

# Internal state
LAST_EVENT_HASH=""
LAST_FOLLOW_ATTEMPT=0
: "${PRIMARY_HINT:=pg-1}"

REPMGR_USER=${REPMGR_USER:-repmgr}
REPMGR_DB=${REPMGR_DB:-repmgr}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-}

CLUSTER_LOCK=${CLUSTER_LOCK:-/var/lib/postgresql/cluster.lock}
CLEANUP_THRESHOLD=${CLEANUP_THRESHOLD:-3}
CLEANUP_STATE_DIR=${CLEANUP_STATE_DIR:-/var/lib/postgresql/cleanup}

# State tracking for change detection
LAST_HEALTH_STATE=""
LAST_EVENT_HASH=""
LAST_TOPOLOGY=""
# Local runtime flag: ensure we only log the initial primary once after start
INITIAL_PRIMARY_LOGGED=0
INITIAL_CLUSTER_STATE_WRITTEN=0

# Cleanup timing control
LAST_CLEANUP_ATTEMPT=0
CLEANUP_INTERVAL=${CLEANUP_INTERVAL:-1800}  # 30 minutes default

log() { printf '[%s] [monitor] %s\n' "$(date -Iseconds)" "$*"; }
log_info() { printf '[%s] [monitor] INFO: %s\n' "$(date -Iseconds)" "$*"; }
log_warn() { printf '[%s] [monitor] WARNING: %s\n' "$(date -Iseconds)" "$*"; }
log_error() { printf '[%s] [monitor] ERROR: %s\n' "$(date -Iseconds)" "$*"; }
log_critical() { printf '[%s] [monitor] CRITICAL: %s\n' "$(date -Iseconds)" "$*"; }
log_event() { printf '[%s] [monitor] EVENT: %s\n' "$(date -Iseconds)" "$*"; }

# Source common utilities
if [ -f "./scenarios/utils.sh" ]; then
  . ./scenarios/utils.sh || true
fi

get_current_primary() {
local output name role status
output=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true)
if [ -z "$output" ]; then
printf ''
return
fi
while IFS='|' read -r _ name role status _; do
name=$(echo "$name" | xargs)
role=$(echo "$role" | xargs)
status=$(echo "$status" | xargs)
if [ "$role" = "Role" ]; then
continue
fi
# Match either registered primary with running status, or node running as primary (new promoted primary)
if [[ "$role" = "primary" && "$status" == *running* ]] || [[ "$status" == *"running as primary"* ]]; then
printf '%s' "$name"
return
fi
done <<<"$output"
printf ''
}

check_cluster_health() {
local output id name role status total=0 online=0
output=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true)
if [ -z "$output" ]; then
printf 'UNKNOWN'
return
fi
while IFS='|' read -r id name role status _; do
id=$(echo "$id" | xargs)
role=$(echo "$role" | xargs)
status=$(echo "$status" | xargs)
if [ "$role" = "Role" ]; then
continue
fi
if ! [[ "$id" =~ ^[0-9]+$ ]]; then
continue
fi
if [ "$role" = "witness" ]; then
continue
fi
total=$((total + 1))
if [[ "$status" == *running* ]]; then
online=$((online + 1))
fi
done <<<"$output"
if [ "$total" -eq 0 ]; then
printf 'UNKNOWN'
return
fi
if [ "$total" -eq "$online" ]; then
printf 'GREEN'
elif [ "$online" -ge $((total / 2 + 1)) ]; then
printf 'YELLOW'
elif [ "$online" -eq 1 ]; then
printf 'DISASTER'
else
printf 'RED'
fi
}

ensure_lock_dir() {
mkdir -p "$(dirname "$CLUSTER_LOCK")"
}

acquire_lock() {
ensure_lock_dir
exec 9>"$CLUSTER_LOCK" || return 1
if flock -n 9; then
return 0
fi
sleep $((RANDOM % 5 + 1))
flock 9 || return 1
}

release_lock() {
exec 9>&- || true
}

ensure_cleanup_dir() {
mkdir -p "$CLEANUP_STATE_DIR"
}

cleanup_state_file() {
ensure_cleanup_dir
printf '%s/%s' "$CLEANUP_STATE_DIR" "$1"
}

reset_cleanup_counter() {
local file
file=$(cleanup_state_file "$1")
rm -f "$file" 2>/dev/null || true
}

increment_cleanup_counter() {
local node_id="$1" file count=0
file=$(cleanup_state_file "$node_id")
if [ -f "$file" ]; then
count=$(cat "$file" 2>/dev/null || printf '0')
fi
count=$((count + 1))
printf '%s\n' "$count" >"$file"
printf '%s' "$count"
}

attempt_metadata_cleanup() {
local node_id="$1" node_name="$2" attempt latest lid lname lrole lstatus
	attempt=$(increment_cleanup_counter "$node_id")
	if [ "$attempt" -lt "$CLEANUP_THRESHOLD" ]; then
		# Silent increment - only log when threshold reached
		return
	fi

	if ! acquire_lock; then
		log_warn "Cannot acquire lock for cleanup of $node_name (ID:$node_id)"
		return
	fi

	# Determine a primary to connect to for cleanup. Prefer current cluster primary,
	# then PRIMARY_HINT. If none available, abort.
	local primary
	primary=$(get_current_primary)
	if [ -z "$primary" ]; then
		primary=${PRIMARY_HINT%:*}
	fi
	if [ -z "$primary" ]; then
		log_error "Cannot determine primary for cleanup of $node_name (ID:$node_id)"
		release_lock
		return
	fi

	# Fetch latest cluster view from the primary (explicit connect) with retries
	local tries=0 max_tries=3 sleep_for=2
	while [ $tries -lt $max_tries ]; do
		latest=$(gosu postgres repmgr -h "$primary" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true)
		if [ -n "$latest" ]; then
			break
		fi
		tries=$((tries + 1))
		sleep $sleep_for
		sleep_for=$((sleep_for * 2))
	done
	if [ -z "$latest" ]; then
		log_error "Cannot read cluster state from primary=$primary after $max_tries attempts"
		release_lock
		return
	fi

	# If node is still unreachable/failed as seen from primary, request cleanup
	while IFS='|' read -r lid lname lrole lstatus _; do
		lid=$(echo "$lid" | xargs)
		lname=$(echo "$lname" | xargs)
		lrole=$(echo "$lrole" | xargs)
		lstatus=$(echo "$lstatus" | xargs)
		if [ "$lrole" = "Role" ]; then
			continue
		fi
		if [ "$lid" = "$node_id" ] && [[ "$lstatus" == *unreachable* || "$lstatus" == *failed* ]]; then
			# Run cleanup connecting explicitly to primary; retry a few times on transient failures
			local ctries=0 cmax=3 cback=2
			while [ $ctries -lt $cmax ]; do
				if gosu postgres repmgr -h "$primary" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" cluster cleanup --node-id="$node_id"; then
					log_event "Metadata cleanup successful for $node_name (ID:$node_id) via primary=$primary"
					reset_cleanup_counter "$node_id"
					release_lock
					return
				fi
				ctries=$((ctries + 1))
				sleep $cback
				cback=$((cback * 2))
			done
			log_error "Metadata cleanup failed for $node_name (ID:$node_id) after $cmax attempts - manual intervention required"
			release_lock
			return
		fi
	done <<<"$latest"
	# Node recovered - reset counter silently
	release_lock
	reset_cleanup_counter "$node_id"
}

follow_block_file() {
	ensure_cleanup_dir
	printf '%s/follow_block_%s' "$CLEANUP_STATE_DIR" "$NODE_NAME"
}

is_follow_blocked() {
	local f
	f=$(follow_block_file)
	if [ ! -f "$f" ]; then
		return 1
	fi
	local ts
	ts=$(cat "$f" 2>/dev/null || printf '0')
	if [ -z "$ts" ]; then
		return 1
	fi
	local now
	now=$(date +%s)
	if [ $((now - ts)) -lt $FOLLOW_COOLDOWN ]; then
		return 0
	fi
	return 1
}

set_follow_block() {
	local reason="$1" f
	f=$(follow_block_file)
	printf '%s\n' "$(date +%s)" >"$f"
	log_warn "Follow attempts blocked for $NODE_NAME due to: $reason (cooldown=${FOLLOW_COOLDOWN}s)"
}

wait_for_postgres() {
local attempts=${1:-30}
for _ in $(seq 1 "$attempts"); do
if gosu postgres pg_isready -h "$NODE_NAME" -p 5432 >/dev/null 2>&1; then
return 0
fi
sleep 1
done
return 1
}

safe_stop_postgres() {
if gosu postgres pg_isready -h "$NODE_NAME" -p 5432 >/dev/null 2>&1; then
gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop || gosu postgres pg_ctl -D "$PGDATA" -m immediate -w stop || true
fi
}

try_pg_rewind() {
local host="$1" port="${2:-5432}" escaped conn
if [ -z "$host" ]; then
return 1
fi
log_event "Attempting pg_rewind from $host:$port"
safe_stop_postgres
escaped=${REPMGR_PASSWORD//\'/\'\'}
conn="host=$host port=$port user=$REPMGR_USER dbname=$REPMGR_DB"
if [ -n "$REPMGR_PASSWORD" ]; then
conn+=" password='${escaped}'"
fi
if gosu postgres pg_rewind --target-pgdata="$PGDATA" --source-server="$conn"; then
log_event "pg_rewind completed successfully"
gosu postgres pg_ctl -D "$PGDATA" -w start || true
return 0
fi
log_error "pg_rewind failed"
return 1
}

do_full_clone() {
local host="$1" port="${2:-5432}"
if [ -z "$host" ]; then
return 1
fi
log_event "Full clone from $host:$port initiated"
safe_stop_postgres
rm -rf "$PGDATA"/* || true
mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
until gosu postgres pg_isready -h "$host" -p "$port" -q; do
sleep 1
done
if gosu postgres repmgr -h "$host" -p "$port" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF" standby clone --force -D "$PGDATA"; then
gosu postgres pg_ctl -D "$PGDATA" -w start || true
gosu postgres repmgr -f "$REPMGR_CONF" standby register --force || true
log_event "Full clone + register completed"
return 0
fi
log_error "Standby clone failed"
return 1
}

resolve_rejoin_target() {
local candidate
candidate=$(get_current_primary)
if [ -n "$candidate" ] && [ "$candidate" != "$NODE_NAME" ]; then
printf '%s' "$candidate"
return
fi
candidate=${PRIMARY_HINT%:*}
if [ -n "$candidate" ] && [ "$candidate" != "$NODE_NAME" ]; then
printf '%s' "$candidate"
return
fi
printf ''
}

get_streaming_upstream_host() {
	gosu postgres psql -Atqc "SELECT substring(conninfo from 'host=([^ ]+)') FROM pg_stat_wal_receiver LIMIT 1;" 2>/dev/null || printf ''
}

ensure_role_alignment() {
	local local_role in_recovery current_primary current_upstream_host timeline_conflict
	
	local_role=$(gosu postgres repmgr -f "$REPMGR_CONF" node status 2>/dev/null | awk -F':' '/Role/{gsub(/[[:space:]]/,"",$2); print tolower($2)}')
	in_recovery=$(gosu postgres psql -Atqc 'select pg_is_in_recovery();' 2>/dev/null || printf '')

	# If this node is already primary, update last-known-primary and skip follow attempts
	if [ "${local_role:-}" = "primary" ] || { [ "${in_recovery:-}" = "f" ] && [ "${local_role:-}" != "standby" ]; }; then
		# This condition is tricky. A standby could temporarily be "writable" during a messy promotion.
		# However, if we are definitively the primary, we should lead.
		if [ "$(get_current_primary)" = "$NODE_NAME" ]; then
			# Local node is confirmed as primary - no need to log this every second
			true
		else
			log_warn "Local node appears writable but is not the registered primary. Deferring action for repmgrd to resolve."
		fi
		return
	fi

	# From here, we are a standby. Our job is to follow the correct primary.
	current_primary=$(get_current_primary)
	if [ -z "$current_primary" ] || [ "$current_primary" = "$NODE_NAME" ]; then
		log_info "No active primary found or I am the primary. Nothing to follow."
		return
	fi

	current_upstream_host=$(get_streaming_upstream_host)

	# If we are already following the correct primary, all is well.
	if [ "$current_upstream_host" = "$current_primary" ]; then
		# log_info "Correctly following primary: $current_primary" # This is too noisy for normal operation
		return
	fi

	log_warn "Misaligned upstream detected. Cluster Primary: '$current_primary', This Node is Following: '${current_upstream_host:-Not Streaming}'."

	# Check for timeline conflict first
	timeline_conflict=$(gosu postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN (SELECT timeline_id FROM pg_control_checkpoint()) ELSE NULL END;" 2>/dev/null || printf '')
	if [ -n "$timeline_conflict" ]; then
		local primary_timeline
		primary_timeline=$(gosu postgres psql -h "$current_primary" -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc "SELECT timeline_id FROM pg_control_checkpoint();" 2>/dev/null || printf '')
		if [ -n "$primary_timeline" ] && [ "$timeline_conflict" != "$primary_timeline" ]; then
			log_warn "Timeline conflict detected: local=$timeline_conflict, primary=$primary_timeline"
			
			# Try pg_rewind first
			if try_pg_rewind "$current_primary"; then
				log_event "Timeline conflict resolved via pg_rewind"
				return
			else
				log_warn "pg_rewind failed, attempting full clone"
				if do_full_clone "$current_primary"; then
					log_event "Timeline conflict resolved via full clone"
					return
				else
					log_error "Failed to resolve timeline conflict - manual intervention required"
					return
				fi
			fi
		fi
	fi

	# PERFECT RECOVERY: Complete recovery with proper repmgr registration
	log_event "Perfect recovery: updating config, restarting, and registering with new primary..."

	# Step 1: Stop PostgreSQL
	log_event "Stopping PostgreSQL..."
	if ! gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop; then
		log_error "Failed to stop PostgreSQL"
		return
	fi

	# Step 2: Update configuration to point to new primary
	log_event "Updating primary_conninfo to '$current_primary'..."
	sed -i '/^primary_conninfo/d' "$PGDATA/postgresql.auto.conf"
	echo "primary_conninfo = 'user=$REPMGR_USER password=$REPMGR_PASSWORD connect_timeout=5 host=$current_primary port=5432 application_name=$NODE_NAME'" >> "$PGDATA/postgresql.auto.conf"

	# Step 3: Start PostgreSQL
	log_event "Starting PostgreSQL..."
	if ! gosu postgres pg_ctl -D "$PGDATA" -w start; then
		log_error "Failed to start PostgreSQL"
		return
	fi

	# Step 4: Register as standby with new primary
	log_event "Registering as standby with new primary '$current_primary'..."
	if gosu postgres repmgr -f "$REPMGR_CONF" standby register --force >/tmp/register.log 2>&1; then
		log_info "Successfully registered as standby with '$current_primary'"
	else
		log_error "Failed to register as standby. Check /tmp/register.log for details."
	fi
}

check_auto_promotion() {
	local current_primary local_role
	current_primary=$(get_current_primary)
	local_role=$(gosu postgres repmgr -f "$REPMGR_CONF" node status 2>/dev/null | awk -F':' '/Role/{gsub(/[[:space:]]/,"",$2); print tolower($2)}')

	# Only promote if no primary and we are standby
	if [ -n "$current_primary" ] || [ "$local_role" != "standby" ]; then
		return
	fi

	log_event "No current primary and we are standby - triggering auto promotion"

	# Call promote_command directly - it handles the actual promotion
	if /usr/local/bin/promote_guard.sh; then
		log_event "Auto promotion successful"
	else
		log_error "Promotion guard failed"
	fi
}

handle_unreachable_nodes() {
local output id name role status now
now=$(date +%s)

# Only attempt cleanup every CLEANUP_INTERVAL seconds (default 30 minutes)
if [ $((now - LAST_CLEANUP_ATTEMPT)) -lt $CLEANUP_INTERVAL ]; then
return
fi
LAST_CLEANUP_ATTEMPT=$now

output=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true)
if [ -z "$output" ]; then
return
fi
while IFS='|' read -r id name role status _; do
id=$(echo "$id" | xargs)
name=$(echo "$name" | xargs)
role=$(echo "$role" | xargs)
status=$(echo "$status" | xargs)
if [ "$role" = "Role" ]; then
continue
fi
if ! [[ "$id" =~ ^[0-9]+$ ]]; then
continue
fi
if [[ "$status" == *running* ]]; then
reset_cleanup_counter "$id"
continue
fi
if [[ "$status" == *unreachable* || "$status" == *failed* ]]; then
if [ "$name" = "$NODE_NAME" ] || [ "$role" = "witness" ]; then
continue
fi
attempt_metadata_cleanup "$id" "$name"
fi
done <<<"$output"
}

update_primary_hint() {
local primary existing
primary=$(get_current_primary)
if [ -n "$primary" ]; then
	existing=$(get_primary_from_state 2>/dev/null || printf '')
	# If there is no recorded previous primary, log it once on startup then persist.
	if [ -z "$existing" ]; then
		if [ "$INITIAL_PRIMARY_LOGGED" -eq 0 ]; then
			log_info "Initial primary detected: $primary"
			INITIAL_PRIMARY_LOGGED=1
		fi
		if command -v write_cluster_state >/dev/null 2>&1; then
			write_cluster_state 2>/dev/null || true
		fi
		return
	fi

	if [ "$existing" != "$primary" ]; then
		log_event "Primary changed: $existing → $primary"
		if command -v write_cluster_state >/dev/null 2>&1; then
			write_cluster_state 2>/dev/null || true
		fi
	fi
fi
}

emit_event_snapshot() {
local events event_hash
events=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster event --limit=10 2>/dev/null || printf '')
event_hash=$(printf '%s' "$events" | md5sum | awk '{print $1}')
if [ "$event_hash" != "$LAST_EVENT_HASH" ]; then
if printf '%s' "$events" | grep -Eiq 'promote|demote'; then
log_event "PROMOTE/DEMOTE detected - cluster topology:"
echo "$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || echo 'Unable to fetch cluster status')"
fi
LAST_EVENT_HASH="$event_hash"
fi
}

emit_health_snapshot() {
local health
health=$(check_cluster_health)
if [ "$health" != "$LAST_HEALTH_STATE" ]; then
case "$health" in
GREEN)
log_info "Cluster health: GREEN - all nodes running"
echo "$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || echo 'Unable to fetch cluster status')"
;;
YELLOW)
log_warn "Cluster health: YELLOW - some nodes down"
echo "$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || echo 'Unable to fetch cluster status')"
;;
RED)
log_error "Cluster health: RED - quorum lost"
echo "$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || echo 'Unable to fetch cluster status')"
;;
DISASTER)
log_critical "Cluster health: DISASTER - only 1 node!"
echo "$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || echo 'Unable to fetch cluster status')"
;;
esac
LAST_HEALTH_STATE="$health"
fi
}

emit_witness_status() {
    local witness_output witness_status witness_name
    witness_output=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null | grep 'witness' || true)

    if [ -z "$witness_output" ]; then
        # No witness registered or visible. This is a valid configuration, so no warning is needed.
        return
    fi

    # Example output: 99 | witness-1 | witness | * running |
    witness_name=$(echo "$witness_output" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')
    witness_status=$(echo "$witness_output" | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')

    if [[ "$witness_status" != *"running"* ]]; then
        log_warn "Witness node '$witness_name' is not running. Current status: '$witness_status'. Automatic failover may be impaired."
    fi
    # If it's running, we don't log anything to keep the logs clean during normal operation.
}


### Per-service monitor functions
monitor_postgresql() {
	log_info "PostgreSQL monitor starting - waiting for database to be ready"
	until gosu postgres pg_isready -h "$NODE_NAME" -p 5432 >/dev/null 2>&1; do
		sleep 2
	done
	log_info "PostgreSQL ready - monitoring active"

	# Wait for cluster to be fully up (all peers running) then persist cluster state once.
	# We poll `check_cluster_health` up to CLUSTER_READY_WAIT attempts (2s apart) and
	# write `cluster_state.json` only when health == GREEN. If the helper is not
	# available or the cluster doesn't reach GREEN within the timeout, we proceed
	# into the main loop without the initial persisted state (monitor will still
	# attempt writes later).
	if [ "$INITIAL_CLUSTER_STATE_WRITTEN" -eq 0 ]; then
		if command -v write_cluster_state >/dev/null 2>&1; then
			checks=0
			max_checks=${CLUSTER_READY_WAIT}
			while [ $checks -lt $max_checks ]; do
				health=$(check_cluster_health)
				if [ "$health" = "GREEN" ]; then
					if write_cluster_state >/dev/null 2>&1; then
						log_info "Initial cluster state written after cluster health=GREEN"
						INITIAL_CLUSTER_STATE_WRITTEN=1
					else
						log_warn "Initial cluster state write failed despite cluster health=GREEN"
					fi
					break
				fi
				checks=$((checks + 1))
				sleep 2
			done
			if [ "$INITIAL_CLUSTER_STATE_WRITTEN" -eq 0 ]; then
				log_warn "Cluster did not reach GREEN within ${CLUSTER_READY_WAIT} checks; skipping initial cluster state write"
			fi
		else
			log_info "write_cluster_state helper not available; skipping initial cluster state persist"
			INITIAL_CLUSTER_STATE_WRITTEN=1
		fi
	fi

	last_event=0
	last_health=0
	last_refresh=0

	while true; do
		if ! wait_for_postgres 1; then
			log_error "PostgreSQL not responding"
			sleep 5
			continue
		fi

		ensure_role_alignment
		check_auto_promotion
		handle_unreachable_nodes

		now=$(date +%s)

		if (( now - last_refresh >= REFRESH_INTERVAL )); then
			last_refresh=$now
			# Read previous primary before we overwrite it
			prev_primary=$(get_primary_from_state 2>/dev/null || printf '')
			current_primary="$(get_current_primary)"
			# If we have no recorded previous primary, treat this as initial detection and log once
			if [ -z "$prev_primary" ] && [ -n "$current_primary" ]; then
				if [ "$INITIAL_PRIMARY_LOGGED" -eq 0 ]; then
					log_info "Initial primary detected: $current_primary"
					INITIAL_PRIMARY_LOGGED=1
				fi
				if command -v write_cluster_state >/dev/null 2>&1; then
					write_cluster_state 2>/dev/null || log_warn "Initial cluster state write failed"
				fi
			elif [ "$prev_primary" != "$current_primary" ]; then
				log "[refresh] Primary changed: $prev_primary → $current_primary"
			fi
		fi

		if (( now - last_event >= EVENT_INTERVAL )); then
			last_event=$now
			emit_event_snapshot
		fi

		if (( now - last_health >= HEALTH_INTERVAL )); then
			last_health=$now
			emit_health_snapshot
emit_witness_status
fi

		sleep 1
	done
}

monitor_pgpool() {
	: "${PGPOOL_CHECK_INTERVAL:=30}"
	: "${PCP_PORT:=9898}"
	: "${PCP_USER:=admin}"
	
	log_info "PgPool monitor starting (pcp_port=$PCP_PORT)"
	
	# Wait for pgpool to start
	sleep 5
	
	local last_topology=""
	
	while true; do
		local current_topology=""
		
		# Try to get node info via pcp_node_info
		if command -v pcp_node_count >/dev/null 2>&1 && [ -f /var/lib/postgresql/.pcppass ]; then
			local node_count
			node_count=$(pcp_node_count -h localhost -p "$PCP_PORT" -U "${PCP_USER:-pcp_admin}" -w 2>/dev/null || echo "0")
			
			if [ "$node_count" -gt 0 ]; then
				for i in $(seq 0 $((node_count - 1))); do
					local info
					info=$(pcp_node_info -h localhost -p "$PCP_PORT" -U "${PCP_USER:-pcp_admin}" -w "$i" 2>/dev/null || echo "")
					if [ -n "$info" ]; then
						local host port status lb_weight role
						host=$(echo "$info" | awk '{print $1}')
						port=$(echo "$info" | awk '{print $2}')
						status=$(echo "$info" | awk '{print $3}')
						role=$(echo "$info" | awk '{print $5}')
						
						local status_str role_str
						case "$status" in
							1|2|3) status_str="UP" ;;
							*) status_str="DOWN" ;;
						esac
						
						case "$role" in
							0) role_str="primary" ;;
							1) role_str="standby" ;;
							*) role_str="unknown" ;;
						esac
						
						current_topology+="Node[$i] $host:$port status=$status_str role=$role_str; "
					fi
				done
			else
				current_topology="PgPool: waiting for backend nodes..."
			fi
		else
			current_topology="PgPool: PCP tools not available or .pcppass missing"
		fi
		
		# Log topology changes or errors
		if [ "$current_topology" != "$last_topology" ]; then
			if echo "$current_topology" | grep -q "DOWN"; then
				log_error "PgPool cluster state changed: $current_topology"
			elif echo "$current_topology" | grep -q "waiting\|missing"; then
				log_warn "$current_topology"
			else
				log_info "PgPool cluster state: $current_topology"
			fi
			last_topology="$current_topology"
		fi

		sleep "$PGPOOL_CHECK_INTERVAL"
	done
}

monitor_haproxy() {
	: "${HAPROXY_CHECK_INTERVAL:=30}"
	
	log_info "HAProxy monitor starting"
	
	# Wait for HAProxy to start
	sleep 5
	
	local last_backend_status=""

	while true; do
		local backend_status=""
		local pgpool_backends=""
		
		# Parse PGPOOL_BACKENDS env or HAPROXY_BACKENDS
		if [ -n "${PGPOOL_BACKENDS:-}" ]; then
			pgpool_backends="$PGPOOL_BACKENDS"
		elif [ -n "${HAPROXY_BACKENDS:-}" ]; then
			pgpool_backends="$HAPROXY_BACKENDS"
		fi
		
		if [ -n "$pgpool_backends" ]; then
			IFS=',' read -ra backends <<< "$pgpool_backends"
			local total=${#backends[@]}
			local up=0
			
			for backend in "${backends[@]}"; do
				local host port
				host=$(echo "$backend" | cut -d: -f1)
				port=$(echo "$backend" | cut -d: -f2)
				[ -z "$port" ] && port=5432
				
				if bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
					backend_status+="$host:$port=UP "
					up=$((up + 1))
				else
					backend_status+="$host:$port=DOWN "
				fi
			done
			
			backend_status+="(total:$up/$total)"
		else
			backend_status="HAProxy: no PGPOOL_BACKENDS or HAPROXY_BACKENDS defined"
		fi
		
		# Log backend status changes
		if [ "$backend_status" != "$last_backend_status" ]; then
			if echo "$backend_status" | grep -q "DOWN"; then
				log_error "HAProxy pgpool backend status: $backend_status"
			elif echo "$backend_status" | grep -q "no.*defined"; then
				log_warn "$backend_status"
			else
				log_info "HAProxy pgpool backend status: $backend_status"
			fi
			last_backend_status="$backend_status"
		fi

		sleep "$HAPROXY_CHECK_INTERVAL"
	done
}

# Dispatcher: run the appropriate monitor based on SERVICE_TYPE
: "${SERVICE_TYPE:=postgresql}"
case "$SERVICE_TYPE" in
	postgresql)
		monitor_postgresql
		;;
	pgpool)
		monitor_pgpool
		;;
	haproxy)
		monitor_haproxy
		;;
	*)
		log "Unknown SERVICE_TYPE='$SERVICE_TYPE' - defaulting to postgresql"
		monitor_postgresql
		;;
esac
