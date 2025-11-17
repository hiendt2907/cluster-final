FROM postgres:17

# Cài repmgr và tiện ích
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-17-repmgr gosu vim less && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/repmgr && chown postgres:postgres /etc/repmgr

# Create SSL directory
RUN mkdir -p /etc/ssl/postgresql && chown postgres:postgres /etc/ssl/postgresql

# Copy SSL certificates
COPY postgresql/ssl/server.crt /etc/ssl/postgresql/server.crt
COPY postgresql/ssl/server.key /etc/ssl/postgresql/server.key
COPY postgresql/ssl/client.crt /etc/ssl/postgresql/client.crt
COPY postgresql/ssl/client.key /etc/ssl/postgresql/client.key

# Set proper permissions for SSL certificates
RUN chown postgres:postgres /etc/ssl/postgresql/*.crt /etc/ssl/postgresql/*.key && \
    chmod 600 /etc/ssl/postgresql/*.key && \
    chmod 644 /etc/ssl/postgresql/*.crt

# Copy scripts (paths relative to repo root; build with the repository root as context)
# When building from repo root: docker build -f postgresql/Dockerfile .
COPY postgresql/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY postgresql/scripts/monitor.sh /usr/local/bin/monitor.sh
COPY postgresql/scripts/promote_guard.sh /usr/local/bin/promote_guard.sh
COPY postgresql/scripts/promote_hook.sh /usr/local/bin/promote_hook.sh
COPY postgresql/scripts/failover_validation.sh /usr/local/bin/failover_validation.sh

# Copy scenario scripts and utilities into the image so entrypoint or external operators
# can start the cluster_state_updater and scenario helpers. These are owned by postgres.
COPY postgresql/scripts/scenarios /usr/local/bin/scenarios
RUN chmod -R a+rx /usr/local/bin/scenarios || true
RUN chown -R postgres:postgres /usr/local/bin/scenarios || true

RUN chmod +x /usr/local/bin/*.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]