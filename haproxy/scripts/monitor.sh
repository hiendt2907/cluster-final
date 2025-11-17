#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

: "${REPMGR_CONF:=/etc/repmgr/repmgr.conf}"
: "${NODE_NAME:=$(hostname)}"
: "${PGDATA:=/var/lib/postgresql/data}"
: "${LAST_PRIMARY_FILE:="$PGDATA/last_known_primary"}"
: "${EVENT_INTERVAL:=15}"
: "${HEALTH_INTERVAL:=60}"
: "${REFRESH_INTERVAL:=5}"
: "${PRIMARY_HINT:=pg-1}"

REPMGR_USER=${REPMGR_USER:-repmgr}
REPMGR_DB=${REPMGR_DB:-repmgr}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-}

CLUSTER_LOCK=${CLUSTER_LOCK:-/var/lib/postgresql/cluster.lock}
CLEANUP_STATE_DIR=${CLEANUP_STATE_DIR:-/var/lib/postgresql/cleanup-state}
CLEANUP_THRESHOLD=${CLEANUP_THRESHOLD:-3}

log() { printf '[%s] [monitor] %s\n' "$(date -Iseconds)" "$*"; }

write_last_primary() {
local primary="$1" tmp="${LAST_PRIMARY_FILE}.tmp"
printf '%s\n' "$primary" >"$tmp"
chmod 600 "$tmp" 2>/dev/null || true
chown postgres:postgres "$tmp" 2>/dev/null || true
mv -f "$tmp" "$LAST_PRIMARY_FILE"
sync
chmod 600 "$LAST_PRIMARY_FILE" 2>/dev/null || true
chown postgres:postgres "$LAST_PRIMARY_FILE" 2>/dev/null || true
}

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
if [ "$role" = "primary" ] && [[ "$status" == *running* ]]; then
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
		log "Tăng bộ đếm cleanup cho $node_name (ID:$node_id) lên $attempt"
		return
	fi

	if ! acquire_lock; then
		log "Không lấy được lock để cleanup metadata của $node_name"
		return
	fi

	# Determine a primary to connect to for cleanup. Prefer current cluster primary,
	# then last-known-primary, then PRIMARY_HINT. If none available, abort.
	local primary
	primary=$(get_current_primary)
	if [ -z "$primary" ] && [ -f "$LAST_PRIMARY_FILE" ]; then
		primary=$(tail -n1 "$LAST_PRIMARY_FILE" 2>/dev/null || true)
	fi
	if [ -z "$primary" ]; then
		primary=${PRIMARY_HINT%:*}
	fi
	if [ -z "$primary" ]; then
		log "Không xác định được primary để chạy cleanup cho $node_name (ID:$node_id)"
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
		log "Không đọc được cluster show từ primary=$primary (thử lại $tries/$max_tries)"
		sleep $sleep_for
		sleep_for=$((sleep_for * 2))
	done
	if [ -z "$latest" ]; then
		log "Không đọc được cluster show từ primary=$primary sau $max_tries lần. Bỏ qua cleanup." 
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
					log "Cleanup metadata thành công cho $node_name (ID:$node_id) via primary=$primary"
					reset_cleanup_counter "$node_id"
					release_lock
					return
				fi
				ctries=$((ctries + 1))
				log "Cleanup metadata cho $node_name (ID:$node_id) thất bại (attempt $ctries/$cmax). Thử lại sau $cback s"
				sleep $cback
				cback=$((cback * 2))
			done
			log "Cleanup metadata thất bại cho $node_name (ID:$node_id) sau $cmax lần. Cần can thiệp thủ công"
			release_lock
			return
		fi
	done <<<"$latest"
	log "$node_name không còn ở trạng thái unreachable theo view của primary=$primary, bỏ qua cleanup"
	release_lock
	reset_cleanup_counter "$node_id"
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
log "Thực hiện pg_rewind từ $host:$port"
safe_stop_postgres
escaped=${REPMGR_PASSWORD//\'/\'\'}
conn="host=$host port=$port user=$REPMGR_USER dbname=$REPMGR_DB"
if [ -n "$REPMGR_PASSWORD" ]; then
conn+=" password='${escaped}'"
fi
if gosu postgres pg_rewind --target-pgdata="$PGDATA" --source-server="$conn"; then
log "pg_rewind hoàn tất"
gosu postgres pg_ctl -D "$PGDATA" -w start || true
write_last_primary "$host"
return 0
fi
log "pg_rewind thất bại"
return 1
}

do_full_clone() {
local host="$1" port="${2:-5432}"
if [ -z "$host" ]; then
return 1
fi
log "Clone lại dữ liệu từ $host:$port"
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
write_last_primary "$host"
log "Clone + register hoàn tất"
return 0
fi
log "Clone standby thất bại"
return 1
}

resolve_rejoin_target() {
local candidate
candidate=$(get_current_primary)
if [ -n "$candidate" ] && [ "$candidate" != "$NODE_NAME" ]; then
printf '%s' "$candidate"
return
fi
if [ -f "$LAST_PRIMARY_FILE" ]; then
candidate=$(tail -n1 "$LAST_PRIMARY_FILE" 2>/dev/null || printf '')
if [ -n "$candidate" ] && [ "$candidate" != "$NODE_NAME" ]; then
printf '%s' "$candidate"
return
fi
fi
candidate=${PRIMARY_HINT%:*}
if [ -n "$candidate" ] && [ "$candidate" != "$NODE_NAME" ]; then
printf '%s' "$candidate"
return
fi
printf ''
}

ensure_role_alignment() {
local local_role in_recovery target_host
local_role=$(gosu postgres repmgr -f "$REPMGR_CONF" node status 2>/dev/null | awk -F':' '/Role/{gsub(/[[:space:]]/,"",$2); print tolower($2)}')
in_recovery=$(gosu postgres psql -Atqc 'select pg_is_in_recovery();' 2>/dev/null || printf '')
if [ "$local_role" = "standby" ] && [ "$in_recovery" = "f" ]; then
target_host=$(resolve_rejoin_target)
if [ -z "$target_host" ]; then
log "Node này đang writable nhưng không tìm được primary để bám"
return
fi
if acquire_lock; then
log "Node standby chạy writable → thử rejoin vào primary $target_host"
if gosu postgres pg_isready -h "$target_host" -p 5432 -q; then
if try_pg_rewind "$target_host" 5432; then
if ! gosu postgres repmgr -f "$REPMGR_CONF" node rejoin --force --force-rewind -h "$target_host" -p 5432 -U "$REPMGR_USER" -d "$REPMGR_DB"; then
log "repmgr node rejoin trả về lỗi, sẽ thử lại ở vòng sau"
fi
else
if ! do_full_clone "$target_host" 5432; then
log "Full clone thất bại, cần can thiệp thủ công"
fi
fi
else
log "Không kết nối được tới primary $target_host, bỏ qua rejoin"
fi
wait_for_postgres 30 || log "PostgreSQL không sẵn sàng sau khi tự phục hồi"
release_lock
else
log "Không lấy được cluster lock cho quá trình tự phục hồi"
fi
fi
}

handle_unreachable_nodes() {
local output id name role status
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
existing=$(tail -n1 "$LAST_PRIMARY_FILE" 2>/dev/null || printf '')
if [ "$existing" != "$primary" ]; then
write_last_primary "$primary"
log "Ghi nhận primary hiện tại là $primary"
fi
fi
}

emit_event_snapshot() {
local events
events=$(gosu postgres repmgr -f "$REPMGR_CONF" cluster event --limit=10 2>/dev/null || printf '')
if printf '%s' "$events" | grep -Eiq 'promote|failover'; then
log "Phát hiện sự kiện promote/failover gần đây"
printf '%s\n' "$events"
fi
}

emit_health_snapshot() {
local health
health=$(check_cluster_health)
if [ "$health" != "GREEN" ]; then
log "Tình trạng cluster: $health"
gosu postgres repmgr -f "$REPMGR_CONF" cluster show --compact 2>/dev/null || true
fi
}

### Per-service monitor functions
monitor_postgresql() {
	log "Chờ PostgreSQL khởi động"
	until gosu postgres pg_isready -h "$NODE_NAME" -p 5432 >/dev/null 2>&1; do
		sleep 2
	done
	log "PostgreSQL đã sẵn sàng, bắt đầu monitor"

	last_event=0
	last_health=0
	last_refresh=0

	while true; do
		if ! wait_for_postgres 1; then
			log "PostgreSQL không phản hồi, tạm chờ"
			sleep 5
			continue
		fi

		ensure_role_alignment
		handle_unreachable_nodes

		now=$(date +%s)

		if (( now - last_refresh >= REFRESH_INTERVAL )); then
			last_refresh=$now
			update_primary_hint
		fi

		if (( now - last_event >= EVENT_INTERVAL )); then
			last_event=$now
			emit_event_snapshot
		fi

		if (( now - last_health >= HEALTH_INTERVAL )); then
			last_health=$now
			emit_health_snapshot
		fi

		sleep 1
	done
}

monitor_pgpool() {
	: "${PGPOOL_PORT:=5432}"
	: "${PGPOOL_CHECK_INTERVAL:=5}"
	: "${PGPOOL_PROC_PATTERN:=pgpool}"
	log "Bắt đầu monitor PgPool (port=$PGPOOL_PORT)"
	while true; do
		# check process
		if pgrep -f "$PGPOOL_PROC_PATTERN" >/dev/null 2>&1; then
			proc_ok=1
		else
			proc_ok=0
		fi

		# check TCP listen/connect
		tcp_ok=0
		if bash -c "</dev/tcp/127.0.0.1/$PGPOOL_PORT" >/dev/null 2>&1; then
			tcp_ok=1
		fi

		if [ "$proc_ok" -eq 1 ] && [ "$tcp_ok" -eq 1 ]; then
			log "PgPool: process up and listening on $PGPOOL_PORT"
		elif [ "$proc_ok" -eq 1 ] && [ "$tcp_ok" -eq 0 ]; then
			log "PgPool: process running but port $PGPOOL_PORT not accepting connections"
		else
			log "PgPool: process not running"
		fi

		sleep "$PGPOOL_CHECK_INTERVAL"
	done
}

monitor_haproxy() {
	: "${HAPROXY_CFG:=/usr/local/etc/haproxy/haproxy.cfg}"
	: "${HAPROXY_CHECK_INTERVAL:=5}"
	: "${HAPROXY_PROC_PATTERN:=haproxy}"
	log "Bắt đầu monitor HAProxy (cfg=$HAPROXY_CFG)"

	while true; do
		if pgrep -f "$HAPROXY_PROC_PATTERN" >/dev/null 2>&1; then
			proc_ok=1
		else
			proc_ok=0
		fi

		# parse backend server addresses from haproxy cfg
		reachable=0
		total=0
		if [ -f "$HAPROXY_CFG" ]; then
			# lines like: server name addr:port check
			while read -r line; do
				addr_port=$(printf '%s' "$line" | awk '{print $3}')
				if [ -z "$addr_port" ]; then
					continue
				fi
				total=$((total + 1))
				host=$(printf '%s' "$addr_port" | cut -d: -f1)
				port=$(printf '%s' "$addr_port" | cut -d: -f2)
				if [ -z "$port" ]; then
					port=5432
				fi
				if bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
					reachable=$((reachable + 1))
				fi
			done < <(grep -E '^[[:space:]]*server[[:space:]]+' "$HAPROXY_CFG" || true)
		fi

		if [ "$proc_ok" -eq 1 ]; then
			log "HAProxy process running"
		else
			log "HAProxy process not running"
		fi
		if [ $total -gt 0 ]; then
			log "HAProxy backend reachability: $reachable/$total"
		else
			log "HAProxy: no backend servers parsed from $HAPROXY_CFG"
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
