#!/bin/bash
set -e

echo "[$(date)] HAProxy Entrypoint - Starting..."

# Environment variables with defaults
PGPOOL_BACKENDS=${PGPOOL_BACKENDS:-"pgpool-1:5432,pgpool-2:5432"}
HAPROXY_STATS_PORT=${HAPROXY_STATS_PORT:-8404}
HAPROXY_STATS_USER=${HAPROXY_STATS_USER:-admin}
HAPROXY_STATS_PASSWORD=${HAPROXY_STATS_PASSWORD:-changeme}
HAPROXY_ENABLE_SSL=${HAPROXY_ENABLE_SSL:-0}

# Generate dynamic haproxy.cfg based on environment
echo "[$(date)] Generating HAProxy configuration from environment..."
# If SSL termination is enabled, ensure server.pem exists (private key + cert)
if [ "${HAPROXY_ENABLE_SSL:-0}" = "1" ]; then
    mkdir -p /etc/ssl/haproxy
    if [ -f /etc/ssl/haproxy/server.key ] && [ -f /etc/ssl/haproxy/server.crt ]; then
        # Convert to PKCS#1 format and create PEM
        openssl rsa -in /etc/ssl/haproxy/server.key -out /etc/ssl/haproxy/server.key.pkcs1 -traditional
        cat /etc/ssl/haproxy/server.key.pkcs1 /etc/ssl/haproxy/server.crt > /etc/ssl/haproxy/server.pem
        rm /etc/ssl/haproxy/server.key.pkcs1
        chmod 644 /etc/ssl/haproxy/server.pem
        chown haproxy:haproxy /etc/ssl/haproxy/server.pem
        echo "[$(date)] HAProxy SSL termination enabled (server.pem created)"
    else
        echo "[$(date)] WARNING: HAPROXY_ENABLE_SSL=1 but cert/key not found in /etc/ssl/haproxy"
    fi
fi

cat > /usr/local/etc/haproxy/haproxy.cfg <<EOF
#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    log stdout format raw local0 info
    
    # Performance tuning for high-throughput (32 vCPU / 32 GB RAM)
    maxconn 50000                      # Max concurrent connections
    nbthread 32                        # Match vCPU count
    cpu-map auto:1/1-32 0-31          # Pin threads to CPUs
    
    # Buffers and timeouts
    tune.bufsize 32768                 # 32 KB buffer (default 16KB)
    tune.maxrewrite 8192               # Max header rewrite buffer
    
    # SSL/TLS (if needed in future)
    ssl-default-bind-ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-options ssl-min-ver TLSv1.2
    
    # Security
    user haproxy
    group haproxy
    
    # Stats socket for runtime API
    stats socket /var/lib/haproxy/stats mode 600 level admin expose-fd listeners
    stats timeout 30s

#---------------------------------------------------------------------
# Defaults
#---------------------------------------------------------------------
defaults
    log global
    mode tcp                           # TCP mode for PostgreSQL
    option tcplog                      # Detailed TCP logging
    option dontlognull                 # Don't log health check probes
    
    # Timeouts optimized for database workloads
    timeout connect 5s                 # Backend connection timeout
    timeout client 1h                  # Client idle timeout (long for transactions)
    timeout server 1h                  # Server idle timeout
    timeout check 5s                   # Health check timeout
    
    # Retries and connection handling
    retries 3                          # Retry failed connections 3 times
    option redispatch                  # Redistribute on server failure
    option tcp-smart-accept            # Delay accept until data arrives
    option tcp-smart-connect           # Delay connect until data ready
    
    # Load balancing
    balance roundrobin                  # Route to server with least connections
    
    # Error handling
    default-server inter 3s fall 3 rise 2  # Health check: every 3s, down after 3 fails, up after 2 success

#---------------------------------------------------------------------
# Stats Page (HTTP)
#---------------------------------------------------------------------
listen stats
    bind *:${HAPROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /
    stats refresh 5s
    stats show-legends
    stats show-node
    stats auth ${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASSWORD}

#---------------------------------------------------------------------
# PostgreSQL Frontend (Read/Write via PgPool)
# Port 5432 - Main endpoint for application connections
#---------------------------------------------------------------------
frontend postgres_frontend
EOF

# Generate bind line based on SSL setting
if [ "${HAPROXY_ENABLE_SSL:-0}" = "1" ]; then
    cat >> /usr/local/etc/haproxy/haproxy.cfg <<EOF
    bind *:5432 ssl crt /etc/ssl/haproxy/server.pem
EOF
else
    cat >> /usr/local/etc/haproxy/haproxy.cfg <<EOF
    bind *:5432
EOF
fi

cat >> /usr/local/etc/haproxy/haproxy.cfg <<EOF
    mode tcp
    
    # Connection limits
    maxconn 100000                      # Reserve some for health checks
    
    # TCP optimization
    option tcpka                       # Enable TCP keepalive
    
    # Default backend
    default_backend pgpool_backend

#---------------------------------------------------------------------
# PgPool Backend Pool
# PgPool handles read/write splitting, we just load-balance between 2 PgPool nodes
#---------------------------------------------------------------------
backend pgpool_backend
    mode tcp
    
    # Balance algorithm: leastconn (route to PgPool with fewest active connections)
    balance leastconn
    
    # TCP connections to PgPool (PgPool doesn't support SSL for client connections)
    
    # Sticky sessions based on source IP (optional, for connection pooling efficiency)
    # Disabled by default - PgPool handles session state
    # stick-table type ip size 200k expire 30m
    # stick on src
    
    # Health check: TCP connect to port 5432 (PgPool accepts TCP connections)
    option tcp-check
    tcp-check connect port 5432
    
EOF

# Parse PGPOOL_BACKENDS and add server entries dynamically
echo "[$(date)] Adding PgPool backends: $PGPOOL_BACKENDS"

IFS=',' read -ra BACKENDS <<< "$PGPOOL_BACKENDS"
SERVER_ID=1
for backend in "${BACKENDS[@]}"; do
    host=$(echo "$backend" | cut -d: -f1)
    port=$(echo "$backend" | cut -s -d: -f2)
    if [ -z "$port" ]; then port=5432; fi
    
    # Add server entry without SSL (PgPool doesn't support SSL for client connections)
    cat >> /usr/local/etc/haproxy/haproxy.cfg <<BACKEND_EOF
    # PgPool node $SERVER_ID
    server pgpool-$SERVER_ID $host:$port check inter 2s fastinter 500ms downinter 3s rise 3 fall 2 maxconn 30000
BACKEND_EOF
    
    SERVER_ID=$((SERVER_ID + 1))
done

# Display configuration summary
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          HAProxy Configuration Summary                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Mode: TCP (PostgreSQL passthrough)"
echo "  Max Connections: 50,000"
echo "  Threads: 32 (CPU-pinned)"
echo "  Balance Algorithm: leastconn"
echo ""
echo "  Frontends:"
echo "    PostgreSQL: *:5432 → pgpool_backend"
echo "    Stats:      *:${HAPROXY_STATS_PORT} (HTTP)"
echo ""
echo "  Backends (PgPool nodes):"
IFS=',' read -ra BACKENDS <<< "$PGPOOL_BACKENDS"
for backend in "${BACKENDS[@]}"; do
    echo "    - $backend (health check: every 3s, TCP)"
done
echo ""
echo "  Health Check:"
echo "    Interval: 2s (fast: 500ms when down)"
echo "    Fail threshold: 2 consecutive failures"
echo "    Rise threshold: 3 consecutive successes"
echo "    Down interval: 3s"
echo ""
echo "══════════════════════════════════════════════════════════"
echo ""

# Validate configuration
echo "[$(date)] Validating HAProxy configuration..."

# Helper: check backends and return number of responsive backends
check_backends() {
    local count=0
    for backend in "${BACKENDS[@]}"; do
        host=$(echo "$backend" | cut -d: -f1)
        port=$(echo "$backend" | cut -s -d: -f2)
        if [ -z "$port" ]; then port=5432; fi

        # DNS resolution
        if ! getent hosts "$host" >/dev/null 2>&1; then
            continue
        fi

        PCP_PORT=9898
        if bash -c "</dev/tcp/$host/$PCP_PORT" >/dev/null 2>&1; then
            count=$((count+1))
            continue
        fi

        # Require two consecutive successful TCP connects to avoid flakiness
        success_count=0
        required_successes=2
        for j in $(seq 1 $required_successes); do
            if bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
                success_count=$((success_count+1))
            else
                break
            fi
            sleep 1
        done
        if [ "$success_count" -ge "$required_successes" ]; then
            count=$((count+1))
        fi
    done
    echo "$count"
}

# Wait until at least one backend is responsive. This avoids HAProxy starting
# while all PgPool nodes are still initializing. The loop is indefinite to
# keep the container alive and retry until a backend appears.
HAPROXY_MIN_READY=${HAPROXY_MIN_READY:-2}   # require at least N backends
HAPROXY_WAIT_INTERVAL=${HAPROXY_WAIT_INTERVAL:-3}
echo "[$(date)] Waiting for at least ${HAPROXY_MIN_READY} responsive PgPool backend(s)..."
while true; do
    ready=$(check_backends)
    if [ -n "$ready" ] && [ "$ready" -ge "$HAPROXY_MIN_READY" ]; then
        echo "  ✓ $ready backend(s) are responsive — proceeding to validate HAProxy config"
        break
    fi
    echo "  ✗ $ready backend(s) responsive — re-checking in ${HAPROXY_WAIT_INTERVAL}s..."
    sleep $HAPROXY_WAIT_INTERVAL
done

if haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg; then
    echo "[$(date)] ✓ Configuration is valid"
else
    echo "[$(date)] ✗ Configuration validation FAILED"
    cat /usr/local/etc/haproxy/haproxy.cfg
    exit 1
fi

# Start HAProxy
echo "[$(date)] Starting HAProxy..."
exec haproxy -f /usr/local/etc/haproxy/haproxy.cfg -W -db
