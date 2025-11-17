FROM debian:bookworm-slim

# Install PostgreSQL client, pgpool2, and utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    pgpool2 \
    postgresql-client-15 \
    postgresql-client-common \
    curl \
    jq \
    gosu \
    procps \
    gettext-base \
    strace \
    gdb \
    tcpdump \
    && rm -rf /var/lib/apt/lists/*

# Try to install ltrace separately; it's not available in some slim images/repos.
RUN apt-get update || true && apt-get install -y --no-install-recommends ltrace || true \
    && rm -rf /var/lib/apt/lists/* || true

# Create necessary directories
RUN mkdir -p /etc/pgpool-II /var/run/pgpool /var/log/pgpool /config /etc/ssl/pgpool \
    && chown -R postgres:postgres /etc/pgpool-II /var/run/pgpool /var/log/pgpool /etc/ssl/pgpool

# Copy SSL certificates
COPY ssl/server.crt /etc/ssl/pgpool/server.crt
COPY ssl/server.key /etc/ssl/pgpool/server.key
COPY ssl/client.crt /etc/ssl/pgpool/client.crt
COPY ssl/client.key /etc/ssl/pgpool/client.key

# Set proper permissions for SSL certificates
RUN chown postgres:postgres /etc/ssl/pgpool/*.crt /etc/ssl/pgpool/*.key && \
    chmod 600 /etc/ssl/pgpool/*.key && \
    chmod 644 /etc/ssl/pgpool/*.crt

# Copy configuration files to /config (will be copied to /etc/pgpool-II at runtime)
COPY pgpool.conf /config/
COPY pool_hba.conf /config/
COPY pcp.conf /config/

# Copy scripts
COPY entrypoint.sh /usr/local/bin/
COPY pgpool_monitor.sh /usr/local/bin/
COPY monitor.sh /usr/local/bin/
COPY failover.sh /usr/local/bin/
COPY pcp_debug_runner.sh /usr/local/bin/pcp_debug_runner.sh
COPY pcp_cleanup_debug.sh /usr/local/bin/pcp_cleanup_debug.sh
RUN chmod +x /usr/local/bin/*.sh
RUN chmod +x /usr/local/bin/pcp_debug_runner.sh /usr/local/bin/pcp_cleanup_debug.sh || true

# Expose ports
# 5432 - PostgreSQL protocol
# 9898 - PCP (Pgpool Control Protocol)
# 9000 - Watchdog
# 9694 - Heartbeat
EXPOSE 5432 9898 9000 9694

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
