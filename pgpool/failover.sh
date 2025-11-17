#!/usr/bin/env bash
set -euo pipefail

# Failover helper for PgPool
# Purpose: DO NOT perform promotion from PgPool. Wait for repmgr to perform
# promotion and then reload PgPool configuration so PgPool follows repmgr's
# authoritative decision. This avoids split-brain where PgPool and repmgr
# both try to promote different nodes.

#!/usr/bin/env bash
set -euo pipefail

# Failover helper for PgPool
# Purpose: DO NOT perform promotion from PgPool. Wait for repmgr to perform
# promotion and then reload PgPool configuration so PgPool follows repmgr's
# authoritative decision. This avoids split-brain where PgPool and repmgr
# both try to promote different nodes.

LOG_FILE="/var/log/pgpool/failover.log"
mkdir -p /var/log/pgpool

log() { echo "[$(date -Iseconds)] [failover] $*" | tee -a "$LOG_FILE"; }

# Ensure PCP_USER has a default early so later lookups and .pcppass parsing
: ${PCP_USER:='pcp_admin'}

# Parameters passed by pgpool (documented, but we only log them)
FAILED_NODE_ID=${1:-}
FAILED_HOST_NAME=${2:-}
FAILED_PORT=${3:-}

log "Failover detected by PgPool - failed node: ${FAILED_NODE_ID} (${FAILED_HOST_NAME}:${FAILED_PORT})"

# Configuration: how long to wait for repmgr to elect/register a new primary
WAIT_TIMEOUT=${FAILOVER_WAIT_TIMEOUT:-60}   # seconds
POLL_INTERVAL=${FAILOVER_POLL_INTERVAL:-2}  # seconds

# Helper: read backend host:port pairs from pgpool.conf
get_backends() {
	local i=0
	local hosts=()
	while true; do
		local h
		h=$(grep -m1 "^backend_hostname${i} =" /etc/pgpool-II/pgpool.conf || true)
		if [ -z "$h" ]; then
			break
		fi
		local host
		host=$(echo "$h" | awk -F"'" '{print $2}')
		local port_line
		port_line=$(grep -m1 "^backend_port${i} =" /etc/pgpool-II/pgpool.conf || true)
		local port
		port=$(echo "$port_line" | awk '{print $3}' || true)
		if [ -z "$port" ]; then port=5432; fi
		hosts+=("${host}:${port}")
		i=$((i+1))
	done
	printf "%s\n" "${hosts[@]}"
}

# Query repmgr metadata on a given host:port to find the registered primary
query_primary_on() {
	local host=$1 port=${2:-5432}
	# Use repmgr DB to inspect repmgr.nodes - requires REPMGR_PASSWORD env to be set
	if [ -z "${REPMGR_PASSWORD:-}" ]; then
		return 1
	fi
	PGPASSWORD="$REPMGR_PASSWORD" psql -h "$host" -p "$port" -U repmgr -d repmgr -tAc \
		"SELECT node_name FROM repmgr.nodes WHERE type='primary' AND active='t' LIMIT 1;" 2>/dev/null | tr -d '[:space:]' || true
}

# If PCP credentials are not exported into environment when this hook runs,
# try to read them from /etc/pgpool-II/pcp.conf which is created by the
# pgpool entrypoint.
if [ -z "${PCP_USER:-}" ] || [ -z "${PCP_PASSWORD:-}" ]; then
	if [ -f /etc/pgpool-II/pcp.conf ]; then
		# pcp.conf format: username:password or username:md5<hash>
		pcpline=$(head -n1 /etc/pgpool-II/pcp.conf || true)
		PCP_USER_READ=${pcpline%%:*}
		PCP_PASSWORD_READ=${pcpline#*:}
		PCP_USER=${PCP_USER:-$PCP_USER_READ}
		# If pcp.conf contains an md5 hash (md5<hex>) we cannot recover the
		# plaintext password from it. In that case do not set PCP_PASSWORD from
		# pcp.conf; rely on a provided PCP_PASSWORD env var or a client-side
		# ~/.pcppass file instead.
		if [[ "${PCP_PASSWORD_READ:-}" =~ ^md5 ]]; then
			:
		else
			PCP_PASSWORD=${PCP_PASSWORD:-$PCP_PASSWORD_READ}
		fi
	fi
fi

# If we still don't have a plaintext PCP password, try to read a client-side
# .pcppass file (created by the entrypoint) which contains lines like
# host:port:user:password. We prefer the /root/.pcppass (failover runs as
# root inside the container) and fall back to /var/lib/postgresql/.pcppass.
if [ -z "${PCP_PASSWORD:-}" ]; then
	for f in /root/.pcppass /var/lib/postgresql/.pcppass; do
		if [ -r "$f" ]; then
			PCP_PASSWORD_FROM_FILE=$(awk -F: -v u="$PCP_USER" '$3==u{print $4; exit}' "$f" || true)
			if [ -n "$PCP_PASSWORD_FROM_FILE" ]; then
				PCP_PASSWORD=$PCP_PASSWORD_FROM_FILE
				break
			fi
		fi
	done
fi

# Wait for repmgr to report a primary, up to WAIT_TIMEOUT
end_time=$((SECONDS + WAIT_TIMEOUT))
new_primary=""
mapfile -t backends < <(get_backends)
if [ ${#backends[@]} -eq 0 ]; then
	log "No backends found in /etc/pgpool-II/pgpool.conf - aborting wait"
	exit 0
fi

log "Polling repmgr metadata on backends for up to ${WAIT_TIMEOUT}s"
while [ $SECONDS -le $end_time ]; do
	for be in "${backends[@]}"; do
		host=${be%%:*}
		port=${be##*:}
		primary_name=$(query_primary_on "$host" "$port" || true)
		if [ -n "$primary_name" ]; then
			new_primary="$primary_name"
			break 2
		fi
	done
	sleep $POLL_INTERVAL
done

if [ -z "$new_primary" ]; then
	log "Timed out waiting for repmgr to elect/register a primary (waited ${WAIT_TIMEOUT}s)."
	log "PgPool will not attempt promotion; operator intervention may be required."
	exit 0
fi

log "Detected repmgr-registered primary: $new_primary"

# Reload local PgPool configuration via PCP so runtime state reflects repmgr metadata.
# Try local PCP first, then attempt remote peers using /etc/pgpool-II/pcp.conf or PGPOOL_PEERS.
PCP_HOST=${PCP_HOST:-localhost}
PCP_PORT=${PCP_PORT:-9898}

reload_pcp() {
	local host=$1 port=$2
	log "Attempting pcp_reload_config on ${host}:${port}"
	# Prefer non-interactive .pcppass for PCP authentication. Use -w to avoid prompts.
	if pcp_reload_config -h "$host" -p "$port" -U "${PCP_USER:-pcp_admin}" -w >/dev/null 2>&1; then
		log "pcp_reload_config succeeded on ${host}:${port}"
		return 0
	fi

	# If the direct call failed, also attempt the no-prompt variant without -w (some environments)
	if pcp_reload_config -h "$host" -p "$port" -U "${PCP_USER:-pcp_admin}" >/dev/null 2>&1; then
		log "pcp_reload_config succeeded on ${host}:${port} (fallback)"
		return 0
	fi
	log "pcp_reload_config failed on ${host}:${port}"
	return 1
}

# Ensure PCP_USER has a default
: ${PCP_USER:='pcp_admin'}

# Reload local pgpool (try PCP first, then fallback to local SIGHUP if PCP fails)
if reload_pcp "$PCP_HOST" "$PCP_PORT" >/dev/null 2>&1; then
	log "Local pcp_reload_config succeeded on ${PCP_HOST}:${PCP_PORT}"
else
	log "Local pcp_reload_config failed on ${PCP_HOST}:${PCP_PORT} - attempting local SIGHUP fallback"
	# Try to reload by sending SIGHUP to the pgpool master process (safe local reload)
	PIDFILE=/var/run/pgpool/pgpool.pid
	# Try PID file first, then fallback to finding pgpool master PID via ps if PID file missing
	pgpool_pid=""
	if [ -f "$PIDFILE" ]; then
		pgpool_pid=$(cat "$PIDFILE" 2>/dev/null || true)
	fi
	if [ -z "$pgpool_pid" ]; then
		# Try to discover pgpool master pid (process started as 'pgpool -n -f ...')
		pgpool_pid=$(ps -eo pid,cmd | awk '/pgpool -n -f/ && !/awk/ {print $1; exit}' || true)
	fi
	if [ -n "$pgpool_pid" ] && ps -p "$pgpool_pid" > /dev/null 2>&1; then
		# prefer to send signal as postgres user
		if command -v gosu >/dev/null 2>&1; then
			if gosu postgres kill -HUP "$pgpool_pid" 2>/dev/null; then
				log "Sent SIGHUP to pgpool (pid=$pgpool_pid) via gosu postgres"
			else
				log "gosu postgres failed to send SIGHUP (trying direct kill as fallback)"
				if kill -HUP "$pgpool_pid" 2>/dev/null; then
					log "Sent SIGHUP to pgpool (pid=$pgpool_pid) directly as root"
				else
					log "Failed to send SIGHUP to pgpool (pid=$pgpool_pid) via direct kill"
				fi
			fi
		else
			if kill -HUP "$pgpool_pid" 2>/dev/null; then
				log "Sent SIGHUP to pgpool (pid=$pgpool_pid)"
			else
				log "Failed to send SIGHUP to pgpool (pid=$pgpool_pid)"
			fi
		fi
	else
		log "Could not determine running pgpool PID (tried PIDFILE=$PIDFILE and ps lookup); cannot SIGHUP"
	fi
fi

# Also try to reload other pgpool peers if environment provides them
if [ -n "${PGPOOL_PEERS:-}" ]; then
	IFS=',' read -r -a peers <<< "$PGPOOL_PEERS"
	for p in "${peers[@]}"; do
		peer_host=$(echo "$p" | tr -d '[:space:]')
		# use default PCP port
		reload_pcp "$peer_host" 9898 || true
	done
fi

log "Failover helper completed: PgPool reload attempted."